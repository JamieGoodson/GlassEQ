import CoreAudio
import Foundation
import GlassEQCore
import Synchronization

public enum AudioEngineState: Equatable, Sendable {
    case stopped
    case running(output: AudioOutputDevice)
    case failed(String)
}

public struct AudioEngineMetrics: Equatable, Sendable {
    public var capturedFrames: UInt64
    public var playedFrames: UInt64
    public var playbackUnderrunFrames: UInt64
    public var saturatedSamples: UInt64
    public var currentBufferedFrames: Int
    public var maxBufferedFrames: Int
    public var maximumPlaybackBufferedFrames: Int
    public var minimumPlaybackBufferedFrames: Int
    public var averagePlaybackBufferedFrames: Double
    public var playbackBufferObservations: UInt64
    public var maximumCaptureCallbackFrames: Int
    public var maximumPlaybackCallbackFrames: Int

    public init(
        capturedFrames: UInt64 = 0,
        playedFrames: UInt64 = 0,
        playbackUnderrunFrames: UInt64 = 0,
        saturatedSamples: UInt64 = 0,
        currentBufferedFrames: Int = 0,
        maxBufferedFrames: Int = 0,
        maximumPlaybackBufferedFrames: Int = 0,
        minimumPlaybackBufferedFrames: Int = 0,
        averagePlaybackBufferedFrames: Double = 0,
        playbackBufferObservations: UInt64 = 0,
        maximumCaptureCallbackFrames: Int = 0,
        maximumPlaybackCallbackFrames: Int = 0
    ) {
        self.capturedFrames = capturedFrames
        self.playedFrames = playedFrames
        self.playbackUnderrunFrames = playbackUnderrunFrames
        self.saturatedSamples = saturatedSamples
        self.currentBufferedFrames = currentBufferedFrames
        self.maxBufferedFrames = maxBufferedFrames
        self.maximumPlaybackBufferedFrames = maximumPlaybackBufferedFrames
        self.minimumPlaybackBufferedFrames = minimumPlaybackBufferedFrames
        self.averagePlaybackBufferedFrames = averagePlaybackBufferedFrames
        self.playbackBufferObservations = playbackBufferObservations
        self.maximumCaptureCallbackFrames = maximumCaptureCallbackFrames
        self.maximumPlaybackCallbackFrames = maximumPlaybackCallbackFrames
    }
}

protocol TopologyRebuildMuteGuarding: AnyObject {
    func release()
}

struct TopologyRebuildMuteGuardUnavailable: Error, LocalizedError {
    var underlyingError: any Error

    var errorDescription: String? {
        "GlassEQ could not guarantee silence for a profile rebuild, so the current audio engine was left running."
    }
}

private struct AudioEngineInternalError: Error, LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}

public final class SystemTapAudioEngine: @unchecked Sendable {
    private static let preferredBufferFrameSize: UInt32 = 256
    private static let preferredBluetoothBufferFrameSize: UInt32 = 512
    private static let preferredLowSampleRateBufferFrameSize: UInt32 = 1024
    private static let preferredCaptureBufferFrameSize: UInt32 = 256
    private static let minimumRingBufferFrames = 2048
    private static let maximumRuntimeBufferFrameSize: UInt32 = 1024
    private static let preferredPlaybackPrimeFrames = 512
    private static let lowSampleRateThreshold = 24_000.0

    private struct ControlState {
        var state: AudioEngineState = .stopped
        var status: AudioEngineStatus = .stopped
        // Persistent capture half (one global muted tap, kept alive across output switches).
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var captureIOProcID: AudioDeviceIOProcID?
        var runtime: AudioRuntime?
        var tapSampleRate: Double = 0
        var tapChannelCount: Int = 0
        var captureRunning = false
        // Swappable output half (rebuilt per output device; device forced to the tap rate).
        var outputIOProcID: AudioDeviceIOProcID?
        var activeOutput: AudioOutputDevice?
        var activeProfile: EQProfile?
        var bufferFrameSizeRestorations: [String: BufferFrameSizeRestoration] = [:]
        var sampleRateRestorations: [String: SampleRateRestoration] = [:]
        var outputRebuildGeneration = 0
    }

    private struct OutputRebuildPreparation {
        var generation: Int
        var output: AudioOutputDevice
        var profile: EQProfile
        var runtime: AudioRuntime
        var tapSampleRate: Double
        var originalBufferFrameSize: UInt32
    }

    private struct StaleOutputRebuild: Error {}

    struct BufferFrameSizeRestoration: Equatable, Sendable {
        var uid: String
        var originalFrameSize: UInt32
    }

    struct SampleRateRestoration: Equatable, Sendable {
        var uid: String
        var originalSampleRate: Double
    }

    private final class CoreAudioTopologyRebuildMuteGuard: TopologyRebuildMuteGuarding, @unchecked Sendable {
        private let lock = NSLock()
        private var tapID: AudioObjectID
        private var aggregateDeviceID: AudioObjectID
        private var ioProcID: AudioDeviceIOProcID?

        init(
            tapID: AudioObjectID,
            aggregateDeviceID: AudioObjectID,
            ioProcID: AudioDeviceIOProcID?
        ) {
            self.tapID = tapID
            self.aggregateDeviceID = aggregateDeviceID
            self.ioProcID = ioProcID
        }

        deinit {
            release()
        }

        func release() {
            lock.lock()
            defer { lock.unlock() }

            if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
                _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            if aggregateDeviceID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            }
            if tapID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }

            ioProcID = nil
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private final class PreparedDSPConfigBox: @unchecked Sendable {
        let config: EQRenderConfiguration
        var retiredStorage: EQProcessorRetiredRenderStorage?
        var nextRetiredPointer: UInt = 0

        init(config: EQRenderConfiguration) {
            self.config = config
        }
    }

    private final class AudioRuntime: @unchecked Sendable {
        let ringBuffer: RealtimeAudioRingBuffer
        let channelCount: Int
        let sampleRate: Double
        private let playbackPrimeFrames: Int
        private let maxCallbackFrames: Int
        private var processor: EQProcessor
        private var captureScratchSamples: [Float]
        private var playbackScratchSamples: [Float]

        private let capturedFrames = Atomic<UInt64>(0)
        private let playedFrames = Atomic<UInt64>(0)
        private let playbackUnderrunFrames = Atomic<UInt64>(0)
        private let saturatedSamples = Atomic<UInt64>(0)
        private let maxBufferedFrames = Atomic<Int>(0)
        private let maxPlaybackBufferedFrames = Atomic<Int>(0)
        private let minPlaybackBufferedFrames = Atomic<Int>(Int.max)
        private let totalPlaybackBufferedFrames = Atomic<UInt64>(0)
        private let playbackBufferObservations = Atomic<UInt64>(0)
        private let maxCaptureCallbackFrames = Atomic<Int>(0)
        private let maxPlaybackCallbackFrames = Atomic<Int>(0)
        private let bypassEnabled: Atomic<Bool>
        private let playbackPriming = Atomic<Bool>(true)
        private let outputMutedForTransition = Atomic<Bool>(false)
        private let pendingPlaybackReset = Atomic<Bool>(false)
        private let pendingDSPConfigPointer = Atomic<UInt>(0)
        private let retiredDSPConfigHeadPointer = Atomic<UInt>(0)
        private let stopping = Atomic<Bool>(false)
        private let captureInCallback = Atomic<Bool>(false)
        private let playbackInCallback = Atomic<Bool>(false)
        // Packed (left << 32 | right) so the playback callback can never observe a torn pair.
        private let playbackChannelPair = Atomic<UInt64>(SystemTapAudioEngine.encodedPlaybackChannelPair(left: 0, right: 1))

        init(
            profile: EQProfile,
            sampleRate: Double,
            channelCount: Int,
            ringCapacityFrames: Int,
            scratchFrames: Int,
            playbackPrimeFrames: Int
        ) {
            self.channelCount = max(channelCount, 1)
            self.sampleRate = sampleRate
            self.ringBuffer = RealtimeAudioRingBuffer(
                channelCount: self.channelCount,
                capacityFrames: ringCapacityFrames
            )
            self.captureScratchSamples = Array(repeating: 0, count: scratchFrames * self.channelCount)
            self.playbackScratchSamples = Array(repeating: 0, count: scratchFrames * self.channelCount)
            self.playbackPrimeFrames = playbackPrimeFrames
            self.maxCallbackFrames = max(8_192, max(scratchFrames * 4, ringCapacityFrames * 2))
            self.processor = EQProcessor(
                renderConfiguration: EQRenderConfiguration(
                    profile: SystemTapAudioEngine.dspProfile(from: profile),
                    sampleRate: sampleRate,
                    channelCount: self.channelCount
                )
            )
            self.bypassEnabled = Atomic(profile.isBypassed)
        }

        deinit {
            drainDSPConfigBoxes()
        }

        func markStopping() {
            stopping.store(true, ordering: .releasing)
            outputMutedForTransition.store(true, ordering: .releasing)
            playbackPriming.store(true, ordering: .releasing)
        }

        func setBypassed(_ isBypassed: Bool) {
            bypassEnabled.store(isBypassed, ordering: .relaxed)
        }

        func muteOutputForTransition() {
            outputMutedForTransition.store(true, ordering: .releasing)
            playbackPriming.store(true, ordering: .releasing)
        }

        // Stored by the control thread on every output rebuild, before the new output IOProc
        // starts, so the first callback on the new device already maps to the right channels.
        func setPlaybackChannelPair(left: Int, right: Int) {
            playbackChannelPair.store(
                SystemTapAudioEngine.encodedPlaybackChannelPair(left: left, right: right),
                ordering: .releasing
            )
        }

        // Called when a new output half is started. Clears any transition mute (the runtime
        // persists across output switches now, so the mute flag would otherwise stick on and
        // silence everything) and re-primes so playback re-anchors to the freshest audio.
        func reprimePlayback() {
            pendingPlaybackReset.store(true, ordering: .releasing)
            playbackPriming.store(true, ordering: .releasing)
            outputMutedForTransition.store(false, ordering: .releasing)
        }

        func resetMetrics() {
            capturedFrames.store(0, ordering: .relaxed)
            playedFrames.store(0, ordering: .relaxed)
            playbackUnderrunFrames.store(0, ordering: .relaxed)
            saturatedSamples.store(0, ordering: .relaxed)
            maxBufferedFrames.store(0, ordering: .relaxed)
            maxPlaybackBufferedFrames.store(0, ordering: .relaxed)
            minPlaybackBufferedFrames.store(Int.max, ordering: .relaxed)
            totalPlaybackBufferedFrames.store(0, ordering: .relaxed)
            playbackBufferObservations.store(0, ordering: .relaxed)
            maxCaptureCallbackFrames.store(0, ordering: .relaxed)
            maxPlaybackCallbackFrames.store(0, ordering: .relaxed)
            playbackPriming.store(true, ordering: .releasing)
        }

        func snapshotMetrics() -> AudioEngineMetrics {
            let observations = playbackBufferObservations.load(ordering: .relaxed)
            let minimumBufferedFrames = minPlaybackBufferedFrames.load(ordering: .relaxed)
            return AudioEngineMetrics(
                capturedFrames: capturedFrames.load(ordering: .relaxed),
                playedFrames: playedFrames.load(ordering: .relaxed),
                playbackUnderrunFrames: playbackUnderrunFrames.load(ordering: .relaxed),
                saturatedSamples: saturatedSamples.load(ordering: .relaxed),
                currentBufferedFrames: ringBuffer.occupancyFrames(),
                maxBufferedFrames: maxBufferedFrames.load(ordering: .relaxed),
                maximumPlaybackBufferedFrames: maxPlaybackBufferedFrames.load(ordering: .relaxed),
                minimumPlaybackBufferedFrames: observations == 0 ? 0 : minimumBufferedFrames,
                averagePlaybackBufferedFrames: observations == 0
                    ? 0
                    : Double(totalPlaybackBufferedFrames.load(ordering: .relaxed)) / Double(observations),
                playbackBufferObservations: observations,
                maximumCaptureCallbackFrames: maxCaptureCallbackFrames.load(ordering: .relaxed),
                maximumPlaybackCallbackFrames: maxPlaybackCallbackFrames.load(ordering: .relaxed)
            )
        }

        func publishPendingDSPConfig(_ config: EQRenderConfiguration) {
            let box = PreparedDSPConfigBox(config: config)
            let rawPointer = UInt(bitPattern: Unmanaged.passRetained(box).toOpaque())
            let oldPointer = pendingDSPConfigPointer.exchange(rawPointer, ordering: .acquiringAndReleasing)
            releaseDSPConfigBox(oldPointer)
        }

        func drainDSPConfigBoxes() {
            releaseDSPConfigBox(pendingDSPConfigPointer.exchange(0, ordering: .acquiringAndReleasing))
            var rawPointer = retiredDSPConfigHeadPointer.exchange(0, ordering: .acquiringAndReleasing)
            while rawPointer != 0 {
                guard let pointer = UnsafeRawPointer(bitPattern: rawPointer) else {
                    return
                }
                let box = Unmanaged<PreparedDSPConfigBox>.fromOpaque(pointer).takeUnretainedValue()
                let nextPointer = box.nextRetiredPointer
                box.nextRetiredPointer = 0
                releaseDSPConfigBox(rawPointer)
                rawPointer = nextPointer
            }
        }

        func capture(inputData: UnsafePointer<AudioBufferList>) {
            guard !stopping.load(ordering: .acquiring),
                  enter(captureInCallback) else {
                return
            }
            defer {
                captureInCallback.store(false, ordering: .releasing)
            }

            let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let frameCount = inputFrameCount(inputBuffers),
                  frameCount > 0 else {
                return
            }
            updateMax(maxCaptureCallbackFrames, frameCount)

            if outputMutedForTransition.load(ordering: .acquiring) {
                return
            }

            applyPendingDSPConfig()

            if bypassEnabled.load(ordering: .relaxed) {
                captureBypassed(inputBuffers: inputBuffers, frameCount: frameCount)
                return
            }

            var saturatedSampleCount: UInt64 = 0
            captureScratchSamples.withUnsafeMutableBufferPointer { scratch in
                let scratchFrames = max(scratch.count / channelCount, 1)
                var frameOffset = 0
                while frameOffset < frameCount {
                    let chunkFrames = min(frameCount - frameOffset, scratchFrames)
                    let chunkSamples = UnsafeMutableBufferPointer(
                        start: scratch.baseAddress,
                        count: chunkFrames * channelCount
                    )
                    copyInput(
                        from: inputBuffers,
                        sourceFrameOffset: frameOffset,
                        into: chunkSamples,
                        frameCount: chunkFrames,
                        channelCount: channelCount
                    )
                    saturatedSampleCount += processor.processInterleavedWithDiagnostics(
                        chunkSamples,
                        frameCount: chunkFrames,
                        channelCount: channelCount
                    )
                    ringBuffer.writeInterleaved(
                        UnsafeBufferPointer(chunkSamples),
                        frameCount: chunkFrames,
                        sourceChannelCount: channelCount
                    )
                    frameOffset += chunkFrames
                }
            }

            if saturatedSampleCount > 0 {
                saturatedSamples.wrappingAdd(saturatedSampleCount, ordering: .relaxed)
            }
            updateMaxBufferedFrames(ringBuffer.occupancyFrames())
            capturedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
        }

        func playback(outputData: UnsafeMutablePointer<AudioBufferList>) {
            guard !stopping.load(ordering: .acquiring) else {
                clear(outputData: outputData)
                return
            }
            guard enter(playbackInCallback) else {
                clear(outputData: outputData)
                return
            }
            defer {
                playbackInCallback.store(false, ordering: .releasing)
            }

            let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard let frameCount = outputFrameCount(outputBuffers) else {
                clear(outputData: outputData)
                return
            }
            guard frameCount > 0 else {
                return
            }
            updateMax(maxPlaybackCallbackFrames, frameCount)

            if pendingPlaybackReset.exchange(false, ordering: .acquiringAndReleasing) {
                _ = ringBuffer.reset()
            }

            if outputMutedForTransition.load(ordering: .acquiring) {
                clear(outputData: outputData)
                return
            }

            if playbackPriming.load(ordering: .acquiring) {
                let bufferedFrames = ringBuffer.occupancyFrames()
                updateMaxBufferedFrames(bufferedFrames)
                guard bufferedFrames >= playbackPrimeFrames else {
                    clear(outputData: outputData)
                    return
                }
                guard ringBuffer.trimToLatestFrames(playbackPrimeFrames) else {
                    clear(outputData: outputData)
                    return
                }
                playbackPriming.store(false, ordering: .releasing)
            }

            recordPlaybackBufferedFrames(ringBuffer.occupancyFrames())

            let (destinationLeftChannel, destinationRightChannel) = SystemTapAudioEngine.decodedPlaybackChannelPair(
                playbackChannelPair.load(ordering: .acquiring)
            )

            var underrunFrames = 0
            if destinationLeftChannel == 0,
               destinationRightChannel == 1,
               let outputSamples = contiguousInterleavedOutputBuffer(
                outputBuffers,
                frameCount: frameCount,
                channelCount: channelCount
            ) {
                let readFrames = ringBuffer.readInterleaved(
                    into: outputSamples,
                    frameCount: frameCount,
                    destinationChannelCount: channelCount
                )
                if readFrames < frameCount {
                    underrunFrames += frameCount - readFrames
                }
            } else {
                playbackScratchSamples.withUnsafeMutableBufferPointer { scratch in
                    let scratchFrames = max(scratch.count / channelCount, 1)
                    var frameOffset = 0
                    while frameOffset < frameCount {
                        let chunkFrames = min(frameCount - frameOffset, scratchFrames)
                        let chunkSamples = UnsafeMutableBufferPointer(
                            start: scratch.baseAddress,
                            count: chunkFrames * channelCount
                        )
                        let readFrames = ringBuffer.readInterleaved(
                            into: chunkSamples,
                            frameCount: chunkFrames,
                            destinationChannelCount: channelCount
                        )
                        if readFrames < chunkFrames {
                            underrunFrames += chunkFrames - readFrames
                        }
                        writeInterleaved(
                            UnsafeBufferPointer(chunkSamples),
                            sourceFrameOffset: 0,
                            destinationFrameOffset: frameOffset,
                            frameCount: chunkFrames,
                            sourceChannelCount: channelCount,
                            destinationLeftChannel: destinationLeftChannel,
                            destinationRightChannel: destinationRightChannel,
                            to: outputBuffers
                        )
                        frameOffset += chunkFrames
                    }
                }
            }

            if underrunFrames > 0 {
                playbackUnderrunFrames.wrappingAdd(UInt64(underrunFrames), ordering: .relaxed)
                playbackPriming.store(true, ordering: .releasing)
            }
            updateMaxBufferedFrames(ringBuffer.occupancyFrames())
            playedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
        }

        func clear(outputData: UnsafeMutablePointer<AudioBufferList>) {
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                guard let data = buffer.mData,
                      let byteCount = validatedClearByteCount(for: buffer) else {
                    continue
                }
                data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            }
        }

        private func captureBypassed(
            inputBuffers: UnsafeMutableAudioBufferListPointer,
            frameCount: Int
        ) {
            if let inputSamples = contiguousInterleavedInputBuffer(
                inputBuffers,
                frameCount: frameCount,
                channelCount: channelCount
            ) {
                ringBuffer.writeInterleaved(
                    inputSamples,
                    frameCount: frameCount,
                    sourceChannelCount: channelCount
                )
            } else {
                captureScratchSamples.withUnsafeMutableBufferPointer { scratch in
                    let scratchFrames = max(scratch.count / channelCount, 1)
                    var frameOffset = 0
                    while frameOffset < frameCount {
                        let chunkFrames = min(frameCount - frameOffset, scratchFrames)
                        let chunkSamples = UnsafeMutableBufferPointer(
                            start: scratch.baseAddress,
                            count: chunkFrames * channelCount
                        )
                        copyInput(
                            from: inputBuffers,
                            sourceFrameOffset: frameOffset,
                            into: chunkSamples,
                            frameCount: chunkFrames,
                            channelCount: channelCount
                        )
                        ringBuffer.writeInterleaved(
                            UnsafeBufferPointer(chunkSamples),
                            frameCount: chunkFrames,
                            sourceChannelCount: channelCount
                        )
                        frameOffset += chunkFrames
                    }
                }
            }

            updateMaxBufferedFrames(ringBuffer.occupancyFrames())
            capturedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
        }

        private func applyPendingDSPConfig() {
            let rawPointer = pendingDSPConfigPointer.exchange(0, ordering: .acquiringAndReleasing)
            guard rawPointer != 0 else {
                return
            }

            let pointer = UnsafeRawPointer(bitPattern: rawPointer)!
            let box = Unmanaged<PreparedDSPConfigBox>.fromOpaque(pointer).takeUnretainedValue()
            box.retiredStorage = processor.applyRealtimeCompatiblePreparedConfiguration(box.config)
            pushRetiredDSPConfigBox(rawPointer)
        }

        private func pushRetiredDSPConfigBox(_ rawPointer: UInt) {
            guard rawPointer != 0,
                  let pointer = UnsafeRawPointer(bitPattern: rawPointer) else {
                return
            }
            let box = Unmanaged<PreparedDSPConfigBox>.fromOpaque(pointer).takeUnretainedValue()
            var head = retiredDSPConfigHeadPointer.load(ordering: .acquiring)
            while true {
                box.nextRetiredPointer = head
                let result = retiredDSPConfigHeadPointer.compareExchange(
                    expected: head,
                    desired: rawPointer,
                    ordering: .acquiringAndReleasing
                )
                if result.exchanged {
                    return
                }
                head = result.original
            }
        }

        private func releaseDSPConfigBox(_ rawPointer: UInt) {
            guard rawPointer != 0,
                  let pointer = UnsafeRawPointer(bitPattern: rawPointer) else {
                return
            }
            Unmanaged<PreparedDSPConfigBox>.fromOpaque(pointer).release()
        }

        private func updateMaxBufferedFrames(_ occupancy: Int) {
            updateMax(maxBufferedFrames, occupancy)
        }

        private func updateMax(_ counter: borrowing Atomic<Int>, _ value: Int) {
            var current = counter.load(ordering: .relaxed)
            while value > current {
                let result = counter.compareExchange(
                    expected: current,
                    desired: value,
                    ordering: .relaxed
                )
                if result.exchanged {
                    return
                }
                current = result.original
            }
        }

        private func recordPlaybackBufferedFrames(_ frames: Int) {
            totalPlaybackBufferedFrames.wrappingAdd(UInt64(max(frames, 0)), ordering: .relaxed)
            playbackBufferObservations.wrappingAdd(1, ordering: .relaxed)
            updateMax(maxPlaybackBufferedFrames, frames)

            var current = minPlaybackBufferedFrames.load(ordering: .relaxed)
            while frames < current {
                let result = minPlaybackBufferedFrames.compareExchange(
                    expected: current,
                    desired: frames,
                    ordering: .relaxed
                )
                if result.exchanged {
                    return
                }
                current = result.original
            }
        }

        private func inputFrameCount(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int? {
            guard let buffer = buffers.first else {
                return 0
            }
            guard validatedClearByteCount(for: buffer) != nil else {
                return nil
            }
            let channels = Int(buffer.mNumberChannels)
            let bytesPerFrame = MemoryLayout<Float>.stride * channels
            let frameCount = Int(buffer.mDataByteSize) / bytesPerFrame
            guard frameCount <= maxCallbackFrames else {
                return nil
            }
            return frameCount
        }

        private func outputFrameCount(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int? {
            guard let buffer = buffers.first else {
                return 0
            }
            guard validatedClearByteCount(for: buffer) != nil else {
                return nil
            }
            let channels = Int(buffer.mNumberChannels)
            let bytesPerFrame = MemoryLayout<Float>.stride * channels
            let frameCount = Int(buffer.mDataByteSize) / bytesPerFrame
            guard frameCount <= maxCallbackFrames else {
                return nil
            }
            return frameCount
        }

        private func validatedClearByteCount(for buffer: AudioBuffer) -> Int? {
            guard buffer.mData != nil else {
                return nil
            }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0,
                  channels <= CoreAudioDeviceQuery.maxChannelCount else {
                return nil
            }
            let bytesPerFrame = MemoryLayout<Float>.stride * channels
            let byteCount = Int(buffer.mDataByteSize)
            guard byteCount >= 0,
                  byteCount % bytesPerFrame == 0 else {
                return nil
            }
            let frameCount = byteCount / bytesPerFrame
            guard frameCount <= maxCallbackFrames else {
                return nil
            }
            return byteCount
        }

        private func copyInput(
            from buffers: UnsafeMutableAudioBufferListPointer,
            sourceFrameOffset: Int,
            into samples: UnsafeMutableBufferPointer<Float>,
            frameCount: Int,
            channelCount: Int
        ) {
            if buffers.count == 1,
               let data = buffers[0].mData?.assumingMemoryBound(to: Float.self),
               Int(buffers[0].mNumberChannels) == channelCount,
               frameCount > 0,
               sourceFrameOffset >= 0 {
                let sourceSampleStart = sourceFrameOffset * channelCount
                let copySamples = frameCount * channelCount
                let availableSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride
                if samples.count >= copySamples,
                   sourceSampleStart + copySamples <= availableSamples,
                   let destination = samples.baseAddress {
                    destination.update(from: data.advanced(by: sourceSampleStart), count: copySamples)
                    return
                }
            }

            for frameIndex in 0..<frameCount {
                let sourceFrame = sourceFrameOffset + frameIndex
                let sampleBase = frameIndex * channelCount
                for channel in 0..<channelCount {
                    samples[sampleBase + channel] = sample(from: buffers, frame: sourceFrame, channel: channel)
                }
            }
        }

        private func contiguousInterleavedInputBuffer(
            _ buffers: UnsafeMutableAudioBufferListPointer,
            frameCount: Int,
            channelCount: Int
        ) -> UnsafeBufferPointer<Float>? {
            guard buffers.count == 1,
                  frameCount > 0,
                  Int(buffers[0].mNumberChannels) == channelCount,
                  let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return nil
            }
            let sampleCount = frameCount * channelCount
            guard sampleCount <= Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride else {
                return nil
            }
            return UnsafeBufferPointer(start: data, count: sampleCount)
        }

        private func contiguousInterleavedOutputBuffer(
            _ buffers: UnsafeMutableAudioBufferListPointer,
            frameCount: Int,
            channelCount: Int
        ) -> UnsafeMutableBufferPointer<Float>? {
            guard buffers.count == 1,
                  frameCount > 0,
                  Int(buffers[0].mNumberChannels) == channelCount,
                  let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return nil
            }
            let sampleCount = frameCount * channelCount
            guard sampleCount <= Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride else {
                return nil
            }
            return UnsafeMutableBufferPointer(start: data, count: sampleCount)
        }

        private func sample(
            from buffers: UnsafeMutableAudioBufferListPointer,
            frame: Int,
            channel: Int
        ) -> Float {
            if buffers.count == 1,
               let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                let channelCount = max(Int(buffers[0].mNumberChannels), 1)
                let index = frame * channelCount + min(channel, channelCount - 1)
                guard index >= 0,
                      index < Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride else {
                    return 0
                }
                return data[index]
            }

            let bufferIndex = min(channel, buffers.count - 1)
            guard bufferIndex >= 0,
                  let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self),
                  frame >= 0,
                  frame < Int(buffers[bufferIndex].mDataByteSize) / MemoryLayout<Float>.stride else {
                return 0
            }
            return data[frame]
        }

        private func writeInterleaved(
            _ samples: UnsafeBufferPointer<Float>,
            sourceFrameOffset: Int,
            destinationFrameOffset: Int,
            frameCount: Int,
            sourceChannelCount: Int,
            destinationLeftChannel: Int,
            destinationRightChannel: Int,
            to buffers: UnsafeMutableAudioBufferListPointer
        ) {
            SystemTapAudioEngine.copyInterleavedSamples(
                samples,
                sourceFrameOffset: sourceFrameOffset,
                destinationFrameOffset: destinationFrameOffset,
                frameCount: frameCount,
                sourceChannelCount: sourceChannelCount,
                destinationLeftChannel: destinationLeftChannel,
                destinationRightChannel: destinationRightChannel,
                to: buffers
            )
        }

        private func enter(_ gate: borrowing Atomic<Bool>) -> Bool {
            gate.compareExchange(
                expected: false,
                desired: true,
                ordering: .acquiringAndReleasing
            ).exchanged
        }
    }

    private let control = Mutex(ControlState())
    private let restorationStoreURL: URL

    public var state: AudioEngineState {
        control.withLock { $0.state }
    }

    public var status: AudioEngineStatus {
        control.withLock { $0.status }
    }

    public init(restorationStoreURL: URL? = nil) {
        let restorationStoreURL = restorationStoreURL ?? PersistedAudioDeviceRestorationStore.defaultURL()
        self.restorationStoreURL = restorationStoreURL
        Self.restorePersistedDeviceSettings(at: restorationStoreURL)
    }

    deinit {
        stop()
    }

    public func start(output: AudioOutputDevice, profile: EQProfile) throws {
        var previousState = AudioEngineState.stopped
        var previousStatus = AudioEngineStatus.stopped
        var activePreparation: OutputRebuildPreparation?

        do {
            let preparation = try control.withLock { state in
                previousState = state.state
                previousStatus = state.status
                state.status = .starting
                // The capture half (one global muted tap @ the tap rate) is created once and
                // kept alive across output switches, so dry audio never leaks to a newly
                // selected device. Only the output half is (re)built for `output`.
                try ensureCaptureHalfLocked(&state, profile: profile)
                return try prepareOutputRebuildLocked(&state, output: output, profile: profile)
            }
            activePreparation = preparation
            let matchedOutput = try forceSampleRate(preparation.tapSampleRate, on: preparation.output)
            try control.withLock { state in
                try finishOutputRebuildLocked(&state, preparation: preparation, matchedOutput: matchedOutput)
                let active = state.activeOutput ?? output
                state.state = .running(output: active)
                state.status = .running(output: active)
            }
        } catch is StaleOutputRebuild {
            return
        } catch {
            var shouldRethrow = true
            control.withLock { state in
                if let activePreparation,
                   state.outputRebuildGeneration != activePreparation.generation {
                    shouldRethrow = false
                    return
                }
                if error is TopologyRebuildMuteGuardUnavailable {
                    state.state = previousState
                    state.status = previousStatus
                    if case .running = previousState {
                        shouldRethrow = false
                    }
                    return
                }
                let failure = audioEngineFailure(from: error)
                // Any failure tears the tap down too, so the system is never left muted
                // with nothing replaying.
                stopLocked(&state)
                state.state = .failed(failure.description)
                if failure.category == .systemAudioCapturePermission {
                    state.status = .permissionRequired(failure)
                } else {
                    state.status = .failed(failure)
                }
            }
            if shouldRethrow {
                throw error
            }
        }
    }

    public func update(profile: EQProfile) throws {
        // Prefer a lock-free hot-swap that leaves the persistent tap untouched.
        if updateDSP(profile: profile) {
            return
        }
        // Topology-incompatible change: rebuild around the persistent tap (the tap rate is
        // constant, so start() keeps the capture half and only swaps the DSP graph + output).
        guard let output = control.withLock({ $0.activeOutput }) else {
            return
        }
        let freshOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
        try start(output: freshOutput, profile: profile)
        let didApplyProfile = control.withLock { state in
            state.activeProfile == profile
        }
        guard didApplyProfile else {
            throw TopologyRebuildMuteGuardUnavailable(
                underlyingError: AudioEngineInternalError(message: "Profile rebuild was not applied.")
            )
        }
    }

    @discardableResult
    public func updateDSP(profile: EQProfile) -> Bool {
        control.withLock { state in
            updateDSPLocked(&state, profile: profile)
        }
    }

    private func updateDSPLocked(_ state: inout ControlState, profile: EQProfile) -> Bool {
        guard let runtime = state.runtime,
              let activeProfile = state.activeProfile else {
            return false
        }

        guard Self.canHotSwapDSP(
            from: activeProfile,
            to: profile,
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount
        ) else {
            return false
        }

        let preparedConfig = EQRenderConfiguration(
            profile: Self.dspProfile(from: profile),
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount
        )
        runtime.drainDSPConfigBoxes()
        runtime.publishPendingDSPConfig(preparedConfig)
        runtime.setBypassed(profile.isBypassed)
        state.activeProfile = profile
        return true
    }

    static func canHotSwapDSP(
        from activeProfile: EQProfile,
        to nextProfile: EQProfile,
        sampleRate: Double,
        channelCount: Int
    ) -> Bool {
        guard activeProfile.mode == nextProfile.mode,
              activeProfile.channelMode == nextProfile.channelMode else {
            return false
        }

        return EQRenderConfiguration(
            profile: Self.dspProfile(from: nextProfile),
            sampleRate: sampleRate,
            channelCount: channelCount
        ).hasRealtimeCompatibleTopology(
            with: EQRenderConfiguration(
                profile: Self.dspProfile(from: activeProfile),
                sampleRate: sampleRate,
                channelCount: channelCount
            )
        )
    }

    public func setBypassed(_ isBypassed: Bool) {
        control.withLock { state in
            state.runtime?.setBypassed(isBypassed)
            state.activeProfile?.isBypassed = isBypassed
        }
    }

    public func muteOutputForTransition() {
        control.withLock { state in
            state.runtime?.muteOutputForTransition()
        }
    }

    public func stop() {
        control.withLock { state in
            stopLocked(&state)
        }
    }

    public func snapshotMetrics() -> AudioEngineMetrics {
        let runtime = control.withLock { $0.runtime }
        return runtime?.snapshotMetrics() ?? AudioEngineMetrics()
    }

    public func resetDiagnostics() {
        let runtime = control.withLock { $0.runtime }
        runtime?.resetMetrics()
    }

    private func stopLocked(_ state: inout ControlState) {
        state.runtime?.markStopping()
        stopOutputHalfLocked(&state)
        stopCaptureHalfLocked(&state)
        state.activeProfile = nil
        state.state = .stopped
        state.status = .stopped
    }

    // MARK: - Capture half (persistent global muted tap @ the tap rate)

    private func ensureCaptureHalfLocked(_ state: inout ControlState, profile: EQProfile) throws {
        if state.captureRunning, state.runtime != nil {
            if updateDSPLocked(&state, profile: profile) {
                return
            }
            // Topology-incompatible DSP change: hold a second global muted tap while the
            // capture half is torn down and recreated, so HAL-level muting never lapses.
            try Self.performTopologyRebuild(
                acquireMuteGuard: { try createTopologyRebuildMuteGuard() }
            ) {
                stopOutputHalfLocked(&state)
                stopCaptureHalfLocked(&state)
                try createCaptureHalfLocked(&state, profile: profile)
            }
            return
        }
        try createCaptureHalfLocked(&state, profile: profile)
    }

    private func createCaptureHalfLocked(_ state: inout ControlState, profile: EQProfile) throws {
        let tapID = try createSystemTap()
        state.tapID = tapID

        let format = try tapStreamFormat(tapID)
        let tapSampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let tapChannelCount = min(max(Int(format.mChannelsPerFrame), 1), 2)
        state.tapSampleRate = tapSampleRate
        state.tapChannelCount = tapChannelCount

        let runtimeBufferFrameSize = Int(Self.maximumRuntimeBufferFrameSize)
        // Low-latency tuning: a 512-frame prime (~11 ms @ 48k) — about 2x the tap's callback
        // once we request a 256-frame capture buffer below. The ring keeps drift/transient
        // headroom above the prime; raise the prime if underruns appear on a given device.
        let playbackPrimeFrames = Self.preferredPlaybackPrimeFrames
        let ringCapacityFrames = max(Self.minimumRingBufferFrames, playbackPrimeFrames * 2)
        let scratchFrames = max(runtimeBufferFrameSize, Self.minimumRingBufferFrames)

        let runtime = AudioRuntime(
            profile: profile,
            sampleRate: tapSampleRate,
            channelCount: tapChannelCount,
            ringCapacityFrames: ringCapacityFrames,
            scratchFrames: scratchFrames,
            playbackPrimeFrames: playbackPrimeFrames
        )
        state.runtime = runtime
        state.activeProfile = profile

        state.aggregateDeviceID = try createPrivateAggregateDevice(tapID: tapID)
        // Ask the capture aggregate for small callbacks to cut latency (best-effort; not all
        // tap aggregates honor it — if ignored, the prime above still keeps capture safe).
        try? CoreAudioDeviceQuery.setBufferFrameSize(Self.preferredCaptureBufferFrameSize, objectID: state.aggregateDeviceID)
        state.captureIOProcID = try createCaptureIOProc(deviceID: state.aggregateDeviceID, runtime: runtime)
        try checkOSStatus(
            AudioDeviceStart(state.aggregateDeviceID, state.captureIOProcID),
            operation: "AudioDeviceStart(capture tap)"
        )
        state.captureRunning = true
    }

    private func stopCaptureHalfLocked(_ state: inout ControlState) {
        state.runtime?.markStopping()

        if state.aggregateDeviceID != kAudioObjectUnknown, let captureIOProcID = state.captureIOProcID {
            _ = AudioDeviceStop(state.aggregateDeviceID, captureIOProcID)
            _ = AudioDeviceDestroyIOProcID(state.aggregateDeviceID, captureIOProcID)
        }
        if state.aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(state.aggregateDeviceID)
        }
        if state.tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(state.tapID)
        }

        state.runtime?.drainDSPConfigBoxes()
        state.captureIOProcID = nil
        state.aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        state.tapID = AudioObjectID(kAudioObjectUnknown)
        state.runtime = nil
        state.tapSampleRate = 0
        state.tapChannelCount = 0
        state.captureRunning = false
    }

    // MARK: - Output half (swappable; device forced to the tap rate so no resampling)

    private func prepareOutputRebuildLocked(
        _ state: inout ControlState,
        output: AudioOutputDevice,
        profile: EQProfile
    ) throws -> OutputRebuildPreparation {
        guard let runtime = state.runtime else {
            throw CoreAudioError(operation: "rebuildOutputHalf(missing runtime)", status: kAudioHardwareNotRunningError)
        }
        // Match the device to the tap's fixed rate so the EQ'd stream needs no resampling.
        let originalBufferFrameSize = output.bufferFrameSize
        _ = try Self.supportedRuntimeChannelCount(for: output)
        stopOutputHalfLocked(&state)
        if state.tapSampleRate > 0, abs(output.nominalSampleRate - state.tapSampleRate) >= 1 {
            try recordSampleRateRestorationIfNeeded(for: output, state: &state)
        }
        return OutputRebuildPreparation(
            generation: state.outputRebuildGeneration,
            output: output,
            profile: profile,
            runtime: runtime,
            tapSampleRate: state.tapSampleRate,
            originalBufferFrameSize: originalBufferFrameSize
        )
    }

    private func finishOutputRebuildLocked(
        _ state: inout ControlState,
        preparation: OutputRebuildPreparation,
        matchedOutput: AudioOutputDevice
    ) throws {
        guard state.outputRebuildGeneration == preparation.generation,
              state.runtime === preparation.runtime,
              state.captureRunning else {
            throw StaleOutputRebuild()
        }
        let runtime = preparation.runtime
        let output = preparation.output
        _ = try Self.supportedRuntimeChannelCount(for: matchedOutput)
        if state.bufferFrameSizeRestorations[output.uid] == nil {
            let restoration = BufferFrameSizeRestoration(
                uid: output.uid,
                originalFrameSize: preparation.originalBufferFrameSize
            )
            try PersistedAudioDeviceRestorationStore.recordBufferFrameSize(
                uid: restoration.uid,
                originalFrameSize: restoration.originalFrameSize,
                at: restorationStoreURL
            )
            state.bufferFrameSizeRestorations[output.uid] = restoration
        }

        // Keep our replay muted while we claim and reconfigure the device. The ORDER matters:
        // start our output IOProc (so GlassEQ owns the device) BEFORE writing the buffer size.
        // Writing the buffer size restarts the device's hardware stream; doing it after we own
        // the device means that restart re-engages our (muted) IOProc instead of briefly
        // replaying the un-muted system mix. The buffer write's own property-change notification
        // is ignored via CoreAudioSelfChangeGuard, so it no longer triggers a rebuild loop.
        runtime.muteOutputForTransition()

        // Multi-channel devices play the stereo stream on their preferred stereo pair (the same
        // channels macOS routes system audio to); every other channel receives silence. The pair
        // must be stored before AudioDeviceStart so the first callback already maps correctly.
        let preferredChannels = try? CoreAudioDeviceQuery.preferredStereoChannels(objectID: matchedOutput.id)
        let channelPair = Self.playbackStereoPair(
            preferredChannels: preferredChannels,
            outputChannelCount: matchedOutput.outputChannelCount
        )
        runtime.setPlaybackChannelPair(left: channelPair.left, right: channelPair.right)

        guard let outputIOProcID = try createOutputIOProc(deviceID: matchedOutput.id, runtime: runtime) else {
            throw CoreAudioError(operation: "AudioDeviceCreateIOProcID(default output)", status: kAudioHardwareUnspecifiedError)
        }
        do {
            try checkOSStatus(
                AudioDeviceStart(matchedOutput.id, outputIOProcID),
                operation: "AudioDeviceStart(default output)"
            )
        } catch {
            _ = AudioDeviceDestroyIOProcID(matchedOutput.id, outputIOProcID)
            throw error
        }
        state.outputIOProcID = outputIOProcID

        // Now that our output owns the device, apply the low-latency buffer size. The stream
        // restart it triggers happens under our muted IOProc, so it plays silence, not dry audio.
        let tunedOutput = tuneBufferFrameSize(for: matchedOutput)

        // Unmute and re-anchor playback to the freshest captured audio on the new device.
        runtime.reprimePlayback()

        state.activeOutput = tunedOutput
        state.activeProfile = preparation.profile
    }

    private func stopOutputHalfLocked(_ state: inout ControlState) {
        state.outputRebuildGeneration += 1
        if let output = state.activeOutput, let outputIOProcID = state.outputIOProcID {
            _ = AudioDeviceStop(output.id, outputIOProcID)
            _ = AudioDeviceDestroyIOProcID(output.id, outputIOProcID)
        }
        state.outputIOProcID = nil
        restoreDeviceSettingsIfNeeded(&state)
        state.activeOutput = nil
    }

    private func forceSampleRate(
        _ sampleRate: Double,
        on output: AudioOutputDevice
    ) throws -> AudioOutputDevice {
        guard sampleRate > 0, abs(output.nominalSampleRate - sampleRate) >= 1 else {
            return output
        }
        try CoreAudioDeviceQuery.setNominalSampleRate(sampleRate, objectID: output.id)
        for _ in 0..<3 {
            let freshOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
            if abs(freshOutput.nominalSampleRate - sampleRate) < 1 {
                return freshOutput
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let freshOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
        throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
            output.id,
            "output sample rate \(freshOutput.nominalSampleRate) does not match tap sample rate \(sampleRate)"
        )
    }

    private func recordSampleRateRestorationIfNeeded(
        for output: AudioOutputDevice,
        state: inout ControlState
    ) throws {
        guard state.sampleRateRestorations[output.uid] == nil else {
            return
        }
        let restoration = SampleRateRestoration(
            uid: output.uid,
            originalSampleRate: output.nominalSampleRate
        )
        try PersistedAudioDeviceRestorationStore.recordSampleRate(
            uid: restoration.uid,
            originalSampleRate: restoration.originalSampleRate,
            at: restorationStoreURL
        )
        state.sampleRateRestorations[output.uid] = restoration
    }

    static func setSampleRateAfterRecordingRestoration(
        _ sampleRate: Double,
        on output: AudioOutputDevice,
        needsRestoration: Bool,
        recordRestoration: (SampleRateRestoration) throws -> Void,
        installRestoration: (SampleRateRestoration) -> Void,
        setSampleRate: (Double, AudioObjectID) throws -> Void
    ) throws {
        if needsRestoration {
            let restoration = SampleRateRestoration(
                uid: output.uid,
                originalSampleRate: output.nominalSampleRate
            )
            try recordRestoration(restoration)
            installRestoration(restoration)
        }
        try setSampleRate(sampleRate, output.id)
    }

    private func restoreDeviceSettingsIfNeeded(_ state: inout ControlState) {
        var restoredSampleRateUIDs: [String] = []
        for (uid, restoration) in state.sampleRateRestorations {
            if Self.restoreSampleRateRestoration(restoration) {
                try? PersistedAudioDeviceRestorationStore.clearSampleRate(uid: uid, at: restorationStoreURL)
                restoredSampleRateUIDs.append(uid)
            }
        }
        for uid in restoredSampleRateUIDs {
            state.sampleRateRestorations.removeValue(forKey: uid)
        }

        var restoredBufferFrameSizeUIDs: [String] = []
        for (uid, restoration) in state.bufferFrameSizeRestorations {
            if Self.restoreBufferFrameSizeRestoration(restoration) {
                try? PersistedAudioDeviceRestorationStore.clearBufferFrameSize(uid: uid, at: restorationStoreURL)
                restoredBufferFrameSizeUIDs.append(uid)
            }
        }
        for uid in restoredBufferFrameSizeUIDs {
            state.bufferFrameSizeRestorations.removeValue(forKey: uid)
        }
    }

    static func restoreSampleRateRestoration(
        _ restoration: SampleRateRestoration,
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.outputDevice(uid:),
        setSampleRate: (Double, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setNominalSampleRate(_:objectID:)
    ) -> Bool {
        do {
            guard let output = try outputForUID(restoration.uid) else {
                return false
            }
            guard abs(output.nominalSampleRate - restoration.originalSampleRate) >= 1 else {
                return true
            }
            try setSampleRate(restoration.originalSampleRate, output.id)
            guard let verifiedOutput = try outputForUID(restoration.uid) else {
                return false
            }
            return abs(verifiedOutput.nominalSampleRate - restoration.originalSampleRate) < 1
        } catch {
            return false
        }
    }

    static func restoreBufferFrameSizeRestoration(
        _ restoration: BufferFrameSizeRestoration,
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.outputDevice(uid:),
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setBufferFrameSize(_:objectID:)
    ) -> Bool {
        do {
            guard let output = try outputForUID(restoration.uid) else {
                return false
            }
            guard output.bufferFrameSize != restoration.originalFrameSize else {
                return true
            }
            try setBufferFrameSize(restoration.originalFrameSize, output.id)
            guard let verifiedOutput = try outputForUID(restoration.uid) else {
                return false
            }
            return verifiedOutput.bufferFrameSize == restoration.originalFrameSize
        } catch {
            return false
        }
    }

    static func restorePersistedDeviceSettings(
        at url: URL,
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.outputDevice(uid:),
        setSampleRate: (Double, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setNominalSampleRate(_:objectID:),
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setBufferFrameSize(_:objectID:)
    ) {
        var records = PersistedAudioDeviceRestorationStore.load(from: url)
        guard !records.isEmpty else {
            return
        }

        for (uid, record) in records {
            var updated = record
            if let originalSampleRate = record.originalSampleRate,
               restoreSampleRateRestoration(
                   SampleRateRestoration(uid: uid, originalSampleRate: originalSampleRate),
                   outputForUID: outputForUID,
                   setSampleRate: setSampleRate
               ) {
                updated.originalSampleRate = nil
            }
            if let originalBufferFrameSize = record.originalBufferFrameSize,
               restoreBufferFrameSizeRestoration(
                   BufferFrameSizeRestoration(uid: uid, originalFrameSize: originalBufferFrameSize),
                   outputForUID: outputForUID,
                   setBufferFrameSize: setBufferFrameSize
               ) {
                updated.originalBufferFrameSize = nil
            }
            records[uid] = updated.isEmpty ? nil : updated
        }

        try? PersistedAudioDeviceRestorationStore.save(records, to: url)
    }

    private static func dspProfile(from profile: EQProfile) -> EQProfile {
        var profile = profile
        profile.isBypassed = false
        return profile
    }

    private func audioEngineFailure(from error: Error) -> AudioEngineFailure {
        if let coreAudioError = error as? CoreAudioError {
            return classifyCoreAudioError(coreAudioError)
        }
        if let availabilityError = error as? AudioDeviceAvailabilityError {
            if case .unsupportedOutputChannelCount = availabilityError {
                return AudioEngineFailure(
                    category: .deviceFormatUnsupported,
                    userMessage: availabilityError.description,
                    operation: "CoreAudioDeviceQuery"
                )
            }
            return AudioEngineFailure(
                category: .outputDeviceUnavailable,
                userMessage: availabilityError.description,
                operation: "CoreAudioDeviceQuery"
            )
        }
        return AudioEngineFailure(
            category: .coreAudioOperationFailed,
            userMessage: String(describing: error),
            operation: "SystemTapAudioEngine"
        )
    }

    static func supportedRuntimeChannelCount(for output: AudioOutputDevice) throws -> Int {
        guard output.outputChannelCount > 0 else {
            throw AudioDeviceAvailabilityError.outputDeviceHasNoOutputChannels(output.id)
        }
        guard output.outputChannelCount <= 2 else {
            throw AudioDeviceAvailabilityError.unsupportedOutputChannelCount(output.id, output.outputChannelCount)
        }
        return output.outputChannelCount
    }

    /// Normalizes a device-reported preferred stereo pair (1-based channel numbers; the HAL
    /// reports zeros when the pair was never configured) into 0-based destination channel
    /// indices. Falls back to the first two channels whenever the report is missing or
    /// inconsistent; mono devices collapse to (0, 0).
    static func playbackStereoPair(
        preferredChannels: (left: UInt32, right: UInt32)?,
        outputChannelCount: Int
    ) -> (left: Int, right: Int) {
        guard outputChannelCount > 1 else {
            return outputChannelCount == 1 ? (0, 0) : (0, 1)
        }
        guard let preferredChannels,
              preferredChannels.left >= 1,
              preferredChannels.right >= 1,
              preferredChannels.left != preferredChannels.right,
              preferredChannels.left <= UInt32(outputChannelCount),
              preferredChannels.right <= UInt32(outputChannelCount) else {
            return (0, 1)
        }
        return (Int(preferredChannels.left) - 1, Int(preferredChannels.right) - 1)
    }

    static func encodedPlaybackChannelPair(left: Int, right: Int) -> UInt64 {
        let maxChannelIndex = CoreAudioDeviceQuery.maxChannelCount - 1
        let clampedLeft = UInt64(min(max(left, 0), maxChannelIndex))
        let clampedRight = UInt64(min(max(right, 0), maxChannelIndex))
        return (clampedLeft << 32) | clampedRight
    }

    static func decodedPlaybackChannelPair(_ encoded: UInt64) -> (left: Int, right: Int) {
        (Int(encoded >> 32), Int(encoded & 0xFFFF_FFFF))
    }

    static func performAfterRuntimeChannelValidation<T>(
        for output: AudioOutputDevice,
        _ operation: () throws -> T
    ) throws -> T {
        _ = try supportedRuntimeChannelCount(for: output)
        return try operation()
    }

    static func monoDownmix(
        _ samples: UnsafeBufferPointer<Float>,
        frame: Int,
        sourceChannelCount: Int
    ) -> Float {
        guard frame >= 0 else {
            return 0
        }
        let sourceChannelCount = max(sourceChannelCount, 1)
        let sampleBaseResult = frame.multipliedReportingOverflow(by: sourceChannelCount)
        guard !sampleBaseResult.overflow else {
            return 0
        }
        let sampleBase = sampleBaseResult.partialValue
        guard sampleBase >= 0,
              sampleBase < samples.count else {
            return 0
        }
        guard sourceChannelCount > 1,
              sampleBase + 1 < samples.count else {
            return samples[sampleBase]
        }
        return (samples[sampleBase] + samples[sampleBase + 1]) * 0.5
    }

    static func copyInterleavedSamples(
        _ samples: UnsafeBufferPointer<Float>,
        sourceFrameOffset: Int,
        destinationFrameOffset: Int,
        frameCount: Int,
        sourceChannelCount: Int,
        destinationLeftChannel: Int = 0,
        destinationRightChannel: Int = 1,
        to buffers: UnsafeMutableAudioBufferListPointer
    ) {
        let sourceChannelCount = max(sourceChannelCount, 1)
        if buffers.count == 1,
           let data = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           Int(buffers[0].mNumberChannels) == 1,
           sourceChannelCount > 1,
           frameCount > 0,
           sourceFrameOffset >= 0,
           destinationFrameOffset >= 0 {
            let destinationSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride
            for frameIndex in 0..<frameCount where destinationFrameOffset + frameIndex < destinationSamples {
                data[destinationFrameOffset + frameIndex] = monoDownmix(
                    samples,
                    frame: sourceFrameOffset + frameIndex,
                    sourceChannelCount: sourceChannelCount
                )
            }
            return
        }

        if buffers.count == 1,
           let data = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           Int(buffers[0].mNumberChannels) == sourceChannelCount,
           destinationLeftChannel == 0,
           destinationRightChannel == 1,
           frameCount > 0,
           sourceFrameOffset >= 0,
           destinationFrameOffset >= 0 {
            let copySamples = frameCount * sourceChannelCount
            let sourceSampleStart = sourceFrameOffset * sourceChannelCount
            let destinationSampleStart = destinationFrameOffset * sourceChannelCount
            let destinationSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride
            if sourceSampleStart + copySamples <= samples.count,
               destinationSampleStart + copySamples <= destinationSamples,
               let source = samples.baseAddress {
                data.advanced(by: destinationSampleStart)
                    .update(from: source.advanced(by: sourceSampleStart), count: copySamples)
                return
            }
        }

        // General mapped case: the destination pair channels receive source L/R (mono sources
        // feed both); every other channel gets explicit zeros. Never trust HAL pre-zeroing —
        // stray signal would leak into a multi-channel interface's DAW/loopback channels.
        // Walks the AudioBufferList with a running global channel offset so interleaved,
        // multi-stream, and per-channel-buffer layouts all map correctly.
        guard frameCount > 0, sourceFrameOffset >= 0, destinationFrameOffset >= 0 else {
            return
        }
        let sourceRightChannel = min(1, sourceChannelCount - 1)
        var globalChannelOffset = 0
        for bufferIndex in buffers.indices {
            let bufferChannels = Int(buffers[bufferIndex].mNumberChannels)
            guard bufferChannels > 0,
                  let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else {
                globalChannelOffset += max(bufferChannels, 0)
                continue
            }
            let destinationSampleCount = Int(buffers[bufferIndex].mDataByteSize) / MemoryLayout<Float>.stride
            let zeroStart = destinationFrameOffset * bufferChannels
            let zeroEnd = min((destinationFrameOffset + frameCount) * bufferChannels, destinationSampleCount)
            if zeroStart < zeroEnd {
                data.advanced(by: zeroStart).update(repeating: 0, count: zeroEnd - zeroStart)
            }
            scatterMappedChannel(
                samples,
                sourceChannel: 0,
                sourceFrameOffset: sourceFrameOffset,
                sourceChannelCount: sourceChannelCount,
                localChannel: destinationLeftChannel - globalChannelOffset,
                destinationFrameOffset: destinationFrameOffset,
                frameCount: frameCount,
                bufferChannels: bufferChannels,
                destinationSampleCount: destinationSampleCount,
                into: data
            )
            scatterMappedChannel(
                samples,
                sourceChannel: sourceRightChannel,
                sourceFrameOffset: sourceFrameOffset,
                sourceChannelCount: sourceChannelCount,
                localChannel: destinationRightChannel - globalChannelOffset,
                destinationFrameOffset: destinationFrameOffset,
                frameCount: frameCount,
                bufferChannels: bufferChannels,
                destinationSampleCount: destinationSampleCount,
                into: data
            )
            globalChannelOffset += bufferChannels
        }
    }

    private static func scatterMappedChannel(
        _ samples: UnsafeBufferPointer<Float>,
        sourceChannel: Int,
        sourceFrameOffset: Int,
        sourceChannelCount: Int,
        localChannel: Int,
        destinationFrameOffset: Int,
        frameCount: Int,
        bufferChannels: Int,
        destinationSampleCount: Int,
        into data: UnsafeMutablePointer<Float>
    ) {
        guard localChannel >= 0, localChannel < bufferChannels else {
            return
        }
        for frameIndex in 0..<frameCount {
            let sourceIndex = (sourceFrameOffset + frameIndex) * sourceChannelCount + sourceChannel
            guard sourceIndex < samples.count else {
                continue
            }
            let destinationIndex = (destinationFrameOffset + frameIndex) * bufferChannels + localChannel
            guard destinationIndex < destinationSampleCount else {
                continue
            }
            data[destinationIndex] = samples[sourceIndex]
        }
    }

    static func performTopologyRebuild<T>(
        acquireMuteGuard: () throws -> any TopologyRebuildMuteGuarding,
        rebuild: () throws -> T
    ) throws -> T {
        let muteGuard: any TopologyRebuildMuteGuarding
        do {
            muteGuard = try acquireMuteGuard()
        } catch {
            throw TopologyRebuildMuteGuardUnavailable(underlyingError: error)
        }
        defer {
            muteGuard.release()
        }
        return try rebuild()
    }

    private func tuneBufferFrameSize(for output: AudioOutputDevice) -> AudioOutputDevice {
        do {
            let range = try CoreAudioDeviceQuery.bufferFrameSizeRangeValue(objectID: output.id)
            let requested = clampedBufferFrameSize(
                Self.preferredBufferFrameSize(for: output),
                range: range
            )
            guard requested != output.bufferFrameSize else {
                return output
            }
            try CoreAudioDeviceQuery.setBufferFrameSize(requested, objectID: output.id)
            return try CoreAudioDeviceQuery.outputDevice(id: output.id)
        } catch {
            return output
        }
    }

    static func preferredBufferFrameSize(for output: AudioOutputDevice) -> UInt32 {
        if isLowSampleRateRoute(output) {
            return Self.preferredLowSampleRateBufferFrameSize
        }
        if output.isBluetoothTransport {
            return Self.preferredBluetoothBufferFrameSize
        }
        // Low-latency: request a small output buffer rather than keeping the device's larger
        // default. Clamped to the device's supported range by the caller (tuneBufferFrameSize).
        return Self.preferredBufferFrameSize
    }

    private static func isLowSampleRateRoute(_ output: AudioOutputDevice) -> Bool {
        output.nominalSampleRate > 0 && output.nominalSampleRate <= Self.lowSampleRateThreshold
    }

    private func clampedBufferFrameSize(_ frameSize: UInt32, range: AudioBufferFrameSizeRange) -> UInt32 {
        min(max(frameSize, range.minimum), range.maximum)
    }

    private func createTopologyRebuildMuteGuard() throws -> any TopologyRebuildMuteGuarding {
        let tapID = try createSystemTap(name: "GlassEQ Profile Rebuild Mute Tap")
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?

        do {
            aggregateDeviceID = try createPrivateAggregateDevice(tapID: tapID)
            ioProcID = try createSilenceIOProc(deviceID: aggregateDeviceID)
            try checkOSStatus(
                AudioDeviceStart(aggregateDeviceID, ioProcID),
                operation: "AudioDeviceStart(profile rebuild mute tap)"
            )
            return CoreAudioTopologyRebuildMuteGuard(
                tapID: tapID,
                aggregateDeviceID: aggregateDeviceID,
                ioProcID: ioProcID
            )
        } catch {
            if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
                _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            if aggregateDeviceID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            }
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    private func createSystemTap(name: String = "GlassEQ System Output Tap") throws -> AudioObjectID {
        let ownProcess = try currentAudioProcessObjectID()
        // Global tap (not bound to a device): one muted tap removes the dry system mix from
        // every output device and survives default-output switches without rebuild, so dry
        // audio never leaks to a newly selected device during the route handoff. Verified on
        // hardware across built-in / USB / Bluetooth / HDMI and 44.1k–192k device rates.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.name = name
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.muted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try checkOSStatus(
            AudioHardwareCreateProcessTap(description, &tapID),
            operation: "AudioHardwareCreateProcessTap"
        )
        return tapID
    }

    private func tapStreamFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd),
            operation: "AudioObjectGetPropertyData(tap format)"
        )
        try CoreAudioDeviceQuery.validatePropertySize(
            actual: size,
            expected: UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            operation: "AudioObjectGetPropertyData(tap format)",
            objectID: tapID
        )
        return asbd
    }

    private func createPrivateAggregateDevice(tapID: AudioObjectID) throws -> AudioObjectID {
        let tapUID = try tapUID(tapID)
        let aggregateUID = "com.glasseq.aggregate.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "GlassEQ Private Tap Device",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try checkOSStatus(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
            operation: "AudioHardwareCreateAggregateDevice"
        )
        return deviceID
    }

    private func createCaptureIOProc(deviceID: AudioObjectID, runtime: AudioRuntime) throws -> AudioDeviceIOProcID? {
        var ioProcID: AudioDeviceIOProcID?

        try checkOSStatus(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, inputData, _, outputData, _ in
                runtime.capture(inputData: inputData)
                runtime.clear(outputData: outputData)
            },
            operation: "AudioDeviceCreateIOProcIDWithBlock(capture)"
        )

        return ioProcID
    }

    private func createSilenceIOProc(deviceID: AudioObjectID) throws -> AudioDeviceIOProcID? {
        var ioProcID: AudioDeviceIOProcID?

        try checkOSStatus(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, _, _, outputData, _ in
                Self.clear(outputData: outputData)
            },
            operation: "AudioDeviceCreateIOProcIDWithBlock(profile rebuild mute tap)"
        )

        return ioProcID
    }

    private func createOutputIOProc(deviceID: AudioObjectID, runtime: AudioRuntime) throws -> AudioDeviceIOProcID? {
        var ioProcID: AudioDeviceIOProcID?

        try checkOSStatus(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, _, _, outputData, _ in
                runtime.playback(outputData: outputData)
            },
            operation: "AudioDeviceCreateIOProcIDWithBlock(output)"
        )

        return ioProcID
    }

    private static func clear(outputData: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
            guard let data = buffer.mData else {
                continue
            }
            let byteCount = Int(buffer.mDataByteSize)
            let maxByteCount = Int(CoreAudioDeviceQuery.maxBufferFrameSize)
                * CoreAudioDeviceQuery.maxChannelCount
                * MemoryLayout<Float>.stride
            guard byteCount >= 0,
                  byteCount <= maxByteCount else {
                continue
            }
            data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        }
    }

    private func tapUID(_ tapID: AudioObjectID) throws -> String {
        try CoreAudioDeviceQuery.getStringProperty(
            objectID: tapID,
            selector: kAudioTapPropertyUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private func currentAudioProcessObjectID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        try checkOSStatus(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                &pid,
                &size,
                &processID
            ),
            operation: "AudioObjectGetPropertyData(translate pid)"
        )

        guard processID != kAudioObjectUnknown else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                AudioObjectID(kAudioObjectSystemObject),
                "current audio process object is unknown"
            )
        }
        return processID
    }
}
