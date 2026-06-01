import CoreAudio
import Darwin
import GlassEQAudio
import Testing

@Suite
struct CoreAudioErrorTests {
    @Test
    func formatsOSStatusAsDecimalAndFourCC() {
        let unsupportedDataStatus = fourCC("!dat")

        #expect(formatOSStatusDecimal(OSStatus(-50)) == "-50")
        #expect(formatOSStatusFourCC(unsupportedDataStatus) == "!dat")
        #expect(formatOSStatus(unsupportedDataStatus) == "\(unsupportedDataStatus) ('!dat')")
        #expect(formatOSStatusFourCC(OSStatus(EPERM)) == nil)
    }

    @Test
    func classifiesProcessTapPermissionFailure() {
        let failure = classifyCoreAudioError(
            operation: "AudioHardwareCreateProcessTap",
            status: kAudioHardwareIllegalOperationError
        )

        #expect(failure.category == .systemAudioCapturePermission)
        #expect(failure.operation == "AudioHardwareCreateProcessTap")
        #expect(failure.status == kAudioHardwareIllegalOperationError)
        #expect(failure.statusFourCC == "nope")
    }

    @Test
    func classifiesCaptureStartPermissionFailure() {
        let failure = classifyCoreAudioError(
            operation: "AudioDeviceStart(capture tap)",
            status: OSStatus(EPERM)
        )

        #expect(failure.category == .systemAudioCapturePermission)
        #expect(failure.statusFourCC == nil)
    }

    @Test
    func classifiesDeviceFormatAndOutputFailures() {
        let formatFailure = classifyCoreAudioError(
            operation: "AudioDeviceCreateIOProcIDWithBlock(output)",
            status: kAudioDeviceUnsupportedFormatError
        )
        let outputFailure = classifyCoreAudioError(
            operation: "AudioDeviceStart(default output)",
            status: kAudioHardwareBadDeviceError
        )

        #expect(formatFailure.category == .deviceFormatUnsupported)
        #expect(formatFailure.statusFourCC == "!dat")
        #expect(outputFailure.category == .outputDeviceUnavailable)
        #expect(outputFailure.statusFourCC == "!dev")
    }
}

private func fourCC(_ value: String) -> OSStatus {
    var status = UInt32(0)
    for byte in value.utf8 {
        status = (status << 8) | UInt32(byte)
    }
    return OSStatus(bitPattern: status)
}
