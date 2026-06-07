import Foundation
import GlassEQCore
import GlassEQSettingsIPC
import Testing
@testable import GlassEQSettings
@testable import GlassEQSettingsUI

@Suite
struct SettingsIPCTests {
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
    func audioMetricsDecodeOldPayloadsWithDefaultedNewFields() throws {
        let data = Data("""
        {
          "capturedFrames": 42,
          "playedFrames": 24,
          "playbackUnderrunFrames": 1,
          "saturatedSamples": 2,
          "currentBufferedFrames": 512,
          "maxBufferedFrames": 1024
        }
        """.utf8)

        let metrics = try JSONDecoder().decode(SettingsAudioMetricsDTO.self, from: data)

        #expect(metrics.capturedFrames == 42)
        #expect(metrics.playedFrames == 24)
        #expect(metrics.playbackUnderrunFrames == 1)
        #expect(metrics.saturatedSamples == 2)
        #expect(metrics.currentBufferedFrames == 512)
        #expect(metrics.maxBufferedFrames == 1024)
        #expect(metrics.maximumPlaybackBufferedFrames == 0)
        #expect(metrics.minimumPlaybackBufferedFrames == 0)
        #expect(metrics.averagePlaybackBufferedFrames == 0)
        #expect(metrics.playbackBufferObservations == 0)
        #expect(metrics.maximumCaptureCallbackFrames == 0)
        #expect(metrics.maximumPlaybackCallbackFrames == 0)
    }

    @Test
    func settingsAnalysisUsesCurrentOutputSampleRateWithFallback() {
        let profile = EQProfile(
            name: "Analysis",
            mode: .parametric,
            filters: [
                EQFilter(kind: .peak, frequency: 20_000, gainDB: 8, q: 8)
            ]
        )

        let routeAnalysis = EQAnalysisSnapshot(profile: profile, sampleRate: 44_100)
        let fallbackAnalysis = EQAnalysisSnapshot(profile: profile, sampleRate: 0)

        #expect(routeAnalysis.signature.sampleRate == 44_100)
        #expect(fallbackAnalysis.signature.sampleRate == EQAnalysisSignature.defaultSampleRate)
        #expect(routeAnalysis.signature != fallbackAnalysis.signature)
        #expect(routeAnalysis.linkedPoints == FrequencyResponse.points(
            for: profile.filters,
            preampDB: profile.preampDB,
            sampleRate: 44_100
        ))
        #expect(routeAnalysis.recommendedPreampDB == EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: 44_100
        ))
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

    @Test
    @MainActor
    func settingsLaunchConnectsWhenModelAttachesBeforeArgumentsAreParsed() async {
        let factory = FakeSettingsPipeClientFactory()
        let coordinator = SettingsLaunchCoordinator(clientFactory: factory)
        let model = GlassEQSettingsViewModel()

        coordinator.attach(model: model)
        #expect(model.commandErrorMessage == nil)
        coordinator.finishLaunching(arguments: launchArguments(token: "token-before"))
        await coordinator.waitForConnectionTask()

        #expect(model.isConnected)
        #expect(model.commandErrorMessage == nil)
        #expect(factory.launchInfos.map(\.token) == ["token-before"])
    }

    @Test
    @MainActor
    func settingsLaunchConnectsWhenArgumentsAreParsedBeforeModelAttaches() async {
        let factory = FakeSettingsPipeClientFactory()
        let coordinator = SettingsLaunchCoordinator(clientFactory: factory)
        let model = GlassEQSettingsViewModel()

        coordinator.finishLaunching(arguments: launchArguments(token: "token-after"))
        coordinator.attach(model: model)
        await coordinator.waitForConnectionTask()

        #expect(model.isConnected)
        #expect(model.commandErrorMessage == nil)
        #expect(factory.launchInfos.map(\.token) == ["token-after"])
    }

    @Test
    @MainActor
    func settingsLaunchWithoutGlassEQArgumentsShowsDirectLaunchWarning() {
        let factory = FakeSettingsPipeClientFactory()
        let coordinator = SettingsLaunchCoordinator(clientFactory: factory)
        let model = GlassEQSettingsViewModel()

        coordinator.attach(model: model)
        coordinator.finishLaunching(arguments: ["GlassEQSettings"])

        #expect(!model.isConnected)
        #expect(model.commandErrorMessage == "Settings was not launched by GlassEQ.")
        #expect(factory.launchInfos.isEmpty)
    }

    @Test
    @MainActor
    func settingsLaunchValidationFailureSurfacesConnectionError() async {
        let factory = FakeSettingsPipeClientFactory(
            makeError: SettingsCommandFailure(message: "Settings was launched by an unexpected host application.")
        )
        let coordinator = SettingsLaunchCoordinator(clientFactory: factory)
        let model = GlassEQSettingsViewModel()

        coordinator.finishLaunching(arguments: launchArguments(token: "invalid-host"))
        coordinator.attach(model: model)
        await coordinator.waitForConnectionTask()

        #expect(!model.isConnected)
        #expect(model.commandErrorMessage == "Settings was launched by an unexpected host application.")
    }
}

private struct FakeHostProcessResolver: SettingsHostProcessResolving {
    var snapshot: SettingsHostProcessSnapshot

    func snapshot(for processIdentifier: pid_t) -> SettingsHostProcessSnapshot {
        snapshot
    }
}

@MainActor
private final class FakeSettingsPipeClientFactory: SettingsPipeClientMaking {
    private let makeError: (any Error)?
    private let connectError: (any Error)?
    private let snapshot: SettingsSnapshotDTO
    private(set) var launchInfos: [SettingsLaunchInfo] = []

    init(
        snapshot: SettingsSnapshotDTO = .disconnected,
        makeError: (any Error)? = nil,
        connectError: (any Error)? = nil
    ) {
        self.snapshot = snapshot
        self.makeError = makeError
        self.connectError = connectError
    }

    func makeClient(
        launchInfo: SettingsLaunchInfo,
        model: GlassEQSettingsViewModel
    ) throws -> any SettingsPipeClientConnection {
        if let makeError {
            throw makeError
        }
        launchInfos.append(launchInfo)
        return FakeSettingsPipeClient(
            token: launchInfo.token,
            snapshot: snapshot,
            connectError: connectError
        )
    }
}

@MainActor
private final class FakeSettingsPipeClient: SettingsPipeClientConnection, @unchecked Sendable {
    let token: String
    private let snapshot: SettingsSnapshotDTO
    private let connectError: (any Error)?
    private(set) var didDisconnect = false

    init(token: String, snapshot: SettingsSnapshotDTO, connectError: (any Error)?) {
        self.token = token
        self.snapshot = snapshot
        self.connectError = connectError
    }

    func connect() async throws -> SettingsSnapshotDTO {
        if let connectError {
            throw connectError
        }
        return snapshot
    }

    func perform(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        SettingsCommandResponse()
    }

    func disconnect() {
        didDisconnect = true
    }
}

private func launchArguments(token: String) -> [String] {
    [
        "GlassEQSettings",
        "--glasseq-settings-token", token,
        "--glasseq-main-pid", "123"
    ]
}
