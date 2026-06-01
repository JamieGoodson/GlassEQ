import Foundation
import GlassEQCore
import GlassEQSettingsIPC
import Testing
@testable import GlassEQSettings

@Suite
struct SettingsIPCTests {
    @Test
    func commandRoundTripsThroughSecureEnvelope() throws {
        let profile = EQProfile.flatParametric
        let envelope = try SettingsXPCEnvelope.encode(SettingsCommand.applyProfile(profile))

        let decoded = try envelope.decode(SettingsCommand.self)

        #expect(decoded == .applyProfile(profile))
    }

    @Test
    func snapshotRoundTripsThroughSecureEnvelope() throws {
        let snapshot = SettingsSnapshotDTO.disconnected
        let envelope = try SettingsXPCEnvelope.encode(SettingsEvent.snapshotChanged(snapshot))

        let decoded = try envelope.decode(SettingsEvent.self)

        #expect(decoded == .snapshotChanged(snapshot))
    }

    @Test
    func pipeMessageRoundTripsConnectRequest() throws {
        let message = SettingsPipeMessage.request(sessionToken: "token", id: "request-1", kind: .connect, command: nil)

        let encoded = try SettingsPipeCodec.encodeLine(message)
        let decoded = try SettingsPipeCodec.decodeLine(Data(encoded.dropLast()))

        #expect(decoded == message)
        try decoded.validateSessionToken("token")
    }

    @Test
    func pipeMessageRoundTripsCommandResponseAndEvent() throws {
        let response = SettingsPipeMessage.response(
            sessionToken: "token",
            id: "request-2",
            response: SettingsCommandResponse(snapshot: .disconnected),
            error: nil
        )
        let event = SettingsPipeMessage.event(
            sessionToken: "token",
            event: .metricsChanged(SettingsAudioMetricsDTO(capturedFrames: 42))
        )

        let decodedResponse = try SettingsPipeCodec.decodeLine(Data(try SettingsPipeCodec.encodeLine(response).dropLast()))
        let decodedEvent = try SettingsPipeCodec.decodeLine(Data(try SettingsPipeCodec.encodeLine(event).dropLast()))

        #expect(decodedResponse == response)
        #expect(decodedEvent == event)
    }

    @Test
    func pipeMessageRejectsMismatchedSessionToken() throws {
        let message = SettingsPipeMessage.event(sessionToken: "actual", event: .shutdown)

        #expect(throws: SettingsPipeError.sessionTokenMismatch) {
            try message.validateSessionToken("expected")
        }
    }

    @Test
    func pipeCodecRejectsOversizedEncodedLine() throws {
        let message = SettingsPipeMessage.event(sessionToken: "token", event: .shutdown)

        #expect(throws: SettingsPipeError.self) {
            _ = try SettingsPipeCodec.encodeLine(message, maximumLineBytes: 1)
        }
    }

    @Test
    func pipeLineBufferDecodesChunkedAndMultipleLines() throws {
        let first = SettingsPipeMessage.event(sessionToken: "token", event: .focusRequested)
        let second = SettingsPipeMessage.event(sessionToken: "token", event: .shutdown)
        let firstLine = try SettingsPipeCodec.encodeLine(first)
        let secondLine = try SettingsPipeCodec.encodeLine(second)
        let splitIndex = firstLine.index(firstLine.startIndex, offsetBy: firstLine.count / 2)
        var buffer = SettingsPipeLineBuffer()

        let noLines = try buffer.append(firstLine[..<splitIndex])
        let completedLines = try buffer.append(firstLine[splitIndex...] + secondLine)

        #expect(noLines.isEmpty)
        #expect(completedLines.count == 2)
        #expect(try completedLines.map(SettingsPipeCodec.decodeLine) == [first, second])
        #expect(buffer.bufferedByteCount == 0)
    }

    @Test
    func pipeLineBufferRejectsOversizedUnterminatedFrame() throws {
        var buffer = SettingsPipeLineBuffer(maximumLineBytes: 4)

        #expect(throws: SettingsPipeError.frameTooLarge(byteCount: 5, maximum: 4)) {
            _ = try buffer.append(Data(repeating: 0x61, count: 5))
        }
    }

    @Test
    func snapshotPatchRoundTripsOptionalMapping() throws {
        let profileID = UUID()
        let patch = SettingsSnapshotPatchDTO(
            statusMessage: "Running",
            activeProfileID: profileID,
            activeProfileName: "Flat",
            currentOutput: SettingsOutputDTO(
                name: "DAC",
                uid: "dac",
                sampleRate: 48_000,
                channelCount: 2,
                bufferFrameSize: 256
            ),
            currentOutputMappedProfileID: .set(profileID)
        )
        let message = SettingsPipeMessage.event(sessionToken: "token", event: .snapshotPatched(patch))

        let decoded = try SettingsPipeCodec.decodeLine(Data(try SettingsPipeCodec.encodeLine(message).dropLast()))

        #expect(decoded == message)
    }

    @Test
    func settingsHostValidationChecksProcessParentAndBundleID() throws {
        let launchInfo = try #require(SettingsLaunchInfo(commandLineArguments: [
            "GlassEQSettings",
            "--glasseq-settings-token", "token",
            "--glasseq-main-pid", "123"
        ]))

        try SettingsHostValidator.validate(
            launchInfo: launchInfo,
            resolver: FakeHostProcessResolver(snapshot: SettingsHostProcessSnapshot(
                exists: true,
                bundleIdentifier: "com.glasseq.app",
                parentProcessIdentifier: 123
            ))
        )
        #expect(throws: SettingsCommandFailure.self) {
            try SettingsHostValidator.validate(
                launchInfo: launchInfo,
                resolver: FakeHostProcessResolver(snapshot: SettingsHostProcessSnapshot(
                    exists: false,
                    bundleIdentifier: nil,
                    parentProcessIdentifier: nil
                ))
            )
        }
        #expect(throws: SettingsCommandFailure.self) {
            try SettingsHostValidator.validate(
                launchInfo: launchInfo,
                resolver: FakeHostProcessResolver(snapshot: SettingsHostProcessSnapshot(
                    exists: true,
                    bundleIdentifier: "com.glasseq.app",
                    parentProcessIdentifier: 456
                ))
            )
        }
        #expect(throws: SettingsCommandFailure.self) {
            try SettingsHostValidator.validate(
                launchInfo: launchInfo,
                resolver: FakeHostProcessResolver(snapshot: SettingsHostProcessSnapshot(
                    exists: true,
                    bundleIdentifier: "com.example.other",
                    parentProcessIdentifier: 123
                ))
            )
        }
    }
}

private struct FakeHostProcessResolver: SettingsHostProcessResolving {
    var snapshot: SettingsHostProcessSnapshot

    func snapshot(for processIdentifier: pid_t) -> SettingsHostProcessSnapshot {
        snapshot
    }
}
