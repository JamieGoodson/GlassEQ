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
    public var minimumPlaybackBufferedFrames: Int
    public var averagePlaybackBufferedFrames: Double
    public var playbackBufferObservations: UInt64

    public init(
        capturedFrames: UInt64 = 0,
        playedFrames: UInt64 = 0,
        playbackUnderrunFrames: UInt64 = 0,
        saturatedSamples: UInt64 = 0,
        currentBufferedFrames: Int = 0,
        maxBufferedFrames: Int = 0,
        minimumPlaybackBufferedFrames: Int = 0,
        averagePlaybackBufferedFrames: Double = 0,
        playbackBufferObservations: UInt64 = 0
    ) {
        self.capturedFrames = capturedFrames
        self.playedFrames = playedFrames
        self.playbackUnderrunFrames = playbackUnderrunFrames
        self.saturatedSamples = saturatedSamples
        self.currentBufferedFrames = currentBufferedFrames
        self.maxBufferedFrames = maxBufferedFrames
        self.minimumPlaybackBufferedFrames = minimumPlaybackBufferedFrames
        self.averagePlaybackBufferedFrames = averagePlaybackBufferedFrames
        self.playbackBufferObservations = playbackBufferObservations
    }
}

public final class SystemTapAudioEngine: @unchecked Sendable {
    private static let preferredBufferFrameSize: UInt32 = 256
    private static let preferredBluetoothBufferFrameSize: UInt32 = 512
    private static let preferredLowSampleRateBufferFrameSize: UInt32 = 1024
    private static let minimumRingBufferFrames = 2048
    private static let minimumLowSampleRateRingBufferFrames = 2048
    private static let maximumRuntimeBufferFrameSize: UInt32 = 1024
    private static let maximumPlaybackPrimeFrames = 1024
    private static let lowSampleRateThreshold = 24_000.0

    private struct ControlState {
        var state: AudioEngineState = .stopped
        var status: AudioEngineStatus = .stopped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var captureIOProcID: AudioDeviceIOProcID?
        var outputIOProcID: AudioDeviceIOProcID?
        var activeOutput: AudioOutputDevice?
        var activeProfile: EQProfile?
        var bufferFrameSizeRestoration: BufferFrameSizeRestoration?
        var runtime: AudioRuntime?
    }

    private struct BufferFrameSizeRestoration: Sendable {
        var deviceID: AudioObjectID
        var uid: String
        var originalFrameSize: UInt32
    }

    private final class PreparedDSPConfigBox: @unchecked Sendable {
        let config: EQRenderConfiguration
        var nextRetiredPointer: UInt = 0

        init(config: EQRenderConfiguration) {
            self.config = config
        }
    }

    private final class AudioRuntime: @unchecked Sendable {
        let ringBuffer: RealtimeAudioRingBuffer
        let channelCount: Int
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
        private let minPlaybackBufferedFrames = Atomic<Int>(Int.max)
        private let totalPlaybackBufferedFrames = Atomic<UInt64>(0)
        private let playbackBufferObservations = Atomic<UInt64>(0)
        private let bypassEnabled: Atomic<Bool>
        private let playbackPriming = Atomic<Bool>(true)
        private let outputMutedForTransition = Atomic<Bool>(false)
        private let pendingDSPConfigPointer = Atomic<UInt>(0)
        private let retiredDSPConfigHeadPointer = Atomic<UInt>(0)
        private let stopping = Atomic<Bool>(false)
        private let captureInCallback = Atomic<Bool>(false)
        private let playbackInCallback = Atomic<Bool>(false)

        init(
            profile: EQProfile,
            sampleRate: Double,
            channelCount: Int,
            ringCapacityFrames: Int,
            scratchFrames: Int,
            playbackPrimeFrames: Int
        ) {
            self.channelCount = max(channelCount, 1)
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
            outputMutedForTransition.store(true, ordering: .relaxed)
            playbackPriming.store(true, ordering: .relaxed)
        }

        func setBypassed(_ isBypassed: Bool) {
            bypassEnabled.store(isBypassed, ordering: .relaxed)
        }

        func muteOutputForTransition() {
            outputMutedForTransition.store(true, ordering: .relaxed)
            playbackPriming.store(true, ordering: .relaxed)
        }

        func resetMetrics() {
            capturedFrames.store(0, ordering: .relaxed)
            playedFrames.store(0, ordering: .relaxed)
            playbackUnderrunFrames.store(0, ordering: .relaxed)
            saturatedSamples.store(0, ordering: .relaxed)
            maxBufferedFrames.store(0, ordering: .relaxed)
            minPlaybackBufferedFrames.store(Int.max, ordering: .relaxed)
            totalPlaybackBufferedFrames.store(0, ordering: .relaxed)
            playbackBufferObservations.store(0, ordering: .relaxed)
            playbackPriming.store(true, ordering: .relaxed)
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
                minimumPlaybackBufferedFrames: observations == 0 ? 0 : minimumBufferedFrames,
                averagePlaybackBufferedFrames: observations == 0
                    ? 0
                    : Double(totalPlaybackBufferedFrames.load(ordering: .relaxed)) / Double(observations),
                playbackBufferObservations: observations
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

            if outputMutedForTransition.load(ordering: .relaxed) {
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

            if outputMutedForTransition.load(ordering: .relaxed) {
                clear(outputData: outputData)
                return
            }

            if playbackPriming.load(ordering: .relaxed) {
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
                playbackPriming.store(false, ordering: .relaxed)
            }

            recordPlaybackBufferedFrames(ringBuffer.occupancyFrames())

            var underrunFrames = 0
            if let outputSamples = contiguousInterleavedOutputBuffer(
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
                            to: outputBuffers
                        )
                        frameOffset += chunkFrames
                    }
                }
            }

            if underrunFrames > 0 {
                playbackUnderrunFrames.wrappingAdd(UInt64(underrunFrames), ordering: .relaxed)
                playbackPriming.store(true, ordering: .relaxed)
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
            processor.applyPreparedConfiguration(box.config)
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
            var current = maxBufferedFrames.load(ordering: .relaxed)
            while occupancy > current {
                let result = maxBufferedFrames.compareExchange(
                    expected: current,
                    desired: occupancy,
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
            to buffers: UnsafeMutableAudioBufferListPointer
        ) {
            let sourceChannelCount = max(sourceChannelCount, 1)
            if buffers.count == 1,
               let data = buffers[0].mData?.assumingMemoryBound(to: Float.self),
               Int(buffers[0].mNumberChannels) == sourceChannelCount,
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

            for bufferIndex in buffers.indices {
                guard let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else {
                    continue
                }
                let sourceChannel = min(bufferIndex, sourceChannelCount - 1)
                let destinationSampleCount = Int(buffers[bufferIndex].mDataByteSize) / MemoryLayout<Float>.stride
                for frameIndex in 0..<frameCount where destinationFrameOffset + frameIndex < destinationSampleCount {
                    let sourceIndex = (sourceFrameOffset + frameIndex) * sourceChannelCount + sourceChannel
                    guard sourceIndex < samples.count else {
                        continue
                    }
                    data[destinationFrameOffset + frameIndex] = samples[sourceIndex]
                }
            }
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

    public var state: AudioEngineState {
        control.withLock { $0.state }
    }

    public var status: AudioEngineStatus {
        control.withLock { $0.status }
    }

    public init() {}

    deinit {
        stop()
    }

    public func start(output: AudioOutputDevice, profile: EQProfile) throws {
        try control.withLock { state in
            let shouldRestoreBeforeRestart = Self.shouldRestoreBufferFrameSizeBeforeRestart(
                currentOutput: state.activeOutput,
                nextOutput: output
            )
            stopLocked(&state, restoreBufferFrameSizes: shouldRestoreBeforeRestart)
            state.state = .stopped
            state.status = .starting

            do {
                if state.bufferFrameSizeRestoration == nil {
                    state.bufferFrameSizeRestoration = BufferFrameSizeRestoration(
                        deviceID: output.id,
                        uid: output.uid,
                        originalFrameSize: output.bufferFrameSize
                    )
                }
                let tunedOutput = tuneBufferFrameSize(for: output)
                let channelCount = try Self.supportedRuntimeChannelCount(for: tunedOutput)
                let runtimeBufferFrameSize = Self.runtimeBufferFrameSize(for: tunedOutput)
                let ringCapacityFrames = max(Int(runtimeBufferFrameSize) * 3, minimumRingBufferFrames(for: tunedOutput))
                let scratchFrames = max(Int(runtimeBufferFrameSize), Self.minimumRingBufferFrames)
                let playbackPrimeFrames = min(
                    ringCapacityFrames,
                    Self.minimumPrimeFrames(for: tunedOutput, runtimeBufferFrameSize: runtimeBufferFrameSize)
                )
                let runtime = AudioRuntime(
                    profile: profile,
                    sampleRate: tunedOutput.nominalSampleRate,
                    channelCount: channelCount,
                    ringCapacityFrames: ringCapacityFrames,
                    scratchFrames: scratchFrames,
                    playbackPrimeFrames: playbackPrimeFrames
                )

                state.activeOutput = tunedOutput
                state.activeProfile = profile
                state.runtime = runtime
                state.tapID = try createSystemTap(output: tunedOutput)
                state.aggregateDeviceID = try createPrivateAggregateDevice(tapID: state.tapID)
                state.captureIOProcID = try createCaptureIOProc(deviceID: state.aggregateDeviceID, runtime: runtime)
                state.outputIOProcID = try createOutputIOProc(deviceID: tunedOutput.id, runtime: runtime)
                try checkOSStatus(AudioDeviceStart(state.aggregateDeviceID, state.captureIOProcID), operation: "AudioDeviceStart(capture tap)")
                try checkOSStatus(AudioDeviceStart(tunedOutput.id, state.outputIOProcID), operation: "AudioDeviceStart(default output)")

                state.state = .running(output: tunedOutput)
                state.status = .running(output: tunedOutput)
            } catch {
                let failure = audioEngineFailure(from: error)
                stopLocked(&state, restoreBufferFrameSizes: true)
                state.state = .failed(failure.description)
                if failure.category == .systemAudioCapturePermission {
                    state.status = .permissionRequired(failure)
                } else {
                    state.status = .failed(failure)
                }
                throw error
            }
        }
    }

    public func update(profile: EQProfile) throws {
        guard let output = control.withLock({ $0.activeOutput }) else {
            return
        }

        let freshOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
        try start(output: freshOutput, profile: profile)
    }

    @discardableResult
    public func updateDSP(profile: EQProfile) -> Bool {
        control.withLock { state in
            guard let output = state.activeOutput,
                  let activeProfile = state.activeProfile,
                  let runtime = state.runtime else {
                return false
            }

            guard Self.canHotSwapDSP(
                from: activeProfile,
                to: profile,
                sampleRate: output.nominalSampleRate,
                channelCount: runtime.channelCount
            ) else {
                return false
            }

            let preparedConfig = EQRenderConfiguration(
                profile: Self.dspProfile(from: profile),
                sampleRate: output.nominalSampleRate,
                channelCount: runtime.channelCount
            )
            runtime.drainDSPConfigBoxes()
            runtime.publishPendingDSPConfig(preparedConfig)
            runtime.setBypassed(profile.isBypassed)
            state.activeProfile = profile
            return true
        }
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
            stopLocked(&state, restoreBufferFrameSizes: true)
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

    private func stopLocked(_ state: inout ControlState, restoreBufferFrameSizes: Bool) {
        state.runtime?.markStopping()

        if let output = state.activeOutput, let outputIOProcID = state.outputIOProcID {
            _ = AudioDeviceStop(output.id, outputIOProcID)
            _ = AudioDeviceDestroyIOProcID(output.id, outputIOProcID)
        }

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

        if restoreBufferFrameSizes {
            restoreBufferFrameSizeIfNeeded(&state)
        }

        state.runtime?.drainDSPConfigBoxes()
        state.captureIOProcID = nil
        state.outputIOProcID = nil
        state.aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        state.tapID = AudioObjectID(kAudioObjectUnknown)
        state.activeOutput = nil
        state.activeProfile = nil
        state.runtime = nil
        state.state = .stopped
        state.status = .stopped
    }

    private func restoreBufferFrameSizeIfNeeded(_ state: inout ControlState) {
        guard let restoration = state.bufferFrameSizeRestoration else {
            return
        }
        defer {
            state.bufferFrameSizeRestoration = nil
        }

        guard let activeOutput = state.activeOutput,
              activeOutput.id == restoration.deviceID,
              activeOutput.uid == restoration.uid else {
            return
        }

        try? CoreAudioDeviceQuery.setBufferFrameSize(restoration.originalFrameSize, objectID: restoration.deviceID)
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

    static func shouldRestoreBufferFrameSizeBeforeRestart(
        currentOutput: AudioOutputDevice?,
        nextOutput: AudioOutputDevice
    ) -> Bool {
        guard let currentOutput else {
            return false
        }
        return currentOutput.id != nextOutput.id || currentOutput.uid != nextOutput.uid
    }

    static func runtimeBufferFrameSize(for output: AudioOutputDevice) -> UInt32 {
        min(max(output.bufferFrameSize, 1), Self.maximumRuntimeBufferFrameSize)
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
        return max(
            Self.preferredBufferFrameSize,
            min(output.bufferFrameSize, Self.maximumRuntimeBufferFrameSize)
        )
    }

    private func minimumRingBufferFrames(for output: AudioOutputDevice) -> Int {
        Self.isLowSampleRateRoute(output) ? Self.minimumLowSampleRateRingBufferFrames : Self.minimumRingBufferFrames
    }

    static func minimumPrimeFrames(for output: AudioOutputDevice, runtimeBufferFrameSize: UInt32) -> Int {
        let preferredPrimeFrames = isLowSampleRateRoute(output)
            ? Self.minimumLowSampleRateRingBufferFrames / 2
            : max(Self.minimumRingBufferFrames / 2, Int(runtimeBufferFrameSize) * 2)
        return min(max(Int(runtimeBufferFrameSize), preferredPrimeFrames), Self.maximumPlaybackPrimeFrames)
    }

    private static func isLowSampleRateRoute(_ output: AudioOutputDevice) -> Bool {
        output.nominalSampleRate > 0 && output.nominalSampleRate <= Self.lowSampleRateThreshold
    }

    private func clampedBufferFrameSize(_ frameSize: UInt32, range: AudioBufferFrameSizeRange) -> UInt32 {
        min(max(frameSize, range.minimum), range.maximum)
    }

    private func createSystemTap(output: AudioOutputDevice) throws -> AudioObjectID {
        let ownProcess = try currentAudioProcessObjectID()
        let description = CATapDescription(
            excludingProcesses: [ownProcess],
            deviceUID: output.uid,
            stream: 0
        )
        description.name = "GlassEQ System Output Tap"
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

        return processID
    }
}
