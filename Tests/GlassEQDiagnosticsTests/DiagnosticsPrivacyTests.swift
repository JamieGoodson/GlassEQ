import GlassEQDiagnosticsSupport
import Testing

@Suite
struct DiagnosticsPrivacyTests {
    @Test
    func redactsDeviceIdentifiersByDefaultAndKeepsVerboseDetails() {
        #expect(diagnosticsDeviceName("Studio DAC", verbose: false) == "<redacted>")
        #expect(diagnosticsDeviceName("Studio DAC", verbose: true) == "Studio DAC")
        #expect(diagnosticsIdentifier("ABCDEF123456", verbose: false) == "ABCD...3456")
        #expect(diagnosticsIdentifier("ABCDEF123456", verbose: true) == "ABCDEF123456")
    }
}
