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
    func engineRuntimeChannelPolicyAcceptsMonoAndStereoOnly() throws {
        #expect(try SystemTapAudioEngine.supportedRuntimeChannelCount(for: output(channelCount: 1)) == 1)
        #expect(try SystemTapAudioEngine.supportedRuntimeChannelCount(for: output(channelCount: 2)) == 2)

        do {
            _ = try SystemTapAudioEngine.supportedRuntimeChannelCount(for: output(channelCount: 3))
            Issue.record("Expected multichannel output to be rejected")
        } catch let error as AudioDeviceAvailabilityError {
            #expect(error == .unsupportedOutputChannelCount(42, 3))
        } catch {
            Issue.record("Expected unsupported channel count error, got \(error)")
        }
    }

    @Test
    func bufferFrameRestorationPolicyRestoresOnlyWhenOutputChanges() {
        let current = output(id: 42, uid: "same", channelCount: 2)

        #expect(!SystemTapAudioEngine.shouldRestoreBufferFrameSizeBeforeRestart(
            currentOutput: nil,
            nextOutput: current
        ))
        #expect(!SystemTapAudioEngine.shouldRestoreBufferFrameSizeBeforeRestart(
            currentOutput: current,
            nextOutput: output(id: 42, uid: "same", channelCount: 2)
        ))
        #expect(SystemTapAudioEngine.shouldRestoreBufferFrameSizeBeforeRestart(
            currentOutput: current,
            nextOutput: output(id: 43, uid: "other", channelCount: 2)
        ))
    }

    @Test
    func runtimeBufferFrameSizeCapsOversizedDeviceBuffers() {
        #expect(SystemTapAudioEngine.runtimeBufferFrameSize(for: output(channelCount: 2, bufferFrameSize: 256)) == 256)
        #expect(SystemTapAudioEngine.runtimeBufferFrameSize(for: output(channelCount: 2, bufferFrameSize: 16_384)) == 1_024)
    }

    @Test
    func preferredBufferFrameSizeDoesNotShrinkStandardSpeakerRoutes() {
        #expect(SystemTapAudioEngine.preferredBufferFrameSize(for: output(channelCount: 2, bufferFrameSize: 128)) == 256)
        #expect(SystemTapAudioEngine.preferredBufferFrameSize(for: output(channelCount: 2, bufferFrameSize: 512)) == 512)
        #expect(SystemTapAudioEngine.preferredBufferFrameSize(for: output(channelCount: 2, bufferFrameSize: 2_048)) == 1_024)
    }

    @Test
    func bluetoothAndLowSampleRateRoutesKeepRouteSpecificBufferPreferences() {
        #expect(SystemTapAudioEngine.preferredBufferFrameSize(
            for: output(channelCount: 2, bufferFrameSize: 256, transportType: kAudioDeviceTransportTypeBluetooth)
        ) == 512)
        #expect(SystemTapAudioEngine.preferredBufferFrameSize(
            for: output(channelCount: 2, sampleRate: 16_000, bufferFrameSize: 256)
        ) == 1_024)
    }

    @Test
    func standardRoutesPrimeMultipleCallbacksBeforePlayback() {
        #expect(SystemTapAudioEngine.minimumPrimeFrames(
            for: output(channelCount: 2, bufferFrameSize: 256),
            runtimeBufferFrameSize: 256
        ) == 1_024)
        #expect(SystemTapAudioEngine.minimumPrimeFrames(
            for: output(channelCount: 2, bufferFrameSize: 512),
            runtimeBufferFrameSize: 512
        ) == 1_024)
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
