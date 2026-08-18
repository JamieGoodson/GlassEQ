import AudioToolbox
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
    public var droppedInputFrames: UInt64
    public var droppedBufferedFrames: UInt64
    public var ringGateContentionFailures: UInt64
    public var saturatedSamples: UInt64
    public var currentBufferedFrames: Int
    public var maxBufferedFrames: Int
    public var maximumPlaybackBufferedFrames: Int
    public var minimumPlaybackBufferedFrames: Int
    public var averagePlaybackBufferedFrames: Double
    public var playbackBufferObservations: UInt64
    public var maximumCaptureCallbackFrames: Int
    public var maximumPlaybackCallbackFrames: Int
    public var playbackTimestampDiscontinuities: UInt64
    public var playbackBufferRenegotiations: UInt64
    public var adaptivePlaybackRenderFailures: UInt64
    public var playbackRateCorrectionPPM: Double
    public var playbackRateCorrectionSaturated: Bool
    public var playbackOccupancyTargetFrames: Int
    public var filteredPlaybackOccupancyFrames: Double
    public var playbackBufferSampleRate: Double
    public var playbackSampleRateConversionActive: Bool

    public init(
        capturedFrames: UInt64 = 0,
        playedFrames: UInt64 = 0,
        playbackUnderrunFrames: UInt64 = 0,
        droppedInputFrames: UInt64 = 0,
        droppedBufferedFrames: UInt64 = 0,
        ringGateContentionFailures: UInt64 = 0,
        saturatedSamples: UInt64 = 0,
        currentBufferedFrames: Int = 0,
        maxBufferedFrames: Int = 0,
        maximumPlaybackBufferedFrames: Int = 0,
        minimumPlaybackBufferedFrames: Int = 0,
        averagePlaybackBufferedFrames: Double = 0,
        playbackBufferObservations: UInt64 = 0,
        maximumCaptureCallbackFrames: Int = 0,
        maximumPlaybackCallbackFrames: Int = 0,
        playbackTimestampDiscontinuities: UInt64 = 0,
        playbackBufferRenegotiations: UInt64 = 0,
        adaptivePlaybackRenderFailures: UInt64 = 0,
        playbackRateCorrectionPPM: Double = 0,
        playbackRateCorrectionSaturated: Bool = false,
        playbackOccupancyTargetFrames: Int = 0,
        filteredPlaybackOccupancyFrames: Double = 0,
        playbackBufferSampleRate: Double = 0,
        playbackSampleRateConversionActive: Bool = false
    ) {
        self.capturedFrames = capturedFrames
        self.playedFrames = playedFrames
        self.playbackUnderrunFrames = playbackUnderrunFrames
        self.droppedInputFrames = droppedInputFrames
        self.droppedBufferedFrames = droppedBufferedFrames
        self.ringGateContentionFailures = ringGateContentionFailures
        self.saturatedSamples = saturatedSamples
        self.currentBufferedFrames = currentBufferedFrames
        self.maxBufferedFrames = maxBufferedFrames
        self.maximumPlaybackBufferedFrames = maximumPlaybackBufferedFrames
        self.minimumPlaybackBufferedFrames = minimumPlaybackBufferedFrames
        self.averagePlaybackBufferedFrames = averagePlaybackBufferedFrames
        self.playbackBufferObservations = playbackBufferObservations
        self.maximumCaptureCallbackFrames = maximumCaptureCallbackFrames
        self.maximumPlaybackCallbackFrames = maximumPlaybackCallbackFrames
        self.playbackTimestampDiscontinuities = playbackTimestampDiscontinuities
        self.playbackBufferRenegotiations = playbackBufferRenegotiations
        self.adaptivePlaybackRenderFailures = adaptivePlaybackRenderFailures
        self.playbackRateCorrectionPPM = playbackRateCorrectionPPM
        self.playbackRateCorrectionSaturated = playbackRateCorrectionSaturated
        self.playbackOccupancyTargetFrames = playbackOccupancyTargetFrames
        self.filteredPlaybackOccupancyFrames = filteredPlaybackOccupancyFrames
        self.playbackBufferSampleRate = playbackBufferSampleRate
        self.playbackSampleRateConversionActive = playbackSampleRateConversionActive
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
    private static let preferredBufferFrameSize: UInt32 = 64
    private static let preferredBluetoothBufferFrameSize: UInt32 = 64
    private static let preferredBluetoothPlaybackTargetFrames = 128
    // Leaves one preferred 64-frame capture callback after servicing a 64-frame output pull.
    private static let preferredBluetoothPlaybackReservoirFrames = 64
    private static let preferredLowSampleRateBufferFrameSize: UInt32 = 1024
    // Converted headset routes need enough tap-rate audio to span one full admitted
    // capture callback even when the aggregate ignores the preferred 64-frame request.
    private static let preferredLowSampleRatePlaybackReservoirFrames = Int(maximumRuntimeBufferFrameSize)
    private static let preferredCaptureBufferFrameSize: UInt32 = 64
    private static let minimumRingBufferFrames = 2048
    private static let maximumRuntimeBufferFrameSize: UInt32 = 1024
    private static let maximumSupportedCallbackFrames = 8192
    // Capacity planning allows a 4:1 input/output rate ratio (above the current 48→16 kHz case)
    // and retains one additional full converted pull as drift headroom.
    private static let maximumPlannedPlaybackRateRatio = 4
    private static let playbackRingPullCount = 2
    private static let preferredPlaybackPrimeFrames = 128
    private static let lowSampleRateThreshold = 24_000.0
    private static let maximumPlannedPlaybackPrimeFrames =
        maximumSupportedCallbackFrames * maximumPlannedPlaybackRateRatio
            + maximumSupportedCallbackFrames
    static let runtimeRingCapacityFrames = max(
        minimumRingBufferFrames,
        maximumPlannedPlaybackPrimeFrames * playbackRingPullCount
    )

    private struct PlaybackBufferOperatingPointKey: Hashable {
        var outputUID: String
        var sampleRate: Int
        var tapSampleRate: Int
        var frameSize: UInt32

        init(output: AudioOutputDevice, tapSampleRate: Double) {
            self.outputUID = output.uid
            self.sampleRate = Int(output.nominalSampleRate.rounded())
            self.tapSampleRate = Int(tapSampleRate.rounded())
            self.frameSize = output.bufferFrameSize
        }
    }

    private struct PlaybackBufferRouteKey: Hashable {
        var outputUID: String
        var sampleRate: Int

        init(output: AudioOutputDevice) {
            self.outputUID = output.uid
            self.sampleRate = Int(output.nominalSampleRate.rounded())
        }
    }

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
        // Swappable output half (rebuilt per output device; low-rate headset modes are converted).
        var outputIOProcID: AudioDeviceIOProcID?
        var activeOutput: AudioOutputDevice?
        var activeProfile: EQProfile?
        var profileRevision: UInt64 = 0
        var bufferFrameSizeRestorations: [String: BufferFrameSizeRestoration] = [:]
        var sampleRateRestorations: [String: SampleRateRestoration] = [:]
        var outputRebuildGeneration = 0
        var handledPlaybackInstabilityGeneration: UInt64 = 0
        var playbackBufferCalibrationProbe: PlaybackBufferCalibrationProbe?
        var playbackBufferInstabilityPersistenceGate = PlaybackBufferInstabilityPersistenceGate()
        var attemptedPlaybackTargetDownProbes: Set<PlaybackBufferOperatingPointKey> = []
        var attemptedPlaybackFrameSizeDownProbes: Set<PlaybackBufferRouteKey> = []
        var adaptivePlaybackRenderRecoveryAttempts = 0
        var adaptivePlaybackRenderRecoveryHealthGeneration: UInt64?
    }

    private struct OutputRebuildPreparation {
        var generation: Int
        var output: AudioOutputDevice
        var profile: EQProfile
        var runtime: AudioRuntime
        var tapSampleRate: Double
        var originalBufferFrameSize: UInt32
        var profileRevision: UInt64
    }

    private struct PlaybackBufferRenegotiationPreparation {
        var outputRebuildGeneration: Int
        var reason: PlaybackBufferInstabilityReason
        var output: AudioOutputDevice
        var runtime: AudioRuntime
    }

    private struct OutputRebuildExpectation {
        var generation: Int
        var runtime: AudioRuntime
        var profileRevision: UInt64
    }

    private struct PlaybackBufferTargetAdjustment {
        var output: AudioOutputDevice
        var tapSampleRate: Double
        var previousTargetFrames: Int
        var targetFrames: Int
        var reason: PlaybackBufferInstabilityReason
    }

    private enum PlaybackBufferAdaptationAction {
        case stabilize(PlaybackBufferCalibrationProbe)
        case renegotiate(PlaybackBufferRenegotiationPreparation)
    }

    private enum AdaptivePlaybackRenderRecoveryAction {
        case restart(output: AudioOutputDevice, profile: EQProfile, expectation: OutputRebuildExpectation)
        case fail(AudioEngineFailure)
    }

    private struct StaleOutputRebuild: Error {}
    private struct StaleProfileRequest: Error {}

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

    private enum AdaptivePlaybackRenderResult {
        case rendered
        case underrun(frames: Int)
        case failed
    }

    private final class AudioRuntime: @unchecked Sendable {
        let ringBuffer: RealtimeAudioRingBuffer
        let channelCount: Int
        let sampleRate: Double
        private let playbackPrimeFrames: Atomic<Int>
        private let maxCallbackFrames: Int
        private var processor: EQProcessor
        private var captureScratchSamples: [Float]
        private var adaptiveInputSamples: [Float]
        private var sampleRateConverterInputSamples: UnsafeMutableBufferPointer<Float>
        private let adaptiveOutputSamples: UnsafeMutableBufferPointer<Float>
        private var playbackRateServo: PlaybackRateServo
        private var playbackResampler: HermitePlaybackResampler
        private var playbackSampleRatePlan: PlaybackSampleRatePlan
        private var playbackSampleRateConverter: RealtimePCMRateConverter?
        private var sampleRateConverterInputRatio = 1.0
        private var sampleRateConverterInputResult = AdaptivePlaybackRenderResult.rendered
        private var outputTimestampTracker = OutputCallbackTimestampTracker()

        private let capturedFrames = Atomic<UInt64>(0)
        private let playedFrames = Atomic<UInt64>(0)
        private let playbackUnderrunFrames = Atomic<UInt64>(0)
        private let droppedInputFrames = Atomic<UInt64>(0)
        private let droppedBufferedFrames = Atomic<UInt64>(0)
        private let saturatedSamples = Atomic<UInt64>(0)
        private let maxBufferedFrames = Atomic<Int>(0)
        private let maxPlaybackBufferedFrames = Atomic<Int>(0)
        private let minPlaybackBufferedFrames = Atomic<Int>(Int.max)
        private let totalPlaybackBufferedFrames = Atomic<UInt64>(0)
        private let playbackBufferObservations = Atomic<UInt64>(0)
        private let maxCaptureCallbackFrames = Atomic<Int>(0)
        private let maxPlaybackCallbackFrames = Atomic<Int>(0)
        private let playbackTimestampDiscontinuities = Atomic<UInt64>(0)
        private let playbackBufferRenegotiations = Atomic<UInt64>(0)
        private let adaptivePlaybackRenderFailures = Atomic<UInt64>(0)
        private let adaptivePlaybackRenderFailureActive = Atomic<Bool>(false)
        private let adaptivePlaybackRenderHealthGeneration = Atomic<UInt64>(0)
        private let playbackInstabilityGeneration = Atomic<UInt64>(0)
        private let latestPlaybackInstabilityReason = Atomic<UInt8>(PlaybackBufferInstabilityReason.underrun.rawValue)
        private let adaptivePlaybackTargetFrames: Atomic<Int>
        private let pendingPlaybackClockReset = Atomic<Bool>(true)
        private let pendingPlaybackTargetRetarget = Atomic<Bool>(false)
        private let playbackRateCorrectionPartsPerBillion = Atomic<Int64>(0)
        private let playbackRateCorrectionSaturated = Atomic<Bool>(false)
        private let filteredPlaybackOccupancyMilliFrames = Atomic<Int64>(0)
        private let sampleRateConversionActive = Atomic<Bool>(false)
        private let bypassEnabled: Atomic<Bool>
        private let playbackPriming = Atomic<Bool>(true)
        private let outputMutedForTransition = Atomic<Bool>(false)
        private let pendingPlaybackReset = Atomic<Bool>(false)
        private let pendingOutputTimestampReset = Atomic<Bool>(true)
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
            self.adaptiveInputSamples = Array(repeating: 0, count: (scratchFrames + 8) * self.channelCount)
            self.sampleRateConverterInputSamples = UnsafeMutableBufferPointer<Float>.allocate(
                capacity: self.channelCount
            )
            self.sampleRateConverterInputSamples.initialize(repeating: 0)
            self.adaptiveOutputSamples = UnsafeMutableBufferPointer<Float>.allocate(
                capacity: SystemTapAudioEngine.maximumSupportedCallbackFrames * self.channelCount
            )
            self.adaptiveOutputSamples.initialize(repeating: 0)
            self.playbackPrimeFrames = Atomic(max(playbackPrimeFrames, 1))
            self.adaptivePlaybackTargetFrames = Atomic(max(playbackPrimeFrames, 1))
            self.maxCallbackFrames = SystemTapAudioEngine.maximumSupportedCallbackFrames
            self.playbackRateServo = PlaybackRateServo(
                sampleRate: sampleRate,
                targetFrames: playbackPrimeFrames
            )
            self.playbackResampler = HermitePlaybackResampler(channelCount: self.channelCount)
            self.playbackSampleRatePlan = PlaybackSampleRatePlan(
                inputSampleRate: sampleRate,
                outputSampleRate: sampleRate
            )
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
            sampleRateConverterInputSamples.deinitialize()
            sampleRateConverterInputSamples.deallocate()
            adaptiveOutputSamples.deinitialize()
            adaptiveOutputSamples.deallocate()
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
            pendingOutputTimestampReset.store(true, ordering: .releasing)
        }

        // Stored by the control thread on every output rebuild, before the new output IOProc
        // starts, so the first callback on the new device already maps to the right channels.
        func setPlaybackChannelPair(left: Int, right: Int) {
            playbackChannelPair.store(
                SystemTapAudioEngine.encodedPlaybackChannelPair(left: left, right: right),
                ordering: .releasing
            )
        }

        func configurePlayback(
            primeFrames: Int,
            outputSampleRate: Double
        ) throws {
            let targetFrames = min(max(primeFrames, 1), ringBuffer.capacityFrames)
            let sampleRatePlan = PlaybackSampleRatePlan(
                inputSampleRate: sampleRate,
                outputSampleRate: outputSampleRate
            )
            let sampleRateConverter: RealtimePCMRateConverter? = if sampleRatePlan.requiresConversion {
                try RealtimePCMRateConverter(
                    inputSampleRate: sampleRatePlan.inputSampleRate,
                    outputSampleRate: sampleRatePlan.outputSampleRate,
                    channelCount: channelCount
                )
            } else {
                nil
            }
            let inputCapacityFrames = try sampleRateConverter?.inputFrameCapacity(
                forOutputFrames: maxCallbackFrames
            ) ?? 1
            let inputSamples = UnsafeMutableBufferPointer<Float>.allocate(
                capacity: inputCapacityFrames * channelCount
            )
            inputSamples.initialize(repeating: 0)

            sampleRateConverterInputSamples.deinitialize()
            sampleRateConverterInputSamples.deallocate()
            sampleRateConverterInputSamples = inputSamples
            playbackSampleRateConverter = sampleRateConverter
            playbackSampleRatePlan = sampleRatePlan
            sampleRateConversionActive.store(sampleRateConverter != nil, ordering: .releasing)
            adaptivePlaybackRenderFailureActive.store(false, ordering: .releasing)
            playbackPrimeFrames.store(targetFrames, ordering: .releasing)
            adaptivePlaybackTargetFrames.store(targetFrames, ordering: .releasing)
            pendingPlaybackTargetRetarget.store(false, ordering: .releasing)
            pendingPlaybackClockReset.store(true, ordering: .releasing)
            pendingOutputTimestampReset.store(true, ordering: .releasing)
        }

        func retargetPlayback(primeFrames: Int) {
            let targetFrames = min(max(primeFrames, 1), ringBuffer.capacityFrames)
            playbackPrimeFrames.store(targetFrames, ordering: .releasing)
            adaptivePlaybackTargetFrames.store(targetFrames, ordering: .releasing)
            pendingPlaybackTargetRetarget.store(true, ordering: .releasing)
            pendingOutputTimestampReset.store(true, ordering: .releasing)
        }

        func playbackTargetFrames() -> Int {
            adaptivePlaybackTargetFrames.load(ordering: .acquiring)
        }

        func maximumObservedCaptureCallbackFrames() -> Int {
            maxCaptureCallbackFrames.load(ordering: .relaxed)
        }

        func hasActiveAdaptivePlaybackRenderFailure() -> Bool {
            adaptivePlaybackRenderFailureActive.load(ordering: .acquiring)
        }

        func playbackRenderHealthGeneration() -> UInt64 {
            adaptivePlaybackRenderHealthGeneration.load(ordering: .acquiring)
        }

        // Called when a new output half is started. Clears any transition mute (the runtime
        // persists across output switches now, so the mute flag would otherwise stick on and
        // silence everything) and re-primes so playback re-anchors to the freshest audio.
        func reprimePlayback() {
            pendingPlaybackReset.store(true, ordering: .releasing)
            playbackPriming.store(true, ordering: .releasing)
            pendingOutputTimestampReset.store(true, ordering: .releasing)
            outputMutedForTransition.store(false, ordering: .releasing)
        }

        func playbackInstabilitySnapshot() -> (generation: UInt64, reason: PlaybackBufferInstabilityReason) {
            let generation = playbackInstabilityGeneration.load(ordering: .acquiring)
            let latestReason = PlaybackBufferInstabilityReason(
                rawValue: latestPlaybackInstabilityReason.load(ordering: .relaxed)
            ) ?? .underrun
            let reason = AdaptivePlaybackRenderRecoveryPolicy.effectiveInstabilityReason(
                latest: latestReason,
                renderFailureActive: adaptivePlaybackRenderFailureActive.load(ordering: .acquiring)
            )
            return (generation, reason)
        }

        func recordPlaybackBufferRenegotiation() {
            playbackBufferRenegotiations.wrappingAdd(1, ordering: .relaxed)
        }

        func resetMetrics() {
            capturedFrames.store(0, ordering: .relaxed)
            playedFrames.store(0, ordering: .relaxed)
            playbackUnderrunFrames.store(0, ordering: .relaxed)
            droppedInputFrames.store(0, ordering: .relaxed)
            droppedBufferedFrames.store(0, ordering: .relaxed)
            saturatedSamples.store(0, ordering: .relaxed)
            maxBufferedFrames.store(0, ordering: .relaxed)
            maxPlaybackBufferedFrames.store(0, ordering: .relaxed)
            minPlaybackBufferedFrames.store(Int.max, ordering: .relaxed)
            totalPlaybackBufferedFrames.store(0, ordering: .relaxed)
            playbackBufferObservations.store(0, ordering: .relaxed)
            maxCaptureCallbackFrames.store(0, ordering: .relaxed)
            maxPlaybackCallbackFrames.store(0, ordering: .relaxed)
            playbackTimestampDiscontinuities.store(0, ordering: .relaxed)
            playbackBufferRenegotiations.store(0, ordering: .relaxed)
            adaptivePlaybackRenderFailures.store(0, ordering: .relaxed)
            playbackRateCorrectionSaturated.store(false, ordering: .relaxed)
            ringBuffer.resetOverwriteGateContentionFailureCount()
            playbackPriming.store(true, ordering: .releasing)
        }

        func snapshotMetrics() -> AudioEngineMetrics {
            let observations = playbackBufferObservations.load(ordering: .relaxed)
            let minimumBufferedFrames = minPlaybackBufferedFrames.load(ordering: .relaxed)
            return AudioEngineMetrics(
                capturedFrames: capturedFrames.load(ordering: .relaxed),
                playedFrames: playedFrames.load(ordering: .relaxed),
                playbackUnderrunFrames: playbackUnderrunFrames.load(ordering: .relaxed),
                droppedInputFrames: droppedInputFrames.load(ordering: .relaxed),
                droppedBufferedFrames: droppedBufferedFrames.load(ordering: .relaxed),
                ringGateContentionFailures: ringBuffer.overwriteGateContentionFailureCount(),
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
                maximumPlaybackCallbackFrames: maxPlaybackCallbackFrames.load(ordering: .relaxed),
                playbackTimestampDiscontinuities: playbackTimestampDiscontinuities.load(ordering: .relaxed),
                playbackBufferRenegotiations: playbackBufferRenegotiations.load(ordering: .relaxed),
                adaptivePlaybackRenderFailures: adaptivePlaybackRenderFailures.load(ordering: .relaxed),
                playbackRateCorrectionPPM: Double(
                    playbackRateCorrectionPartsPerBillion.load(ordering: .relaxed)
                ) / 1_000,
                playbackRateCorrectionSaturated: playbackRateCorrectionSaturated.load(ordering: .relaxed),
                playbackOccupancyTargetFrames: adaptivePlaybackTargetFrames.load(ordering: .relaxed),
                filteredPlaybackOccupancyFrames: Double(
                    filteredPlaybackOccupancyMilliFrames.load(ordering: .relaxed)
                ) / 1_000,
                playbackBufferSampleRate: sampleRate,
                playbackSampleRateConversionActive: sampleRateConversionActive.load(ordering: .acquiring)
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
                    recordWriteResult(
                        ringBuffer.writeInterleaved(
                            UnsafeBufferPointer(chunkSamples),
                            frameCount: chunkFrames,
                            sourceChannelCount: channelCount
                        )
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

        func playback(
            outputData: UnsafeMutablePointer<AudioBufferList>,
            outputSampleTime: Double?
        ) {
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

            if pendingOutputTimestampReset.exchange(false, ordering: .acquiringAndReleasing) {
                outputTimestampTracker.reset()
            }

            if pendingPlaybackReset.exchange(false, ordering: .acquiringAndReleasing) {
                _ = ringBuffer.reset()
            }
            if pendingPlaybackClockReset.exchange(false, ordering: .acquiringAndReleasing) {
                pendingPlaybackTargetRetarget.store(false, ordering: .releasing)
                playbackRateServo.reset(
                    targetFrames: adaptivePlaybackTargetFrames.load(ordering: .acquiring)
                )
                playbackResampler.reset()
                publishAdaptivePlaybackMetrics()
            } else if pendingPlaybackTargetRetarget.exchange(false, ordering: .acquiringAndReleasing) {
                playbackRateServo.retarget(
                    adaptivePlaybackTargetFrames.load(ordering: .acquiring)
                )
                playbackResampler.reset()
                publishAdaptivePlaybackMetrics()
            }

            if outputMutedForTransition.load(ordering: .acquiring) {
                clear(outputData: outputData)
                return
            }

            let inputDurationFrames = playbackSampleRatePlan.inputFrames(
                forOutputFrames: frameCount
            )

            if outputTimestampTracker.observe(sampleTime: outputSampleTime, frameCount: frameCount) {
                playbackTimestampDiscontinuities.wrappingAdd(1, ordering: .relaxed)
                signalPlaybackInstability(.outputTimestampDiscontinuity)
                beginPlaybackReprime()
            } else if !playbackPriming.load(ordering: .acquiring),
                      PlaybackOccupancyRecoveryPolicy.shouldReprime(
                          occupancyFrames: ringBuffer.occupancyFrames(),
                          targetFrames: adaptivePlaybackTargetFrames.load(ordering: .acquiring),
                          outputFrames: inputDurationFrames
                      ) {
                signalPlaybackInstability(.excessiveBacklog)
                beginPlaybackReprime()
            }

            if playbackPriming.load(ordering: .acquiring) {
                playbackRateServo.beginPriming()
                playbackResampler.reset()
                publishAdaptivePlaybackMetrics()
                let bufferedFrames = ringBuffer.occupancyFrames()
                let primeFrames = playbackPrimeFrames.load(ordering: .acquiring)
                updateMaxBufferedFrames(bufferedFrames)
                guard bufferedFrames >= primeFrames else {
                    clear(outputData: outputData)
                    return
                }
                guard ringBuffer.trimToLatestFrames(primeFrames) else {
                    clear(outputData: outputData)
                    return
                }
                playbackRateServo.didPrime(occupancyFrames: primeFrames)
                publishAdaptivePlaybackMetrics()
                playbackPriming.store(false, ordering: .releasing)
            }

            let bufferedFrames = ringBuffer.occupancyFrames()
            recordPlaybackBufferedFrames(bufferedFrames)

            let (destinationLeftChannel, destinationRightChannel) = SystemTapAudioEngine.decodedPlaybackChannelPair(
                playbackChannelPair.load(ordering: .acquiring)
            )

            let ratio = playbackRateServo.update(
                occupancyFrames: bufferedFrames,
                outputFrames: inputDurationFrames
            )
            publishAdaptivePlaybackMetrics()
            let result = if playbackSampleRateConverter != nil {
                renderSampleRateConvertedPlayback(
                    outputBuffers: outputBuffers,
                    frameCount: frameCount,
                    ratio: ratio,
                    destinationLeftChannel: destinationLeftChannel,
                    destinationRightChannel: destinationRightChannel
                )
            } else {
                renderAdaptivePlayback(
                    outputBuffers: outputBuffers,
                    frameCount: frameCount,
                    ratio: ratio,
                    destinationLeftChannel: destinationLeftChannel,
                    destinationRightChannel: destinationRightChannel
                )
            }
            var underrunFrames = 0
            var adaptiveRenderFailed = false
            switch result {
            case .rendered:
                adaptivePlaybackRenderFailureActive.store(false, ordering: .releasing)
                adaptivePlaybackRenderHealthGeneration.wrappingAdd(1, ordering: .releasing)
            case .underrun(let frames):
                adaptivePlaybackRenderFailureActive.store(false, ordering: .releasing)
                adaptivePlaybackRenderHealthGeneration.wrappingAdd(1, ordering: .releasing)
                underrunFrames = frames
            case .failed:
                adaptiveRenderFailed = true
            }

            if underrunFrames > 0 {
                playbackUnderrunFrames.wrappingAdd(UInt64(underrunFrames), ordering: .relaxed)
                signalPlaybackInstability(.underrun)
            } else if adaptiveRenderFailed {
                adaptivePlaybackRenderFailures.wrappingAdd(1, ordering: .relaxed)
                if !adaptivePlaybackRenderFailureActive.exchange(true, ordering: .acquiringAndReleasing) {
                    signalPlaybackInstability(.adaptiveRenderFailure)
                }
            }
            if underrunFrames > 0 || adaptiveRenderFailed {
                beginPlaybackReprime()
            }
            updateMaxBufferedFrames(ringBuffer.occupancyFrames())
            playedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
        }

        private func beginPlaybackReprime() {
            playbackRateServo.beginPriming()
            playbackResampler.reset()
            publishAdaptivePlaybackMetrics()
            playbackPriming.store(true, ordering: .releasing)
        }

        private func signalPlaybackInstability(_ reason: PlaybackBufferInstabilityReason) {
            latestPlaybackInstabilityReason.store(reason.rawValue, ordering: .relaxed)
            playbackInstabilityGeneration.wrappingAdd(1, ordering: .releasing)
        }

        private func renderAdaptivePlayback(
            outputBuffers: UnsafeMutableAudioBufferListPointer,
            frameCount: Int,
            ratio: Double,
            destinationLeftChannel: Int,
            destinationRightChannel: Int
        ) -> AdaptivePlaybackRenderResult {
            guard frameCount <= adaptiveOutputSamples.count / channelCount else {
                clear(outputBuffers: outputBuffers)
                return .failed
            }
            let outputSamples = UnsafeMutableBufferPointer(
                start: adaptiveOutputSamples.baseAddress,
                count: frameCount * channelCount
            )
            let result = renderAdaptiveFrames(
                into: outputSamples,
                frameCount: frameCount,
                ratio: ratio
            )
            guard case .rendered = result else {
                clear(outputBuffers: outputBuffers)
                return result
            }
            writeInterleaved(
                UnsafeBufferPointer(outputSamples),
                sourceFrameOffset: 0,
                destinationFrameOffset: 0,
                frameCount: frameCount,
                sourceChannelCount: channelCount,
                destinationLeftChannel: destinationLeftChannel,
                destinationRightChannel: destinationRightChannel,
                to: outputBuffers
            )
            return .rendered
        }

        private func renderAdaptiveFrames(
            into outputSamples: UnsafeMutableBufferPointer<Float>,
            frameCount: Int,
            ratio: Double
        ) -> AdaptivePlaybackRenderResult {
            let inputFrameCapacity = adaptiveInputSamples.count / channelCount
            let outputFrameCapacity = outputSamples.count / channelCount
            let chunkFrameCapacity = max(inputFrameCapacity - 8, 1)
            guard inputFrameCapacity > 8, outputFrameCapacity >= frameCount else {
                return .failed
            }

            var outputFrameOffset = 0
            while outputFrameOffset < frameCount {
                let chunkFrames = min(frameCount - outputFrameOffset, chunkFrameCapacity)
                let plan = playbackResampler.inputPlan(outputFrames: chunkFrames, ratio: ratio)
                guard plan.combinedFrames <= inputFrameCapacity else {
                    playbackResampler.reset()
                    return .failed
                }

                var readFrames = 0
                var copiedRetainedSamples = false
                var rendered = false
                adaptiveInputSamples.withUnsafeMutableBufferPointer { inputSamples in
                    copiedRetainedSamples = playbackResampler.copyRetainedSamples(into: inputSamples, plan: plan)
                    guard copiedRetainedSamples, let inputBase = inputSamples.baseAddress else {
                        return
                    }
                    let newInputSamples = UnsafeMutableBufferPointer(
                        start: inputBase.advanced(by: plan.prefixFrames * channelCount),
                        count: plan.newFrames * channelCount
                    )
                    readFrames = ringBuffer.readInterleaved(
                        into: newInputSamples,
                        frameCount: plan.newFrames,
                        destinationChannelCount: channelCount
                    )
                    guard readFrames == plan.newFrames else {
                        return
                    }

                    let outputChunk = UnsafeMutableBufferPointer(
                        start: outputSamples.baseAddress?.advanced(
                            by: outputFrameOffset * channelCount
                        ),
                        count: chunkFrames * channelCount
                    )
                    rendered = playbackResampler.render(
                        input: inputSamples,
                        plan: plan,
                        output: outputChunk,
                        outputFrames: chunkFrames,
                        ratio: ratio
                    )
                }

                guard copiedRetainedSamples else {
                    playbackResampler.reset()
                    return .failed
                }
                guard readFrames == plan.newFrames else {
                    playbackResampler.reset()
                    return .underrun(frames: max(plan.newFrames - readFrames, 1))
                }
                guard rendered else {
                    playbackResampler.reset()
                    return .failed
                }
                outputFrameOffset += chunkFrames
            }

            return .rendered
        }

        private func renderSampleRateConvertedPlayback(
            outputBuffers: UnsafeMutableAudioBufferListPointer,
            frameCount: Int,
            ratio: Double,
            destinationLeftChannel: Int,
            destinationRightChannel: Int
        ) -> AdaptivePlaybackRenderResult {
            guard let sampleRateConverter = playbackSampleRateConverter,
                  frameCount <= adaptiveOutputSamples.count / channelCount,
                  let outputBase = adaptiveOutputSamples.baseAddress else {
                clear(outputBuffers: outputBuffers)
                return .failed
            }

            sampleRateConverterInputRatio = ratio
            sampleRateConverterInputResult = .rendered
            var convertedFrameCount = UInt32(frameCount)
            var convertedData = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channelCount),
                    mDataByteSize: UInt32(frameCount * channelCount * MemoryLayout<Float>.size),
                    mData: outputBase
                )
            )
            let status = withUnsafeMutablePointer(to: &convertedData) { outputData in
                sampleRateConverter.fill(
                    inputProc: Self.sampleRateConverterInputProc,
                    inputContext: Unmanaged.passUnretained(self).toOpaque(),
                    outputFrames: &convertedFrameCount,
                    outputData: outputData
                )
            }
            guard status == noErr else {
                clear(outputBuffers: outputBuffers)
                return switch sampleRateConverterInputResult {
                case .rendered:
                    .failed
                case .underrun(let frames):
                    .underrun(frames: frames)
                case .failed:
                    .failed
                }
            }
            guard convertedFrameCount == frameCount else {
                clear(outputBuffers: outputBuffers)
                return .failed
            }

            let outputSamples = UnsafeBufferPointer(
                start: outputBase,
                count: frameCount * channelCount
            )
            writeInterleaved(
                outputSamples,
                sourceFrameOffset: 0,
                destinationFrameOffset: 0,
                frameCount: frameCount,
                sourceChannelCount: channelCount,
                destinationLeftChannel: destinationLeftChannel,
                destinationRightChannel: destinationRightChannel,
                to: outputBuffers
            )
            return .rendered
        }

        private static let sampleRateConverterInputProc: AudioConverterComplexInputDataProcRealtimeSafe = {
            _, requestedFrames, inputData, packetDescriptions, context in
            guard let context else {
                requestedFrames.pointee = 0
                return kAudioConverterErr_UnspecifiedError
            }
            packetDescriptions?.pointee = nil
            return Unmanaged<AudioRuntime>
                .fromOpaque(context)
                .takeUnretainedValue()
                .provideSampleRateConverterInput(
                    requestedFrames: requestedFrames,
                    inputData: inputData
                )
        }

        private func provideSampleRateConverterInput(
            requestedFrames: UnsafeMutablePointer<UInt32>,
            inputData: UnsafeMutablePointer<AudioBufferList>
        ) -> OSStatus {
            let frameCount = Int(requestedFrames.pointee)
            guard frameCount > 0,
                  frameCount <= sampleRateConverterInputSamples.count / channelCount,
                  let inputBase = sampleRateConverterInputSamples.baseAddress else {
                requestedFrames.pointee = 0
                sampleRateConverterInputResult = .failed
                return kAudioConverterErr_InvalidInputSize
            }

            let inputSamples = UnsafeMutableBufferPointer(
                start: inputBase,
                count: frameCount * channelCount
            )
            let result = renderAdaptiveFrames(
                into: inputSamples,
                frameCount: frameCount,
                ratio: sampleRateConverterInputRatio
            )
            sampleRateConverterInputResult = result
            guard case .rendered = result else {
                requestedFrames.pointee = 0
                return kAudioConverterErr_UnspecifiedError
            }

            inputData.pointee = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channelCount),
                    mDataByteSize: UInt32(frameCount * channelCount * MemoryLayout<Float>.size),
                    mData: inputBase
                )
            )
            return noErr
        }

        private func publishAdaptivePlaybackMetrics() {
            playbackRateCorrectionPartsPerBillion.store(
                Int64((playbackRateServo.correctionPartsPerMillion * 1_000).rounded()),
                ordering: .relaxed
            )
            playbackRateCorrectionSaturated.store(
                playbackRateServo.correctionIsSaturated,
                ordering: .relaxed
            )
            filteredPlaybackOccupancyMilliFrames.store(
                Int64((playbackRateServo.filteredOccupancyFrames * 1_000).rounded()),
                ordering: .relaxed
            )
        }

        func clear(outputData: UnsafeMutablePointer<AudioBufferList>) {
            clear(outputBuffers: UnsafeMutableAudioBufferListPointer(outputData))
        }

        private func clear(outputBuffers: UnsafeMutableAudioBufferListPointer) {
            for buffer in outputBuffers {
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
                recordWriteResult(
                    ringBuffer.writeInterleaved(
                        inputSamples,
                        frameCount: frameCount,
                        sourceChannelCount: channelCount
                    )
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
                        recordWriteResult(
                            ringBuffer.writeInterleaved(
                                UnsafeBufferPointer(chunkSamples),
                                frameCount: chunkFrames,
                                sourceChannelCount: channelCount
                            )
                        )
                        frameOffset += chunkFrames
                    }
                }
            }

            updateMaxBufferedFrames(ringBuffer.occupancyFrames())
            capturedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
        }

        private func recordWriteResult(_ result: RingBufferWriteResult) {
            if result.droppedInputFrames > 0 {
                droppedInputFrames.wrappingAdd(UInt64(result.droppedInputFrames), ordering: .relaxed)
            }
            if result.droppedBufferedFrames > 0 {
                droppedBufferedFrames.wrappingAdd(UInt64(result.droppedBufferedFrames), ordering: .relaxed)
            }
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
    private let playbackBufferRenegotiationHandler = Mutex<(@Sendable (PlaybackBufferRenegotiation) -> Void)?>(nil)
    private let runtimeFailureHandler = Mutex<(@Sendable (AudioEngineFailure) -> Void)?>(nil)
    private let restorationStoreURL: URL
    private let playbackBufferCalibrationStoreURL: URL
    private let playbackBufferAdaptationQueue = DispatchQueue(
        label: "com.glasseq.playback-buffer-adaptation",
        qos: .userInitiated
    )
    private let playbackBufferAdaptationQueueKey = DispatchSpecificKey<Void>()
    private let playbackBufferAdaptationTimer: DispatchSourceTimer
    private let playbackBufferAdaptationTimerRunning = Mutex(false)

    public var state: AudioEngineState {
        control.withLock { $0.state }
    }

    public var status: AudioEngineStatus {
        control.withLock { $0.status }
    }

    public init(restorationStoreURL: URL? = nil) {
        let restorationStoreURL = restorationStoreURL ?? PersistedAudioDeviceRestorationStore.defaultURL()
        self.restorationStoreURL = restorationStoreURL
        self.playbackBufferCalibrationStoreURL = PersistedPlaybackBufferCalibrationStore.defaultURL(
            nextTo: restorationStoreURL
        )
        let timer = DispatchSource.makeTimerSource(queue: playbackBufferAdaptationQueue)
        self.playbackBufferAdaptationTimer = timer
        playbackBufferAdaptationQueue.setSpecific(key: playbackBufferAdaptationQueueKey, value: ())
        Self.restorePersistedDeviceSettings(at: restorationStoreURL)
        timer.setEventHandler { [weak self] in
            self?.serviceAdaptivePlaybackBuffering()
        }
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
    }

    deinit {
        stop()
        playbackBufferAdaptationTimer.setEventHandler {}
        playbackBufferAdaptationTimerRunning.withLock { isRunning in
            if !isRunning {
                playbackBufferAdaptationTimer.resume()
            }
            isRunning = false
        }
        playbackBufferAdaptationTimer.cancel()
    }

    public func start(output: AudioOutputDevice, profile: EQProfile) throws {
        try start(output: output, profile: profile, expectation: nil)
    }

    private func start(
        output: AudioOutputDevice,
        profile: EQProfile,
        expectation: OutputRebuildExpectation?
    ) throws {
        pausePlaybackBufferAdaptation()
        defer {
            updatePlaybackBufferAdaptationTimer()
        }
        var previousState = AudioEngineState.stopped
        var previousStatus = AudioEngineStatus.stopped
        var activePreparation: OutputRebuildPreparation?

        do {
            var preparation = try control.withLock { state in
                if let expectation {
                    guard state.outputRebuildGeneration == expectation.generation,
                          state.runtime === expectation.runtime,
                          state.activeOutput?.uid == output.uid else {
                        throw StaleOutputRebuild()
                    }
                }
                guard let requestedProfile = Self.requestedOutputRebuildProfile(
                    requestedProfile: profile,
                    expectedProfileRevision: expectation?.profileRevision,
                    activeProfile: state.activeProfile,
                    activeProfileRevision: state.profileRevision
                ) else {
                    throw StaleProfileRequest()
                }
                previousState = state.state
                previousStatus = state.status
                state.status = .starting
                // Keep capture alive across ordinary output switches. Leaving a low-rate route
                // refreshes it under the same mute guard used for topology changes so normal
                // outputs regain their full capture bandwidth without leaking dry audio.
                try ensureCaptureHalfLocked(&state, output: output, profile: requestedProfile)
                state.profileRevision &+= 1
                return try prepareOutputRebuildLocked(
                    &state,
                    output: output,
                    profile: requestedProfile,
                    profileRevision: state.profileRevision
                )
            }
            let refreshedOutput = try CoreAudioDeviceQuery.outputDevice(id: preparation.output.id)
            preparation.output = refreshedOutput
            preparation.originalBufferFrameSize = refreshedOutput.bufferFrameSize
            activePreparation = preparation
            try control.withLock { state in
                guard state.outputRebuildGeneration == preparation.generation,
                      state.runtime === preparation.runtime,
                      state.captureRunning else {
                    throw StaleOutputRebuild()
                }
                if Self.shouldRecordSampleRateRestoration(
                    tapSampleRate: preparation.tapSampleRate,
                    output: refreshedOutput
                ) {
                    try recordSampleRateRestorationIfNeeded(for: refreshedOutput, state: &state)
                }
            }
            let matchedOutput = try preparePlaybackOutput(
                tapSampleRate: preparation.tapSampleRate,
                output: preparation.output
            )
            let calibrationProbe = try control.withLock { state -> PlaybackBufferCalibrationProbe? in
                try finishOutputRebuildLocked(&state, preparation: preparation, matchedOutput: matchedOutput)
                let active = state.activeOutput ?? output
                state.state = .running(output: active)
                state.status = .running(output: active)
                return state.playbackBufferCalibrationProbe
            }
            if let calibrationProbe {
                try? PersistedPlaybackBufferCalibrationStore.beginProbe(
                    outputUID: calibrationProbe.outputUID,
                    sampleRate: calibrationProbe.sampleRate,
                    tapSampleRate: calibrationProbe.tapSampleRate,
                    frameSize: calibrationProbe.frameSize,
                    targetFrames: calibrationProbe.targetFrames,
                    at: playbackBufferCalibrationStoreURL
                )
            }
        } catch is StaleOutputRebuild {
            return
        } catch is StaleProfileRequest {
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

    private func updateDSPLocked(
        _ state: inout ControlState,
        profile: EQProfile,
        incrementsProfileRevision: Bool = true
    ) -> Bool {
        guard let runtime = state.runtime,
              let activeProfile = state.activeProfile else {
            return false
        }
        let maximumUsableFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
            sampleRate: state.activeOutput?.nominalSampleRate ?? runtime.sampleRate
        )

        guard Self.canHotSwapDSP(
            from: activeProfile,
            to: profile,
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ) else {
            return false
        }

        let preparedConfig = EQRenderConfiguration(
            profile: Self.dspProfile(from: profile),
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        )
        runtime.drainDSPConfigBoxes()
        runtime.publishPendingDSPConfig(preparedConfig)
        runtime.setBypassed(profile.isBypassed)
        state.activeProfile = profile
        if incrementsProfileRevision {
            state.profileRevision &+= 1
        }
        return true
    }

    static func canHotSwapDSP(
        from activeProfile: EQProfile,
        to nextProfile: EQProfile,
        sampleRate: Double,
        channelCount: Int,
        maximumUsableFrequency: Double? = nil
    ) -> Bool {
        guard activeProfile.mode == nextProfile.mode,
              activeProfile.channelMode == nextProfile.channelMode else {
            return false
        }

        return EQRenderConfiguration(
            profile: Self.dspProfile(from: nextProfile),
            sampleRate: sampleRate,
            channelCount: channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ).hasRealtimeCompatibleTopology(
            with: EQRenderConfiguration(
                profile: Self.dspProfile(from: activeProfile),
                sampleRate: sampleRate,
                channelCount: channelCount,
                maximumUsableFrequency: maximumUsableFrequency
            )
        )
    }

    public func setBypassed(_ isBypassed: Bool) {
        control.withLock { state in
            state.runtime?.setBypassed(isBypassed)
            state.activeProfile?.isBypassed = isBypassed
            state.profileRevision &+= 1
        }
    }

    public func muteOutputForTransition() {
        control.withLock { state in
            state.runtime?.muteOutputForTransition()
        }
    }

    public func stop() {
        pausePlaybackBufferAdaptation()
        control.withLock { state in
            stopLocked(&state)
        }
        updatePlaybackBufferAdaptationTimer()
    }

    public func snapshotMetrics() -> AudioEngineMetrics {
        let runtime = control.withLock { $0.runtime }
        return runtime?.snapshotMetrics() ?? AudioEngineMetrics()
    }

    public func resetDiagnostics() {
        let runtime = control.withLock { $0.runtime }
        runtime?.resetMetrics()
    }

    public func resetPlaybackBufferCalibration(forOutputUID outputUID: String) throws {
        guard !outputUID.isEmpty else {
            return
        }
        pausePlaybackBufferAdaptation()
        defer {
            updatePlaybackBufferAdaptationTimer()
        }
        try PersistedPlaybackBufferCalibrationStore.removeCalibrations(
            outputUID: outputUID,
            at: playbackBufferCalibrationStoreURL
        )
        let activeOutputAndProfile = control.withLock {
            state -> (AudioOutputDevice, EQProfile, OutputRebuildExpectation)? in
            if state.playbackBufferCalibrationProbe?.outputUID == outputUID {
                state.playbackBufferCalibrationProbe = nil
            }
            state.playbackBufferInstabilityPersistenceGate.reset(outputUID: outputUID)
            state.attemptedPlaybackTargetDownProbes = Set(
                state.attemptedPlaybackTargetDownProbes.filter { $0.outputUID != outputUID }
            )
            state.attemptedPlaybackFrameSizeDownProbes = Set(
                state.attemptedPlaybackFrameSizeDownProbes.filter { $0.outputUID != outputUID }
            )
            guard let output = state.activeOutput,
                  output.uid == outputUID,
                  let profile = state.activeProfile else {
                return nil
            }
            guard let runtime = state.runtime else {
                return nil
            }
            return (
                output,
                profile,
                OutputRebuildExpectation(
                    generation: state.outputRebuildGeneration,
                    runtime: runtime,
                    profileRevision: state.profileRevision
                )
            )
        }
        if let (activeOutput, activeProfile, expectation) = activeOutputAndProfile {
            let freshOutput = try CoreAudioDeviceQuery.outputDevice(id: activeOutput.id)
            try start(
                output: freshOutput,
                profile: activeProfile,
                expectation: expectation
            )
        }
    }

    public func setPlaybackBufferRenegotiationHandler(
        _ handler: (@Sendable (PlaybackBufferRenegotiation) -> Void)?
    ) {
        playbackBufferRenegotiationHandler.withLock { currentHandler in
            currentHandler = handler
        }
    }

    public func setRuntimeFailureHandler(
        _ handler: (@Sendable (AudioEngineFailure) -> Void)?
    ) {
        runtimeFailureHandler.withLock { currentHandler in
            currentHandler = handler
        }
    }

    private func stopLocked(_ state: inout ControlState) {
        state.runtime?.markStopping()
        stopOutputHalfLocked(&state)
        stopCaptureHalfLocked(&state)
        state.activeProfile = nil
        state.profileRevision &+= 1
        state.handledPlaybackInstabilityGeneration = 0
        state.adaptivePlaybackRenderRecoveryAttempts = 0
        state.adaptivePlaybackRenderRecoveryHealthGeneration = nil
        state.playbackBufferInstabilityPersistenceGate.reset()
        state.attemptedPlaybackTargetDownProbes.removeAll()
        state.attemptedPlaybackFrameSizeDownProbes.removeAll()
        state.state = .stopped
        state.status = .stopped
    }

    // MARK: - Capture half (persistent global muted tap @ the tap rate)

    private func ensureCaptureHalfLocked(
        _ state: inout ControlState,
        output: AudioOutputDevice,
        profile: EQProfile
    ) throws {
        if state.captureRunning, state.runtime != nil {
            let shouldRefreshCapture = Self.shouldRefreshCaptureForOutput(
                tapSampleRate: state.tapSampleRate,
                output: output
            )
            if !shouldRefreshCapture,
               updateDSPLocked(&state, profile: profile, incrementsProfileRevision: false) {
                return
            }
            // Hold a second global muted tap while capture is recreated, so HAL-level muting
            // never lapses during topology changes or low-rate capture refreshes.
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
        // Low-latency tuning: a 128-frame prime (~2.7 ms @ 48k) — about 2x the tap's callback
        // once we request a 64-frame capture buffer below. Capacity is sized from the largest
        // runtime output callback so every supported prime retains equal drift headroom.
        let playbackPrimeFrames = Self.preferredPlaybackPrimeFrames
        let ringCapacityFrames = Self.runtimeRingCapacityFrames
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

    // MARK: - Output half (swappable; direct-rate or converted low-rate playback)

    private func prepareOutputRebuildLocked(
        _ state: inout ControlState,
        output: AudioOutputDevice,
        profile: EQProfile,
        profileRevision: UInt64
    ) throws -> OutputRebuildPreparation {
        guard let runtime = state.runtime else {
            throw CoreAudioError(operation: "rebuildOutputHalf(missing runtime)", status: kAudioHardwareNotRunningError)
        }
        // Mismatched low-rate endpoints keep their device-owned rates and receive realtime
        // sample-rate conversion in the playback callback.
        let originalBufferFrameSize = output.bufferFrameSize
        _ = try Self.supportedRuntimeChannelCount(for: output)
        stopOutputHalfLocked(&state)
        return OutputRebuildPreparation(
            generation: state.outputRebuildGeneration,
            output: output,
            profile: profile,
            runtime: runtime,
            tapSampleRate: state.tapSampleRate,
            originalBufferFrameSize: originalBufferFrameSize,
            profileRevision: profileRevision
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
        let effectiveProfile = Self.effectiveOutputRebuildProfile(
            preparedProfile: preparation.profile,
            preparedProfileRevision: preparation.profileRevision,
            activeProfile: state.activeProfile,
            activeProfileRevision: state.profileRevision
        )
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
        // Keep IOProc ownership paired with its device so failure cleanup can stop it.
        state.activeOutput = matchedOutput

        // Now that our output owns the device, apply the low-latency buffer size. The stream
        // restart it triggers happens under our muted IOProc, so it plays silence, not dry audio.
        let allowsFrameSizeDownwardProbe = state.attemptedPlaybackFrameSizeDownProbes.insert(
            PlaybackBufferRouteKey(output: matchedOutput)
        ).inserted
        let tunedOutput = tuneBufferFrameSize(
            for: matchedOutput,
            tapSampleRate: runtime.sampleRate,
            allowsDownwardProbe: allowsFrameSizeDownwardProbe
        )
        try Self.validatePlaybackCallbackCapacity(for: tunedOutput)
        try Self.validatePlaybackConversionCapacity(
            for: tunedOutput,
            tapSampleRate: runtime.sampleRate
        )
        state.activeOutput = tunedOutput
        let operatingPointKey = PlaybackBufferOperatingPointKey(
            output: tunedOutput,
            tapSampleRate: runtime.sampleRate
        )
        let allowsDownwardProbe = state.attemptedPlaybackTargetDownProbes.insert(
            operatingPointKey
        ).inserted
        let targetFrames = preferredPlaybackTargetFrames(
            for: tunedOutput,
            tapSampleRate: runtime.sampleRate,
            allowsDownwardProbe: allowsDownwardProbe
        )
        // Capture applies prepared configs and retires their boxes. Output switches are a safe
        // control-path opportunity to release those boxes before publishing the next config.
        runtime.drainDSPConfigBoxes()
        runtime.publishPendingDSPConfig(EQRenderConfiguration(
            profile: Self.dspProfile(from: effectiveProfile),
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount,
            maximumUsableFrequency: EQRouteFrequencyPolicy.maximumUsableFrequency(
                sampleRate: tunedOutput.nominalSampleRate
            )
        ))
        // Build the converter and its exact Core Audio input scratch on this control path while
        // the new IOProc is muted. reprimePlayback() release-publishes both before the callback's
        // acquiring mute check.
        try runtime.configurePlayback(
            primeFrames: targetFrames,
            outputSampleRate: tunedOutput.nominalSampleRate
        )
        state.handledPlaybackInstabilityGeneration = runtime.playbackInstabilitySnapshot().generation
        state.playbackBufferCalibrationProbe = playbackBufferCalibrationProbe(
            for: tunedOutput,
            tapSampleRate: runtime.sampleRate,
            targetFrames: targetFrames
        )

        // Unmute and re-anchor playback to the freshest captured audio on the new device.
        runtime.reprimePlayback()

        state.activeProfile = effectiveProfile
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
        state.playbackBufferCalibrationProbe = nil
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

    private func preparePlaybackOutput(
        tapSampleRate: Double,
        output: AudioOutputDevice
    ) throws -> AudioOutputDevice {
        if Self.shouldUseSampleRateConversion(tapSampleRate: tapSampleRate, output: output) {
            return output
        }
        return try forceSampleRate(tapSampleRate, on: output)
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
            switch availabilityError {
            case .unsupportedOutputChannelCount,
                 .unsupportedOutputBufferFrameSize,
                 .unsupportedPlaybackConversionBuffer:
                return AudioEngineFailure(
                    category: .deviceFormatUnsupported,
                    userMessage: availabilityError.description,
                    operation: "CoreAudioDeviceQuery"
                )
            default:
                return AudioEngineFailure(
                    category: .outputDeviceUnavailable,
                    userMessage: availabilityError.description,
                    operation: "CoreAudioDeviceQuery"
                )
            }
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
        // getChannelCount sums per-buffer mNumberChannels without bounding them, so a broken
        // device can still report absurd counts; the playback mapper handles anything below this.
        guard output.outputChannelCount <= CoreAudioDeviceQuery.maxChannelCount else {
            throw AudioDeviceAvailabilityError.unsupportedOutputChannelCount(output.id, output.outputChannelCount)
        }
        return output.outputChannelCount
    }

    static func validatePlaybackCallbackCapacity(for output: AudioOutputDevice) throws {
        guard output.bufferFrameSize <= UInt32(maximumSupportedCallbackFrames) else {
            throw AudioDeviceAvailabilityError.unsupportedOutputBufferFrameSize(
                output.id,
                output.bufferFrameSize,
                maximum: UInt32(maximumSupportedCallbackFrames)
            )
        }
    }

    static func validatePlaybackConversionCapacity(
        for output: AudioOutputDevice,
        tapSampleRate: Double
    ) throws {
        guard shouldUseSampleRateConversion(tapSampleRate: tapSampleRate, output: output) else {
            return
        }
        let requiredPrimeFrames = preferredPlaybackPrimeFrames(
            for: output,
            tapSampleRate: tapSampleRate
        )
        let maximumPrimeFrames = runtimeRingCapacityFrames / playbackRingPullCount
        guard requiredPrimeFrames <= maximumPrimeFrames else {
            throw AudioDeviceAvailabilityError.unsupportedPlaybackConversionBuffer(
                output.id,
                requiredPrimeFrames: requiredPrimeFrames,
                maximumPrimeFrames: maximumPrimeFrames
            )
        }
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

    private func tuneBufferFrameSize(
        for output: AudioOutputDevice,
        tapSampleRate: Double,
        allowsDownwardProbe: Bool
    ) -> AudioOutputDevice {
        do {
            let range = try CoreAudioDeviceQuery.bufferFrameSizeRangeValue(objectID: output.id)
            let calibration = PersistedPlaybackBufferCalibrationStore.calibration(
                outputUID: output.uid,
                sampleRate: output.nominalSampleRate,
                tapSampleRate: tapSampleRate,
                from: playbackBufferCalibrationStoreURL
            )
            let requested = AdaptivePlaybackBufferPolicy.startupFrameSize(
                preferredFrameSize: Self.preferredBufferFrameSize(for: output),
                calibration: calibration,
                supportedRange: range,
                allowsDownwardProbe: allowsDownwardProbe
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

    private func playbackBufferCalibrationProbe(
        for output: AudioOutputDevice,
        tapSampleRate: Double,
        targetFrames: Int,
        startedAt: ContinuousClock.Instant = ContinuousClock().now
    ) -> PlaybackBufferCalibrationProbe? {
        guard Self.shouldAdaptPlaybackBuffer(for: output) else {
            return nil
        }
        let calibration = PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: output.uid,
            sampleRate: output.nominalSampleRate,
            tapSampleRate: tapSampleRate,
            from: playbackBufferCalibrationStoreURL
        )
        guard PlaybackBufferCalibrationPolicy.shouldProbe(
            frameSize: output.bufferFrameSize,
            targetFrames: targetFrames,
            calibration: calibration
        ) else {
            return nil
        }
        return PlaybackBufferCalibrationProbe(
            outputUID: output.uid,
            sampleRate: output.nominalSampleRate,
            tapSampleRate: tapSampleRate,
            frameSize: output.bufferFrameSize,
            targetFrames: targetFrames,
            startedAt: startedAt
        )
    }

    private func preferredPlaybackTargetFrames(
        for output: AudioOutputDevice,
        tapSampleRate: Double,
        allowsDownwardProbe: Bool
    ) -> Int {
        let baseline = Self.preferredPlaybackPrimeFrames(
            for: output,
            tapSampleRate: tapSampleRate
        )
        guard Self.shouldAdaptPlaybackBuffer(for: output) else {
            return baseline
        }
        let calibration = PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: output.uid,
            sampleRate: output.nominalSampleRate,
            tapSampleRate: tapSampleRate,
            from: playbackBufferCalibrationStoreURL
        )
        let targetFrames = AdaptivePlaybackBufferPolicy.startupTargetFrames(
            callbackFrames: Self.playbackInputCallbackFrames(
                for: output,
                tapSampleRate: tapSampleRate
            ),
            baselineTargetFrames: baseline,
            operatingPoint: calibration?.operatingPoint(for: output.bufferFrameSize),
            allowsDownwardProbe: allowsDownwardProbe
        )
        return min(targetFrames, Self.runtimeRingCapacityFrames / 2)
    }

    private func updatePlaybackBufferAdaptationTimer() {
        let shouldRun = control.withLock { state in
            guard case .running = state.state,
                  let output = state.activeOutput else {
                return false
            }
            return Self.shouldAdaptPlaybackBuffer(for: output)
        }
        setPlaybackBufferAdaptationTimerRunning(shouldRun)
    }

    private func pausePlaybackBufferAdaptation() {
        setPlaybackBufferAdaptationTimerRunning(false)
        if DispatchQueue.getSpecific(key: playbackBufferAdaptationQueueKey) == nil {
            playbackBufferAdaptationQueue.sync {}
        }
    }

    private func setPlaybackBufferAdaptationTimerRunning(_ shouldRun: Bool) {
        playbackBufferAdaptationTimerRunning.withLock { isRunning in
            guard isRunning != shouldRun else {
                return
            }
            isRunning = shouldRun
            if shouldRun {
                playbackBufferAdaptationTimer.resume()
            } else {
                playbackBufferAdaptationTimer.suspend()
            }
        }
    }

    private func serviceAdaptivePlaybackBuffering() {
        let now = ContinuousClock().now
        guard let action = control.withLock({ state -> PlaybackBufferAdaptationAction? in
            guard let runtime = state.runtime,
                  let output = state.activeOutput,
                  Self.shouldAdaptPlaybackBuffer(for: output) else {
                return nil
            }

            if let recoveryGeneration = state.adaptivePlaybackRenderRecoveryHealthGeneration,
               runtime.playbackRenderHealthGeneration() != recoveryGeneration {
                state.adaptivePlaybackRenderRecoveryAttempts = 0
                state.adaptivePlaybackRenderRecoveryHealthGeneration = nil
            }

            let instability = runtime.playbackInstabilitySnapshot()
            if instability.generation == state.handledPlaybackInstabilityGeneration {
                guard let probe = state.playbackBufferCalibrationProbe,
                      probe.hasCompletedProbation(at: now) else {
                    return nil
                }
                return .stabilize(probe)
            }
            state.handledPlaybackInstabilityGeneration = instability.generation
            return .renegotiate(PlaybackBufferRenegotiationPreparation(
                outputRebuildGeneration: state.outputRebuildGeneration,
                reason: instability.reason,
                output: output,
                runtime: runtime
            ))
        }) else {
            return
        }

        let preparation: PlaybackBufferRenegotiationPreparation
        switch action {
        case .stabilize(let probe):
            do {
                try PersistedPlaybackBufferCalibrationStore.recordStable(
                    outputUID: probe.outputUID,
                    sampleRate: probe.sampleRate,
                    tapSampleRate: probe.tapSampleRate,
                    frameSize: probe.frameSize,
                    targetFrames: probe.targetFrames,
                    at: playbackBufferCalibrationStoreURL
                )
            } catch {
                return
            }
            control.withLock { state in
                if state.playbackBufferCalibrationProbe == probe {
                    state.playbackBufferCalibrationProbe = nil
                    state.playbackBufferInstabilityPersistenceGate.reset(outputUID: probe.outputUID)
                }
            }
            return
        case .renegotiate(let pendingRenegotiation):
            preparation = pendingRenegotiation
        }

        if preparation.reason == .adaptiveRenderFailure {
            recoverAdaptivePlaybackRenderFailure(preparation)
            return
        }

        if increasePlaybackTargetIfPossible(preparation) {
            return
        }
        guard AdaptivePlaybackBufferPolicy.shouldIncreaseCallback(for: preparation.reason) else {
            continueCalibrationAfterUnresolvedInstability(preparation)
            return
        }

        let range: AudioBufferFrameSizeRange
        do {
            range = try CoreAudioDeviceQuery.bufferFrameSizeRangeValue(objectID: preparation.output.id)
        } catch {
            continueCalibrationAfterUnresolvedInstability(preparation)
            return
        }
        guard let nextFrameSize = AdaptivePlaybackBufferPolicy.nextFrameSize(
            after: preparation.output.bufferFrameSize,
            supportedRange: range
        ) else {
            continueCalibrationAfterUnresolvedInstability(preparation)
            return
        }
        var proposedOutput = preparation.output
        proposedOutput.bufferFrameSize = nextFrameSize
        do {
            try Self.validatePlaybackConversionCapacity(
                for: proposedOutput,
                tapSampleRate: preparation.runtime.sampleRate
            )
        } catch {
            continueCalibrationAfterUnresolvedInstability(preparation)
            return
        }

        let didBeginRenegotiation = control.withLock { state in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return false
            }
            preparation.runtime.muteOutputForTransition()
            return true
        }
        guard didBeginRenegotiation else {
            return
        }

        let updatedOutput: AudioOutputDevice
        do {
            guard let result = try Self.renegotiatedPlaybackOutput(
                preparation.output,
                supportedRange: range
            ) else {
                recoverFailedPlaybackBufferRenegotiation(preparation)
                continueCalibrationAfterUnresolvedInstability(preparation)
                return
            }
            updatedOutput = result
        } catch {
            recoverFailedPlaybackBufferRenegotiation(preparation)
            continueCalibrationAfterUnresolvedInstability(preparation)
            return
        }

        let completedRenegotiation = control.withLock { state -> PlaybackBufferRenegotiation? in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return nil
            }

            let previousTargetFrames = preparation.runtime.playbackTargetFrames()
            let targetFrames = preferredPlaybackTargetFrames(
                for: updatedOutput,
                tapSampleRate: preparation.runtime.sampleRate,
                allowsDownwardProbe: false
            )
            preparation.runtime.retargetPlayback(
                primeFrames: targetFrames
            )
            preparation.runtime.recordPlaybackBufferRenegotiation()
            preparation.runtime.reprimePlayback()

            state.activeOutput = updatedOutput
            state.state = .running(output: updatedOutput)
            state.status = .running(output: updatedOutput)
            state.handledPlaybackInstabilityGeneration = preparation.runtime.playbackInstabilitySnapshot().generation
            state.attemptedPlaybackTargetDownProbes.insert(
                PlaybackBufferOperatingPointKey(
                    output: updatedOutput,
                    tapSampleRate: preparation.runtime.sampleRate
                )
            )
            state.playbackBufferCalibrationProbe = PlaybackBufferCalibrationProbe(
                outputUID: updatedOutput.uid,
                sampleRate: updatedOutput.nominalSampleRate,
                tapSampleRate: preparation.runtime.sampleRate,
                frameSize: updatedOutput.bufferFrameSize,
                targetFrames: targetFrames,
                startedAt: ContinuousClock().now
            )
            return PlaybackBufferRenegotiation(
                outputName: updatedOutput.name,
                outputUID: updatedOutput.uid,
                sampleRate: updatedOutput.nominalSampleRate,
                previousFrameSize: preparation.output.bufferFrameSize,
                frameSize: updatedOutput.bufferFrameSize,
                previousPlaybackTargetFrames: previousTargetFrames,
                playbackTargetFrames: targetFrames,
                reason: preparation.reason
            )
        }
        guard let completedRenegotiation else {
            return
        }
        try? PersistedPlaybackBufferCalibrationStore.recordInstability(
            outputUID: completedRenegotiation.outputUID,
            sampleRate: completedRenegotiation.sampleRate,
            tapSampleRate: preparation.runtime.sampleRate,
            previousFrameSize: completedRenegotiation.previousFrameSize,
            resultingFrameSize: completedRenegotiation.frameSize,
            previousTargetFrames: completedRenegotiation.previousPlaybackTargetFrames,
            resultingTargetFrames: completedRenegotiation.playbackTargetFrames,
            reason: completedRenegotiation.reason,
            at: playbackBufferCalibrationStoreURL
        )
        let handler = playbackBufferRenegotiationHandler.withLock { $0 }
        handler?(completedRenegotiation)
    }

    private func increasePlaybackTargetIfPossible(
        _ preparation: PlaybackBufferRenegotiationPreparation
    ) -> Bool {
        let adjustment = control.withLock { state -> PlaybackBufferTargetAdjustment? in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return nil
            }
            let previousTargetFrames = preparation.runtime.playbackTargetFrames()
            guard let targetFrames = AdaptivePlaybackBufferPolicy.nextTargetFrames(
                for: preparation.reason,
                callbackFrames: Self.playbackInputCallbackFrames(
                    for: preparation.output,
                    tapSampleRate: preparation.runtime.sampleRate
                ),
                after: previousTargetFrames,
                maximumReservoirFrames: Self.maximumPlaybackReservoirFrames(
                    for: preparation.output,
                    tapSampleRate: preparation.runtime.sampleRate,
                    maximumObservedCaptureCallbackFrames: preparation.runtime
                        .maximumObservedCaptureCallbackFrames()
                )
            ) else {
                return nil
            }

            preparation.runtime.retargetPlayback(
                primeFrames: targetFrames
            )
            preparation.runtime.recordPlaybackBufferRenegotiation()
            preparation.runtime.reprimePlayback()
            state.handledPlaybackInstabilityGeneration = preparation.runtime.playbackInstabilitySnapshot().generation
            state.playbackBufferCalibrationProbe = PlaybackBufferCalibrationProbe(
                outputUID: preparation.output.uid,
                sampleRate: preparation.output.nominalSampleRate,
                tapSampleRate: preparation.runtime.sampleRate,
                frameSize: preparation.output.bufferFrameSize,
                targetFrames: targetFrames,
                startedAt: ContinuousClock().now
            )
            return PlaybackBufferTargetAdjustment(
                output: preparation.output,
                tapSampleRate: preparation.runtime.sampleRate,
                previousTargetFrames: previousTargetFrames,
                targetFrames: targetFrames,
                reason: preparation.reason
            )
        }
        guard let adjustment else {
            return false
        }

        try? PersistedPlaybackBufferCalibrationStore.recordInstability(
            outputUID: adjustment.output.uid,
            sampleRate: adjustment.output.nominalSampleRate,
            tapSampleRate: adjustment.tapSampleRate,
            previousFrameSize: adjustment.output.bufferFrameSize,
            resultingFrameSize: adjustment.output.bufferFrameSize,
            previousTargetFrames: adjustment.previousTargetFrames,
            resultingTargetFrames: adjustment.targetFrames,
            reason: adjustment.reason,
            at: playbackBufferCalibrationStoreURL
        )
        return true
    }

    private func continueCalibrationAfterUnresolvedInstability(
        _ preparation: PlaybackBufferRenegotiationPreparation
    ) {
        let targetFrames = preparation.runtime.playbackTargetFrames()
        let instability = UnresolvedPlaybackBufferInstability(
            outputUID: preparation.output.uid,
            sampleRate: preparation.output.nominalSampleRate,
            tapSampleRate: preparation.runtime.sampleRate,
            frameSize: preparation.output.bufferFrameSize,
            targetFrames: targetFrames,
            reason: preparation.reason
        )
        let shouldPersist = control.withLock { state -> Bool? in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return nil
            }
            state.playbackBufferCalibrationProbe = PlaybackBufferCalibrationProbe(
                outputUID: preparation.output.uid,
                sampleRate: preparation.output.nominalSampleRate,
                tapSampleRate: preparation.runtime.sampleRate,
                frameSize: preparation.output.bufferFrameSize,
                targetFrames: targetFrames,
                startedAt: ContinuousClock().now
            )
            return state.playbackBufferInstabilityPersistenceGate.shouldPersist(instability)
        }
        guard shouldPersist == true else {
            return
        }
        do {
            try PersistedPlaybackBufferCalibrationStore.recordInstability(
                outputUID: preparation.output.uid,
                sampleRate: preparation.output.nominalSampleRate,
                tapSampleRate: preparation.runtime.sampleRate,
                previousFrameSize: preparation.output.bufferFrameSize,
                resultingFrameSize: preparation.output.bufferFrameSize,
                previousTargetFrames: targetFrames,
                resultingTargetFrames: targetFrames,
                reason: preparation.reason,
                at: playbackBufferCalibrationStoreURL
            )
        } catch {
            control.withLock { state in
                state.playbackBufferInstabilityPersistenceGate.persistenceFailed(for: instability)
            }
        }
    }

    private func recoverFailedPlaybackBufferRenegotiation(
        _ preparation: PlaybackBufferRenegotiationPreparation
    ) {
        control.withLock { state in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return
            }
            preparation.runtime.reprimePlayback()
        }
    }

    private func recoverAdaptivePlaybackRenderFailure(
        _ preparation: PlaybackBufferRenegotiationPreparation
    ) {
        let action = control.withLock { state -> AdaptivePlaybackRenderRecoveryAction? in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output,
                  preparation.runtime.hasActiveAdaptivePlaybackRenderFailure(),
                  let profile = state.activeProfile else {
                return nil
            }
            if AdaptivePlaybackRenderRecoveryPolicy.shouldRestart(
                afterCompletedAttempts: state.adaptivePlaybackRenderRecoveryAttempts
            ) {
                state.adaptivePlaybackRenderRecoveryAttempts += 1
                state.adaptivePlaybackRenderRecoveryHealthGeneration = preparation.runtime
                    .playbackRenderHealthGeneration()
                return .restart(
                    output: preparation.output,
                    profile: profile,
                    expectation: OutputRebuildExpectation(
                        generation: state.outputRebuildGeneration,
                        runtime: preparation.runtime,
                        profileRevision: state.profileRevision
                    )
                )
            }

            let failure = AudioEngineFailure(
                category: .coreAudioOperationFailed,
                userMessage: "Adaptive playback rendering repeatedly failed, so GlassEQ stopped processing audio.",
                operation: "AdaptivePlaybackRender"
            )
            stopLocked(&state)
            state.state = .failed(failure.description)
            state.status = .failed(failure)
            return .fail(failure)
        }
        guard let action else {
            return
        }

        switch action {
        case .restart(let output, let profile, let expectation):
            do {
                try start(
                    output: output,
                    profile: profile,
                    expectation: expectation
                )
            } catch {
                let failure = control.withLock { state in
                    if case .failed(let failure) = state.status {
                        return failure
                    }
                    return audioEngineFailure(from: error)
                }
                runtimeFailureHandler.withLock { $0 }?(failure)
            }
        case .fail(let failure):
            updatePlaybackBufferAdaptationTimer()
            runtimeFailureHandler.withLock { $0 }?(failure)
        }
    }

    static func renegotiatedPlaybackOutput(
        _ output: AudioOutputDevice,
        supportedRange: AudioBufferFrameSizeRange,
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setBufferFrameSize(_:objectID:),
        queryOutput: (AudioObjectID) throws -> AudioOutputDevice = CoreAudioDeviceQuery.outputDevice(id:),
        waitForPropertySettlement: () -> Void = { Thread.sleep(forTimeInterval: 0.01) }
    ) throws -> AudioOutputDevice? {
        guard let requestedFrameSize = AdaptivePlaybackBufferPolicy.nextFrameSize(
            after: output.bufferFrameSize,
            supportedRange: supportedRange
        ) else {
            return nil
        }

        try setBufferFrameSize(requestedFrameSize, output.id)
        for attempt in 0..<3 {
            let updatedOutput = try queryOutput(output.id)
            if updatedOutput.id == output.id,
               updatedOutput.bufferFrameSize > output.bufferFrameSize {
                return updatedOutput
            }
            if attempt < 2 {
                waitForPropertySettlement()
            }
        }
        return nil
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

    static func preferredPlaybackPrimeFrames(
        for output: AudioOutputDevice,
        tapSampleRate: Double? = nil
    ) -> Int {
        let outputCallbackFrames = max(Int(output.bufferFrameSize), 1)
        if hasLowSampleRateEndpoint(
            tapSampleRate: tapSampleRate ?? output.nominalSampleRate,
            output: output
        ) {
            let sampleRatePlan = PlaybackSampleRatePlan(
                inputSampleRate: tapSampleRate ?? output.nominalSampleRate,
                outputSampleRate: output.nominalSampleRate
            )
            return max(
                sampleRatePlan.inputFrames(forOutputFrames: Int(Self.preferredLowSampleRateBufferFrameSize)),
                sampleRatePlan.inputFrames(forOutputFrames: outputCallbackFrames)
                    + Self.preferredLowSampleRatePlaybackReservoirFrames
            )
        }
        if output.isBluetoothTransport {
            return max(
                Self.preferredBluetoothPlaybackTargetFrames,
                outputCallbackFrames + Self.preferredBluetoothPlaybackReservoirFrames
            )
        }
        return max(
            Self.preferredPlaybackPrimeFrames,
            outputCallbackFrames + Int(Self.preferredCaptureBufferFrameSize)
        )
    }

    static func shouldAdaptPlaybackBuffer(for output: AudioOutputDevice) -> Bool {
        output.nominalSampleRate > 0
    }

    static func playbackInputCallbackFrames(
        for output: AudioOutputDevice,
        tapSampleRate: Double
    ) -> UInt32 {
        UInt32(clamping: PlaybackSampleRatePlan(
            inputSampleRate: tapSampleRate,
            outputSampleRate: output.nominalSampleRate
        ).inputFrames(forOutputFrames: Int(output.bufferFrameSize)))
    }

    static func shouldUseSampleRateConversion(
        tapSampleRate: Double,
        output: AudioOutputDevice
    ) -> Bool {
        abs(tapSampleRate - output.nominalSampleRate) >= 1
            && hasLowSampleRateEndpoint(tapSampleRate: tapSampleRate, output: output)
    }

    static func shouldRecordSampleRateRestoration(
        tapSampleRate: Double,
        output: AudioOutputDevice
    ) -> Bool {
        tapSampleRate > 0
            && abs(output.nominalSampleRate - tapSampleRate) >= 1
            && !shouldUseSampleRateConversion(tapSampleRate: tapSampleRate, output: output)
    }

    static func effectiveOutputRebuildProfile(
        preparedProfile: EQProfile,
        preparedProfileRevision: UInt64,
        activeProfile: EQProfile?,
        activeProfileRevision: UInt64
    ) -> EQProfile {
        guard activeProfileRevision != preparedProfileRevision,
              let activeProfile else {
            return preparedProfile
        }
        return activeProfile
    }

    static func requestedOutputRebuildProfile(
        requestedProfile: EQProfile,
        expectedProfileRevision: UInt64?,
        activeProfile: EQProfile?,
        activeProfileRevision: UInt64
    ) -> EQProfile? {
        guard let expectedProfileRevision,
              activeProfileRevision != expectedProfileRevision else {
            return requestedProfile
        }
        return activeProfile
    }

    static func shouldRefreshCaptureForOutput(
        tapSampleRate: Double,
        output: AudioOutputDevice
    ) -> Bool {
        isLowSampleRate(tapSampleRate)
            && output.nominalSampleRate - tapSampleRate >= 1
    }

    static func maximumPlaybackReservoirFrames(
        for output: AudioOutputDevice,
        tapSampleRate: Double,
        maximumObservedCaptureCallbackFrames: Int
    ) -> Int {
        guard hasLowSampleRateEndpoint(tapSampleRate: tapSampleRate, output: output) else {
            return AdaptivePlaybackBufferPolicy.maximumReservoirFrames
        }
        return max(
            Self.preferredLowSampleRatePlaybackReservoirFrames,
            maximumObservedCaptureCallbackFrames
        )
    }

    private static func isLowSampleRateRoute(_ output: AudioOutputDevice) -> Bool {
        isLowSampleRate(output.nominalSampleRate)
    }

    private static func isLowSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate > 0 && sampleRate <= Self.lowSampleRateThreshold
    }

    private static func hasLowSampleRateEndpoint(
        tapSampleRate: Double,
        output: AudioOutputDevice
    ) -> Bool {
        isLowSampleRate(tapSampleRate) || isLowSampleRateRoute(output)
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
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, _, _, outputData, outputTime in
                let outputTimestamp = outputTime.pointee
                let sampleTime: Double? = if outputTimestamp.mFlags.contains(.sampleTimeValid) {
                    outputTimestamp.mSampleTime
                } else {
                    nil
                }
                runtime.playback(outputData: outputData, outputSampleTime: sampleTime)
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
