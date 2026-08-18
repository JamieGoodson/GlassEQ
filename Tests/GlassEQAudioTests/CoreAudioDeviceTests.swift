import CoreAudio
import Foundation
@testable import GlassEQAudio
import GlassEQCore
import Testing

@Suite
struct CoreAudioDeviceTests {
    @Test
    func defaultOutputQueryDoesNotCrash() throws {
        let device = try CoreAudioDeviceQuery.defaultOutputDevice()

        #expect(!device.name.isEmpty)
        #expect(!device.uid.isEmpty)
        #expect(device.nominalSampleRate > 0)
    }

    @Test
    func metadataValidationRejectsInvalidScalarValues() throws {
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.validatedSampleRate(.infinity, objectID: 42)
        }
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.validatedSampleRate(0, objectID: 42)
        }
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.validatedBufferFrameSize(0, objectID: 42)
        }
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.validatedBufferFrameSize(
                CoreAudioDeviceQuery.maxBufferFrameSize + 1,
                objectID: 42
            )
        }

        #expect(try CoreAudioDeviceQuery.validatedSampleRate(48_000, objectID: 42) == 48_000)
        #expect(try CoreAudioDeviceQuery.validatedBufferFrameSize(256, objectID: 42) == 256)
    }

    @Test
    func availabilityErrorsProvideLocalizedDescriptions() {
        #expect(AudioDeviceAvailabilityError.noDefaultOutput.localizedDescription == "No default output device is available")
        #expect(AudioDeviceAvailabilityError.outputDeviceNotAlive(42).localizedDescription == "Output device 42 is not available")
    }

    @Test
    func engineRuntimeChannelPolicyAcceptsUpToMaxChannelCount() throws {
        #expect(try SystemTapAudioEngine.supportedRuntimeChannelCount(for: output(channelCount: 1)) == 1)
        #expect(try SystemTapAudioEngine.supportedRuntimeChannelCount(for: output(channelCount: 2)) == 2)
        #expect(try SystemTapAudioEngine.supportedRuntimeChannelCount(for: output(channelCount: 6)) == 6)
        #expect(try SystemTapAudioEngine.supportedRuntimeChannelCount(
            for: output(channelCount: CoreAudioDeviceQuery.maxChannelCount)
        ) == CoreAudioDeviceQuery.maxChannelCount)

        do {
            _ = try SystemTapAudioEngine.supportedRuntimeChannelCount(for: output(channelCount: 0))
            Issue.record("Expected zero-channel output to be rejected")
        } catch let error as AudioDeviceAvailabilityError {
            #expect(error == .outputDeviceHasNoOutputChannels(42))
        } catch {
            Issue.record("Expected no-output-channels error, got \(error)")
        }

        do {
            _ = try SystemTapAudioEngine.supportedRuntimeChannelCount(
                for: output(channelCount: CoreAudioDeviceQuery.maxChannelCount + 1)
            )
            Issue.record("Expected out-of-range channel count to be rejected")
        } catch let error as AudioDeviceAvailabilityError {
            #expect(error == .unsupportedOutputChannelCount(42, CoreAudioDeviceQuery.maxChannelCount + 1))
        } catch {
            Issue.record("Expected unsupported channel count error, got \(error)")
        }
    }

    @Test
    func playbackCallbackCapacityRejectsFramesAboveFixedRenderStorage() throws {
        try SystemTapAudioEngine.validatePlaybackCallbackCapacity(
            for: output(channelCount: 2, bufferFrameSize: 8_192)
        )

        do {
            try SystemTapAudioEngine.validatePlaybackCallbackCapacity(
                for: output(channelCount: 2, bufferFrameSize: 8_193)
            )
            Issue.record("Expected oversized playback callback to be rejected")
        } catch let error as AudioDeviceAvailabilityError {
            #expect(error == .unsupportedOutputBufferFrameSize(42, 8_193, maximum: 8_192))
        } catch {
            Issue.record("Expected unsupported buffer frame size error, got \(error)")
        }
    }

    @Test
    func playbackConversionCapacityRejectsPrimesWithoutRingHeadroom() throws {
        try SystemTapAudioEngine.validatePlaybackConversionCapacity(
            for: output(channelCount: 2, sampleRate: 16_000, bufferFrameSize: 8_192),
            tapSampleRate: 48_000
        )
        try SystemTapAudioEngine.validatePlaybackConversionCapacity(
            for: output(channelCount: 2, sampleRate: 16_000, bufferFrameSize: 1_024),
            tapSampleRate: 192_000
        )

        do {
            try SystemTapAudioEngine.validatePlaybackConversionCapacity(
                for: output(channelCount: 2, sampleRate: 16_000, bufferFrameSize: 8_192),
                tapSampleRate: 96_000
            )
            Issue.record("Expected oversized converted playback prime to be rejected")
        } catch let error as AudioDeviceAvailabilityError {
            #expect(error == .unsupportedPlaybackConversionBuffer(
                42,
                requiredPrimeFrames: 50_176,
                maximumPrimeFrames: 40_960
            ))
        } catch {
            Issue.record("Expected unsupported converted playback buffer error, got \(error)")
        }
    }

    @Test
    func unsupportedRuntimeChannelCountSkipsDevicePreparation() {
        var didPrepareDevice = false
        let channelCount = CoreAudioDeviceQuery.maxChannelCount + 1

        do {
            _ = try SystemTapAudioEngine.performAfterRuntimeChannelValidation(
                for: output(channelCount: channelCount, sampleRate: 44_100)
            ) {
                didPrepareDevice = true
                return output(channelCount: channelCount, sampleRate: 48_000)
            }
            Issue.record("Expected out-of-range output to be rejected")
        } catch let error as AudioDeviceAvailabilityError {
            #expect(error == .unsupportedOutputChannelCount(42, channelCount))
        } catch {
            Issue.record("Expected unsupported channel count error, got \(error)")
        }

        #expect(!didPrepareDevice)
    }

    @Test
    func outputDeviceUIDLookupResolvesDefaultOutput() throws {
        let defaultOutput = try CoreAudioDeviceQuery.defaultOutputDevice()
        let resolvedOutput = try #require(try CoreAudioDeviceQuery.outputDevice(uid: defaultOutput.uid))

        #expect(resolvedOutput.uid == defaultOutput.uid)
        #expect(resolvedOutput.outputChannelCount > 0)
        #expect(try CoreAudioDeviceQuery.outputDevice(uid: "") == nil)
    }

    @Test
    func sampleRateMutationRecordsRestorationBeforeDeviceWrite() throws {
        let output = output(uid: "record-before-set", channelCount: 2, sampleRate: 44_100)
        var events: [String] = []

        try SystemTapAudioEngine.setSampleRateAfterRecordingRestoration(
            48_000,
            on: output,
            needsRestoration: true,
            recordRestoration: { restoration in
                #expect(restoration.uid == output.uid)
                #expect(restoration.originalSampleRate == 44_100)
                events.append("record")
            },
            installRestoration: { restoration in
                #expect(restoration.uid == output.uid)
                events.append("install")
            },
            setSampleRate: { sampleRate, objectID in
                #expect(sampleRate == 48_000)
                #expect(objectID == output.id)
                events.append("set")
            }
        )

        #expect(events == ["record", "install", "set"])
    }

    @Test
    func sampleRateMutationSkipsDeviceWriteWhenRestorationRecordFails() {
        let output = output(uid: "record-fails", channelCount: 2, sampleRate: 44_100)
        var didInstall = false
        var didSet = false

        #expect(throws: TestDeviceMutationError.recordFailed) {
            try SystemTapAudioEngine.setSampleRateAfterRecordingRestoration(
                48_000,
                on: output,
                needsRestoration: true,
                recordRestoration: { _ in throw TestDeviceMutationError.recordFailed },
                installRestoration: { _ in didInstall = true },
                setSampleRate: { _, _ in didSet = true }
            )
        }

        #expect(!didInstall)
        #expect(!didSet)
    }

    @Test
    func sampleRateRestorationUsesFreshUIDDeviceAndVerifiesWrite() {
        var currentSampleRate = 44_100.0
        var setCalls: [(sampleRate: Double, objectID: AudioObjectID)] = []
        let restoration = SystemTapAudioEngine.SampleRateRestoration(
            uid: "restored-output",
            originalSampleRate: 48_000
        )

        let restored = SystemTapAudioEngine.restoreSampleRateRestoration(
            restoration,
            outputForUID: { uid in
                #expect(uid == restoration.uid)
                return output(
                    id: 9_001,
                    uid: uid,
                    channelCount: 2,
                    sampleRate: currentSampleRate
                )
            },
            setSampleRate: { sampleRate, objectID in
                setCalls.append((sampleRate, objectID))
                currentSampleRate = sampleRate
            }
        )

        #expect(restored)
        #expect(setCalls.count == 1)
        #expect(setCalls.first?.sampleRate == 48_000)
        #expect(setCalls.first?.objectID == 9_001)
    }

    @Test
    func sameOutputRebuildReinstallsRestorationFromFreshDeviceRate() throws {
        let uid = "same-output"
        let objectID = AudioObjectID(9_003)
        var currentSampleRate = 48_000.0
        let originalRestoration = SystemTapAudioEngine.SampleRateRestoration(
            uid: uid,
            originalSampleRate: 44_100
        )
        let outputForUID: (String) throws -> AudioOutputDevice? = { requestedUID in
            #expect(requestedUID == uid)
            return output(
                id: objectID,
                uid: uid,
                channelCount: 2,
                sampleRate: currentSampleRate
            )
        }
        let setSampleRate: (Double, AudioObjectID) throws -> Void = { sampleRate, requestedID in
            #expect(requestedID == objectID)
            currentSampleRate = sampleRate
        }

        #expect(SystemTapAudioEngine.restoreSampleRateRestoration(
            originalRestoration,
            outputForUID: outputForUID,
            setSampleRate: setSampleRate
        ))
        let refreshedOutput = try #require(try outputForUID(uid))
        #expect(refreshedOutput.nominalSampleRate == 44_100)
        #expect(SystemTapAudioEngine.shouldRecordSampleRateRestoration(
            tapSampleRate: 48_000,
            output: refreshedOutput
        ))

        var replacementRestoration: SystemTapAudioEngine.SampleRateRestoration?
        try SystemTapAudioEngine.setSampleRateAfterRecordingRestoration(
            48_000,
            on: refreshedOutput,
            needsRestoration: true,
            recordRestoration: { replacementRestoration = $0 },
            installRestoration: { _ in },
            setSampleRate: setSampleRate
        )
        #expect(currentSampleRate == 48_000)
        #expect(SystemTapAudioEngine.restoreSampleRateRestoration(
            try #require(replacementRestoration),
            outputForUID: outputForUID,
            setSampleRate: setSampleRate
        ))
        #expect(currentSampleRate == 44_100)
    }

    @Test
    func sampleRateRestorationIsRetainedWhenDeviceIsAbsentOrWriteCannotBeVerified() {
        var setCallCount = 0
        let restoration = SystemTapAudioEngine.SampleRateRestoration(
            uid: "missing-output",
            originalSampleRate: 48_000
        )

        let absentRestored = SystemTapAudioEngine.restoreSampleRateRestoration(
            restoration,
            outputForUID: { _ in nil },
            setSampleRate: { _, _ in setCallCount += 1 }
        )

        #expect(!absentRestored)
        #expect(setCallCount == 0)

        let unverifiedRestored = SystemTapAudioEngine.restoreSampleRateRestoration(
            restoration,
            outputForUID: { uid in
                output(id: 9_002, uid: uid, channelCount: 2, sampleRate: 44_100)
            },
            setSampleRate: { _, _ in setCallCount += 1 }
        )

        #expect(!unverifiedRestored)
        #expect(setCallCount == 1)
    }

    @Test
    func bufferFrameSizeRestorationUsesFreshUIDDeviceAndVerifiesWrite() {
        var currentFrameSize: UInt32 = 512
        var setCalls: [(frameSize: UInt32, objectID: AudioObjectID)] = []
        let restoration = SystemTapAudioEngine.BufferFrameSizeRestoration(
            uid: "buffer-output",
            originalFrameSize: 256
        )

        let restored = SystemTapAudioEngine.restoreBufferFrameSizeRestoration(
            restoration,
            outputForUID: { uid in
                #expect(uid == restoration.uid)
                return output(
                    id: 9_003,
                    uid: uid,
                    channelCount: 2,
                    bufferFrameSize: currentFrameSize
                )
            },
            setBufferFrameSize: { frameSize, objectID in
                setCalls.append((frameSize, objectID))
                currentFrameSize = frameSize
            }
        )

        #expect(restored)
        #expect(setCalls.count == 1)
        #expect(setCalls.first?.frameSize == 256)
        #expect(setCalls.first?.objectID == 9_003)
    }

    @Test
    func bufferFrameSizeRestorationSkipsAlreadyRestoredDevice() {
        var didSet = false
        let restoration = SystemTapAudioEngine.BufferFrameSizeRestoration(
            uid: "already-restored-buffer-output",
            originalFrameSize: 256
        )

        let restored = SystemTapAudioEngine.restoreBufferFrameSizeRestoration(
            restoration,
            outputForUID: { uid in
                output(id: 9_004, uid: uid, channelCount: 2, bufferFrameSize: 256)
            },
            setBufferFrameSize: { _, _ in didSet = true }
        )

        #expect(restored)
        #expect(!didSet)
    }

    @Test
    func persistedDeviceRestorationRestoresAndClearsVerifiedSettings() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQDeviceRestoration-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        try PersistedAudioDeviceRestorationStore.recordSampleRate(uid: "dac", originalSampleRate: 48_000, at: url)
        try PersistedAudioDeviceRestorationStore.recordBufferFrameSize(uid: "dac", originalFrameSize: 256, at: url)
        var sampleRate = 44_100.0
        var frameSize: UInt32 = 512

        SystemTapAudioEngine.restorePersistedDeviceSettings(
            at: url,
            outputForUID: { uid in
                output(uid: uid, channelCount: 2, sampleRate: sampleRate, bufferFrameSize: frameSize)
            },
            setSampleRate: { nextSampleRate, _ in
                sampleRate = nextSampleRate
            },
            setBufferFrameSize: { nextFrameSize, _ in
                frameSize = nextFrameSize
            }
        )

        #expect(PersistedAudioDeviceRestorationStore.load(from: url).isEmpty)
        #expect(sampleRate == 48_000)
        #expect(frameSize == 256)
    }

    @Test
    func persistedDeviceRestorationKeepsUnavailableDeviceRecords() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQDeviceRestoration-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        try PersistedAudioDeviceRestorationStore.recordSampleRate(uid: "missing", originalSampleRate: 48_000, at: url)

        SystemTapAudioEngine.restorePersistedDeviceSettings(
            at: url,
            outputForUID: { _ in nil },
            setSampleRate: { _, _ in Issue.record("Unexpected sample-rate write") },
            setBufferFrameSize: { _, _ in Issue.record("Unexpected buffer-size write") }
        )

        #expect(PersistedAudioDeviceRestorationStore.load(from: url)["missing"]?.originalSampleRate == 48_000)
    }

    @Test
    func persistedDeviceRestorationDoesNotOverwritePendingOriginals() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQDeviceRestoration-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try PersistedAudioDeviceRestorationStore.recordSampleRate(uid: "dac", originalSampleRate: 48_000, at: url)
        try PersistedAudioDeviceRestorationStore.recordSampleRate(uid: "dac", originalSampleRate: 44_100, at: url)
        try PersistedAudioDeviceRestorationStore.recordBufferFrameSize(uid: "dac", originalFrameSize: 256, at: url)
        try PersistedAudioDeviceRestorationStore.recordBufferFrameSize(uid: "dac", originalFrameSize: 512, at: url)

        let record = try #require(PersistedAudioDeviceRestorationStore.load(from: url)["dac"])
        #expect(record.originalSampleRate == 48_000)
        #expect(record.originalBufferFrameSize == 256)
    }

    @Test
    func persistedDeviceRestorationFoldsDuplicateUIDRecordsWithoutTrapping() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQDeviceRestoration-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let records = [
            PersistedAudioDeviceRestorationRecord(uid: "dac", originalSampleRate: 48_000),
            PersistedAudioDeviceRestorationRecord(uid: "dac", originalSampleRate: 44_100),
            PersistedAudioDeviceRestorationRecord(uid: "dac", originalBufferFrameSize: 256),
            PersistedAudioDeviceRestorationRecord(uid: "dac", originalBufferFrameSize: 512),
            PersistedAudioDeviceRestorationRecord(uid: "headphones", originalBufferFrameSize: 1_024)
        ]
        try JSONEncoder().encode(records).write(to: url)

        let loaded = PersistedAudioDeviceRestorationStore.load(from: url)

        let dac = try #require(loaded["dac"])
        #expect(dac.originalSampleRate == 48_000)
        #expect(dac.originalBufferFrameSize == 256)
        #expect(loaded["headphones"]?.originalBufferFrameSize == 1_024)
    }

    @Test
    func monoRuntimeOutputDownmixesStereoInsteadOfUsingLeftOnly() {
        let samples: [Float] = [
            1, 3,
            -2, 4,
            10, -4
        ]

        samples.withUnsafeBufferPointer { pointer in
            #expect(SystemTapAudioEngine.monoDownmix(pointer, frame: 0, sourceChannelCount: 2) == 2)
            #expect(SystemTapAudioEngine.monoDownmix(pointer, frame: 1, sourceChannelCount: 2) == 1)
            #expect(SystemTapAudioEngine.monoDownmix(pointer, frame: 2, sourceChannelCount: 2) == 3)
            #expect(SystemTapAudioEngine.monoDownmix(pointer, frame: -1, sourceChannelCount: 2) == 0)
            #expect(SystemTapAudioEngine.monoDownmix(pointer, frame: 99, sourceChannelCount: 2) == 0)
        }
    }

    @Test
    func monoSourceDuplicatesIntoSingleInterleavedStereoOutputBuffer() {
        let samples: [Float] = [1, 2]
        var destination: [Float] = [-1, -1, -1, -1, -1, -1]

        samples.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                let audioBuffer = AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(destinationBuffer.count * MemoryLayout<Float>.stride),
                    mData: destinationBuffer.baseAddress
                )
                var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
                withUnsafeMutablePointer(to: &audioBufferList) { audioBufferListPointer in
                    SystemTapAudioEngine.copyInterleavedSamples(
                        source,
                        sourceFrameOffset: 0,
                        destinationFrameOffset: 1,
                        frameCount: 2,
                        sourceChannelCount: 1,
                        to: UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
                    )
                }
            }
        }

        #expect(destination == [-1, -1, 1, 1, 2, 2])
    }

    @Test
    func preferredBufferFrameSizeShrinksStandardSpeakerRoutesForLowLatency() {
        #expect(SystemTapAudioEngine.preferredBufferFrameSize(for: output(channelCount: 2, bufferFrameSize: 128)) == 64)
        #expect(SystemTapAudioEngine.preferredBufferFrameSize(for: output(channelCount: 2, bufferFrameSize: 512)) == 64)
        #expect(SystemTapAudioEngine.preferredBufferFrameSize(for: output(channelCount: 2, bufferFrameSize: 2_048)) == 64)
    }

    @Test
    func bluetoothAndLowSampleRateRoutesKeepRouteSpecificBufferPreferences() {
        #expect(SystemTapAudioEngine.preferredBufferFrameSize(
            for: output(channelCount: 2, bufferFrameSize: 256, transportType: kAudioDeviceTransportTypeBluetooth)
        ) == 64)
        #expect(SystemTapAudioEngine.preferredBufferFrameSize(
            for: output(channelCount: 2, sampleRate: 16_000, bufferFrameSize: 256)
        ) == 1_024)
    }

    @Test
    func playbackPrimeTracksTheTunedRouteCallbackSize() {
        #expect(SystemTapAudioEngine.preferredPlaybackPrimeFrames(
            for: output(channelCount: 2, bufferFrameSize: 64)
        ) == 128)
        #expect(SystemTapAudioEngine.preferredPlaybackPrimeFrames(
            for: output(channelCount: 2, bufferFrameSize: 128)
        ) == 192)
        #expect(SystemTapAudioEngine.preferredPlaybackPrimeFrames(
            for: output(
                channelCount: 2,
                bufferFrameSize: 64,
                transportType: kAudioDeviceTransportTypeBluetooth
            )
        ) == 128)
        #expect(SystemTapAudioEngine.preferredPlaybackPrimeFrames(
            for: output(
                channelCount: 2,
                bufferFrameSize: 1_024,
                transportType: kAudioDeviceTransportTypeBluetooth
            )
        ) == 1_088)
        #expect(SystemTapAudioEngine.preferredPlaybackPrimeFrames(
            for: output(channelCount: 2, sampleRate: 16_000, bufferFrameSize: 1_024)
        ) == 2_048)
        #expect(SystemTapAudioEngine.preferredPlaybackPrimeFrames(
            for: output(channelCount: 2, sampleRate: 24_000, bufferFrameSize: 1_024),
            tapSampleRate: 48_000
        ) == 3_072)
        #expect(SystemTapAudioEngine.preferredPlaybackPrimeFrames(
            for: output(channelCount: 2, sampleRate: 16_000, bufferFrameSize: 1_024),
            tapSampleRate: 48_000
        ) == 4_096)
        #expect(SystemTapAudioEngine.preferredPlaybackPrimeFrames(
            for: output(channelCount: 2, sampleRate: 48_000, bufferFrameSize: 64),
            tapSampleRate: 24_000
        ) == 1_056)
    }

    @Test
    func headsetSampleRateConversionHandlesBothTransitionDirections() {
        let headsetOutput = output(
            channelCount: 2,
            sampleRate: 24_000,
            bufferFrameSize: 1_024,
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        let normalOutput = output(
            channelCount: 2,
            sampleRate: 48_000,
            bufferFrameSize: 128,
            transportType: kAudioDeviceTransportTypeBluetooth
        )

        #expect(SystemTapAudioEngine.shouldUseSampleRateConversion(
            tapSampleRate: 48_000,
            output: headsetOutput
        ))
        #expect(!SystemTapAudioEngine.shouldUseSampleRateConversion(
            tapSampleRate: 48_000,
            output: normalOutput
        ))
        #expect(SystemTapAudioEngine.shouldUseSampleRateConversion(
            tapSampleRate: 24_000,
            output: normalOutput
        ))
        #expect(!SystemTapAudioEngine.shouldUseSampleRateConversion(
            tapSampleRate: 24_000,
            output: headsetOutput
        ))
        #expect(SystemTapAudioEngine.shouldRefreshCaptureForOutput(
            tapSampleRate: 24_000,
            output: normalOutput
        ))
        #expect(SystemTapAudioEngine.shouldRefreshCaptureForOutput(
            tapSampleRate: 16_000,
            output: headsetOutput
        ))
        #expect(!SystemTapAudioEngine.shouldRefreshCaptureForOutput(
            tapSampleRate: 24_000,
            output: output(
                channelCount: 2,
                sampleRate: 16_000,
                bufferFrameSize: 1_024,
                transportType: kAudioDeviceTransportTypeBluetooth
            )
        ))
        #expect(!SystemTapAudioEngine.shouldRefreshCaptureForOutput(
            tapSampleRate: 48_000,
            output: headsetOutput
        ))
        #expect(SystemTapAudioEngine.maximumPlaybackReservoirFrames(
            for: normalOutput,
            tapSampleRate: 24_000,
            maximumObservedCaptureCallbackFrames: 768
        ) == 1_024)
        #expect(SystemTapAudioEngine.maximumPlaybackReservoirFrames(
            for: normalOutput,
            tapSampleRate: 48_000,
            maximumObservedCaptureCallbackFrames: 768
        ) == AdaptivePlaybackBufferPolicy.maximumReservoirFrames)
    }

    @Test
    func outputRebuildUsesAProfileHotSwappedAfterPreparation() {
        let prepared = EQProfile(name: "Prepared", mode: .parametric, filters: [])
        let hotSwapped = EQProfile(name: "Hot Swapped", mode: .parametric, filters: [])

        #expect(SystemTapAudioEngine.effectiveOutputRebuildProfile(
            preparedProfile: prepared,
            preparedProfileRevision: 1,
            activeProfile: prepared,
            activeProfileRevision: 1
        ) == prepared)
        #expect(SystemTapAudioEngine.effectiveOutputRebuildProfile(
            preparedProfile: prepared,
            preparedProfileRevision: 1,
            activeProfile: hotSwapped,
            activeProfileRevision: 2
        ) == hotSwapped)
    }

    @Test
    func staleOutputRebuildRequestUsesTheCurrentProfile() {
        let requested = EQProfile(name: "Requested", mode: .parametric, filters: [])
        let current = EQProfile(name: "Current", mode: .parametric, filters: [])

        #expect(SystemTapAudioEngine.requestedOutputRebuildProfile(
            requestedProfile: requested,
            expectedProfileRevision: 1,
            activeProfile: requested,
            activeProfileRevision: 1
        ) == requested)
        #expect(SystemTapAudioEngine.requestedOutputRebuildProfile(
            requestedProfile: requested,
            expectedProfileRevision: 1,
            activeProfile: current,
            activeProfileRevision: 2
        ) == current)
    }

    @Test
    func profileUpdateRejectsTheTemporaryGapInAnOutputRebuild() throws {
        #expect(throws: AudioEngineProfileUpdateUnavailable.self) {
            _ = try SystemTapAudioEngine.profileUpdateOutput(nil)
        }

        let activeOutput = output(uid: "profile-update-output", channelCount: 2)
        #expect(try SystemTapAudioEngine.profileUpdateOutput(activeOutput) == activeOutput)
    }

    @Test
    func adaptivePlaybackBufferAppliesToEveryValidOutputRate() {
        #expect(SystemTapAudioEngine.shouldAdaptPlaybackBuffer(
            for: output(channelCount: 2, bufferFrameSize: 64)
        ))
        #expect(SystemTapAudioEngine.shouldAdaptPlaybackBuffer(
            for: output(
                channelCount: 2,
                bufferFrameSize: 64,
                transportType: kAudioDeviceTransportTypeBluetooth
            )
        ))
        #expect(SystemTapAudioEngine.shouldAdaptPlaybackBuffer(
            for: output(channelCount: 2, sampleRate: 16_000, bufferFrameSize: 1_024)
        ))
        #expect(SystemTapAudioEngine.playbackInputCallbackFrames(
            for: output(channelCount: 2, sampleRate: 16_000, bufferFrameSize: 1_024),
            tapSampleRate: 48_000
        ) == 3_072)
    }

    @Test
    func runtimeRingAlwaysLeavesHeadroomAboveTheLargestPrime() {
        let largestPrime = SystemTapAudioEngine.preferredPlaybackPrimeFrames(
            for: output(channelCount: 2, bufferFrameSize: 8_192)
        )

        #expect(largestPrime == 8_256)
        #expect(SystemTapAudioEngine.runtimeRingCapacityFrames >= largestPrime * 2)

        let largestConvertedPrime = SystemTapAudioEngine.preferredPlaybackPrimeFrames(
            for: output(channelCount: 2, sampleRate: 16_000, bufferFrameSize: 8_192),
            tapSampleRate: 48_000
        )
        #expect(SystemTapAudioEngine.runtimeRingCapacityFrames >= largestConvertedPrime * 2)
    }

    @Test
    func adaptiveBufferLadderStopsAtStableLegacySize() {
        let range = AudioBufferFrameSizeRange(minimum: 15, maximum: 960)

        #expect(AdaptivePlaybackBufferPolicy.nextFrameSize(after: 64, supportedRange: range) == 128)
        #expect(AdaptivePlaybackBufferPolicy.nextFrameSize(after: 128, supportedRange: range) == 256)
        #expect(AdaptivePlaybackBufferPolicy.nextFrameSize(after: 256, supportedRange: range) == 512)
        #expect(AdaptivePlaybackBufferPolicy.nextFrameSize(after: 512, supportedRange: range) == nil)
        #expect(AdaptivePlaybackBufferPolicy.previousFrameSize(before: 512, supportedRange: range) == 256)
        #expect(AdaptivePlaybackBufferPolicy.previousFrameSize(before: 128, supportedRange: range) == 64)
        #expect(AdaptivePlaybackBufferPolicy.previousFrameSize(before: 64, supportedRange: range) == 15)
    }

    @Test
    func adaptiveBufferLadderHonorsPartialDeviceRange() {
        let range = AudioBufferFrameSizeRange(minimum: 96, maximum: 300)

        #expect(AdaptivePlaybackBufferPolicy.nextFrameSize(after: 96, supportedRange: range) == 128)
        #expect(AdaptivePlaybackBufferPolicy.nextFrameSize(after: 128, supportedRange: range) == 256)
        #expect(AdaptivePlaybackBufferPolicy.nextFrameSize(after: 256, supportedRange: range) == 300)
        #expect(AdaptivePlaybackBufferPolicy.nextFrameSize(after: 300, supportedRange: range) == nil)
    }

    @Test
    func adaptiveBufferRenegotiationWritesAndVerifiesTheNextStep() throws {
        let current = output(
            channelCount: 2,
            bufferFrameSize: 64,
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        var requestedFrameSize: UInt32?

        let updated = try SystemTapAudioEngine.renegotiatedPlaybackOutput(
            current,
            supportedRange: AudioBufferFrameSizeRange(minimum: 15, maximum: 960),
            setBufferFrameSize: { frameSize, objectID in
                #expect(objectID == current.id)
                requestedFrameSize = frameSize
            },
            queryOutput: { objectID in
                #expect(objectID == current.id)
                return output(
                    id: objectID,
                    channelCount: 2,
                    bufferFrameSize: 128,
                    transportType: kAudioDeviceTransportTypeBluetooth
                )
            }
        )

        #expect(requestedFrameSize == 128)
        #expect(updated?.bufferFrameSize == 128)
    }

    @Test
    func adaptiveBufferRenegotiationWaitsForTheDevicePropertyToSettle() throws {
        let current = output(channelCount: 2, bufferFrameSize: 64)
        var queryCount = 0
        var waitCount = 0

        let updated = try SystemTapAudioEngine.renegotiatedPlaybackOutput(
            current,
            supportedRange: AudioBufferFrameSizeRange(minimum: 64, maximum: 512),
            setBufferFrameSize: { _, _ in },
            queryOutput: { objectID in
                queryCount += 1
                return output(
                    id: objectID,
                    channelCount: 2,
                    bufferFrameSize: queryCount < 3 ? 64 : 128
                )
            },
            waitForPropertySettlement: {
                waitCount += 1
            }
        )

        #expect(queryCount == 3)
        #expect(waitCount == 2)
        #expect(updated?.bufferFrameSize == 128)
    }

    @Test
    func topologyRebuildAcquiresMuteGuardBeforeRebuildAndReleasesAfter() throws {
        var events: [String] = []
        let result = try SystemTapAudioEngine.performTopologyRebuild(
            acquireMuteGuard: {
                events.append("acquire")
                return FakeTopologyRebuildMuteGuard(events: { events.append($0) })
            },
            rebuild: {
                events.append("rebuild")
                return 7
            }
        )

        #expect(result == 7)
        #expect(events == ["acquire", "rebuild", "release"])
    }

    @Test
    func topologyRebuildSkipsTeardownWhenMuteGuardCannotBeAcquired() {
        var rebuildWasCalled = false

        #expect(throws: TopologyRebuildMuteGuardUnavailable.self) {
            _ = try SystemTapAudioEngine.performTopologyRebuild(
                acquireMuteGuard: {
                    throw CoreAudioError(operation: "test mute guard", status: kAudioHardwareUnspecifiedError)
                },
                rebuild: {
                    rebuildWasCalled = true
                }
            )
        }
        #expect(!rebuildWasCalled)
    }

    @Test
    func selfChangeGuardSuppressesOnlyMatchingDevice() {
        let changeGuard = CoreAudioSelfChangeGuard(windowMilliseconds: 1_000)

        changeGuard.beginSelfChange(deviceID: 42)

        #expect(changeGuard.isSelfChange(deviceID: 42))
        #expect(!changeGuard.isSelfChange(deviceID: 43))
    }

    @Test
    func selfChangeGuardExpires() async throws {
        let changeGuard = CoreAudioSelfChangeGuard(windowMilliseconds: 1)

        changeGuard.beginSelfChange(deviceID: 42)
        try await Task.sleep(nanoseconds: 5_000_000)

        #expect(!changeGuard.isSelfChange(deviceID: 42))
    }

    @Test
    func outputObserverNeverSuppressesDeviceAliveNotifications() {
        let changeGuard = CoreAudioSelfChangeGuard(windowMilliseconds: 1_000)
        changeGuard.beginSelfChange(deviceID: 42)

        #expect(DefaultOutputDeviceObserver.shouldSuppressSelfInducedOutputChange(
            selector: kAudioDevicePropertyBufferFrameSize,
            deviceID: 42,
            selfChangeGuard: changeGuard
        ))
        #expect(!DefaultOutputDeviceObserver.shouldSuppressSelfInducedOutputChange(
            selector: kAudioDevicePropertyDeviceIsAlive,
            deviceID: 42,
            selfChangeGuard: changeGuard
        ))
    }

    @Test
    func refreshCoalescerRunsOnlyLatestScheduledAction() {
        let queue = DispatchQueue(label: "com.glasseq.tests.refresh-coalescer")
        let coalescer = DispatchRefreshCoalescer(queue: queue, delay: .milliseconds(10))
        let counter = LockedCounter()

        queue.sync {
            coalescer.schedule {
                counter.increment()
            }
            coalescer.schedule {
                counter.increment()
            }
            coalescer.schedule {
                counter.increment()
            }
        }

        Thread.sleep(forTimeInterval: 0.05)
        queue.sync {}

        #expect(counter.value == 1)
    }

    @Test
    func refreshCoalescerCancelSuppressesPendingAction() {
        let queue = DispatchQueue(label: "com.glasseq.tests.refresh-coalescer-cancel")
        let coalescer = DispatchRefreshCoalescer(queue: queue, delay: .milliseconds(10))
        let counter = LockedCounter()

        queue.sync {
            coalescer.schedule {
                counter.increment()
            }
            coalescer.cancelPending()
        }

        Thread.sleep(forTimeInterval: 0.05)
        queue.sync {}

        #expect(counter.value == 0)
    }

    @Test
    func dspHotSwapAllowsSameTopologyParameterAndBypassChanges() {
        let active = EQProfile(
            name: "Active",
            mode: .graphic10,
            preampDB: -3,
            filters: EQProfile.flatGraphic10.filters
        )
        var next = active
        next.preampDB = -4
        next.filters[0].gainDB = 3
        next.filters[1].frequency = 70
        next.isBypassed = true

        #expect(SystemTapAudioEngine.canHotSwapDSP(
            from: active,
            to: next,
            sampleRate: 48_000,
            channelCount: 2
        ))
    }

    @Test
    func dspHotSwapRejectsTopologyChangingProfiles() {
        let graphic = EQProfile(
            name: "Graphic",
            mode: .graphic10,
            filters: EQProfile.flatGraphic10.filters
        )

        var disabledBand = graphic
        disabledBand.filters[0].isEnabled = false
        #expect(!SystemTapAudioEngine.canHotSwapDSP(
            from: graphic,
            to: disabledBand,
            sampleRate: 48_000,
            channelCount: 2
        ))

        let parametric = EQProfile(
            name: "Parametric",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: 0, q: 1)]
        )
        var addedFilter = parametric
        addedFilter.filters.append(EQFilter(kind: .peak, frequency: 2_000, gainDB: 0, q: 1))
        #expect(!SystemTapAudioEngine.canHotSwapDSP(
            from: parametric,
            to: addedFilter,
            sampleRate: 48_000,
            channelCount: 2
        ))

        let modeSwitch = EQProfile(
            name: "Parametric Same Count",
            mode: .parametric,
            filters: graphic.filters
        )
        #expect(!SystemTapAudioEngine.canHotSwapDSP(
            from: graphic,
            to: modeSwitch,
            sampleRate: 48_000,
            channelCount: 2
        ))

        var stereoSwitch = graphic
        stereoSwitch.channelMode = .stereo
        #expect(!SystemTapAudioEngine.canHotSwapDSP(
            from: graphic,
            to: stereoSwitch,
            sampleRate: 48_000,
            channelCount: 2
        ))
    }

    @Test
    func renderConfigurationTopologyRejectsFormatChanges() {
        let profile = EQProfile.flatGraphic10
        let active = EQRenderConfiguration(profile: profile, sampleRate: 48_000, channelCount: 2)
        let sampleRateChange = EQRenderConfiguration(profile: profile, sampleRate: 44_100, channelCount: 2)
        let channelCountChange = EQRenderConfiguration(profile: profile, sampleRate: 48_000, channelCount: 1)

        #expect(!sampleRateChange.hasRealtimeCompatibleTopology(with: active))
        #expect(!channelCountChange.hasRealtimeCompatibleTopology(with: active))
    }

    @Test
    func metadataValidationRejectsInvalidRangesAndSizes() throws {
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.validatedBufferFrameSizeRange(
                AudioValueRange(mMinimum: 512, mMaximum: 256),
                objectID: 42
            )
        }
        expectInvalidMetadata {
            try CoreAudioDeviceQuery.validateStreamConfigurationSize(4, objectID: 42)
        }
        expectInvalidMetadata {
            try CoreAudioDeviceQuery.validateStreamConfigurationSize(
                CoreAudioDeviceQuery.maxStreamConfigurationBytes + 1,
                objectID: 42
            )
        }
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.checkedSampleCount(
                frames: Int(CoreAudioDeviceQuery.maxBufferFrameSize) + 1,
                channels: CoreAudioDeviceQuery.maxChannelCount,
                objectID: 42
            )
        }

        let range = try CoreAudioDeviceQuery.validatedBufferFrameSizeRange(
            AudioValueRange(mMinimum: 127.2, mMaximum: 256.8),
            objectID: 42
        )
        #expect(range == AudioBufferFrameSizeRange(minimum: 128, maximum: 256))
    }

    private func expectInvalidMetadata(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected invalid Core Audio metadata to be rejected")
        } catch let error as AudioDeviceAvailabilityError {
            guard case .invalidDeviceMetadata = error else {
                Issue.record("Expected invalid metadata error, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected invalid metadata error, got \(error)")
        }
    }

    private func output(
        id: AudioObjectID = 42,
        uid: String = "test-output",
        channelCount: Int,
        sampleRate: Double = 48_000,
        bufferFrameSize: UInt32 = 256,
        transportType: UInt32? = nil
    ) -> AudioOutputDevice {
        AudioOutputDevice(
            id: id,
            uid: uid,
            name: "Test Output",
            nominalSampleRate: sampleRate,
            outputChannelCount: channelCount,
            bufferFrameSize: bufferFrameSize,
            transportType: transportType
        )
    }
}

private enum TestDeviceMutationError: Error {
    case recordFailed
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return count
    }
}

private final class FakeTopologyRebuildMuteGuard: TopologyRebuildMuteGuarding {
    private let record: (String) -> Void

    init(events record: @escaping (String) -> Void) {
        self.record = record
    }

    func release() {
        record("release")
    }
}
