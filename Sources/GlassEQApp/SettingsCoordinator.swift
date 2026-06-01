import AppKit
import Darwin
import Foundation
import GlassEQCore
import GlassEQSettingsIPC
import Security

private struct UncheckedSendable<Value>: @unchecked Sendable {
    var value: Value
}

@MainActor
final class SettingsCoordinator: NSObject {
    private weak var model: GlassEQAppModel?
    private var launchToken: String?
    private var runningApplication: NSRunningApplication?
    private var helperProcess: Process?
    private var pipeWriter: FileHandle?
    private var pipeReader: FileHandle?
    private var pipeErrorReader: FileHandle?
    private var pipeDecoder = SettingsPipeLineDecoder()
    private var settingsConnected = false
    private var pendingFocusRequest = false
    private var suppressModelChangeEvents = false
    private var lastSentSnapshot: SettingsSnapshot?

    init(model: GlassEQAppModel) {
        self.model = model
        super.init()
    }

    func openSettings() {
        if let helperProcess, helperProcess.isRunning {
            if settingsConnected {
                send(.focusRequested)
            } else {
                pendingFocusRequest = true
            }
            focusSettings()
            return
        }

        do {
            let token = prepareSession()
            pendingFocusRequest = true
            try launchHelper(token: token)
        } catch {
            model?.statusMessage = localized("Settings failed to open: \(error.localizedDescription)")
            model?.notifyModelDidChangeFromCoordinator()
            cleanupSession(terminateHelper: false)
        }
    }

    func shutdown() {
        send(.shutdown)
        cleanupSession(terminateHelper: true)
    }

    func modelDidChange() {
        guard !suppressModelChangeEvents,
              let model else {
            return
        }
        sendSnapshotUpdate(model.settingsSnapshot())
    }

    func metricsDidChange() {
        guard let model else {
            return
        }
        let metrics = SettingsAudioMetricsDTO(model.engineMetrics)
        guard lastSentSnapshot?.metrics != metrics else {
            return
        }
        if var snapshot = lastSentSnapshot {
            snapshot.metrics = metrics
            lastSentSnapshot = snapshot
        }
        send(.metricsChanged(metrics))
    }

    private func prepareSession() -> String {
        let token = UUID().uuidString
        launchToken = token
        settingsConnected = false
        pendingFocusRequest = false
        suppressModelChangeEvents = false
        lastSentSnapshot = nil
        pipeDecoder = SettingsPipeLineDecoder()
        return token
    }

    private func launchHelper(token: String) throws {
        let helperURL = try settingsHelperURL()
        let executableURL = try SettingsHelperVerifier.validatedExecutableURL(for: helperURL)

        let process = Process()
        let helperInput = Pipe()
        let helperOutput = Pipe()
        let helperError = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "--glasseq-settings-token", token,
            "--glasseq-main-pid", String(ProcessInfo.processInfo.processIdentifier)
        ]
        process.standardInput = helperInput.fileHandleForReading
        process.standardOutput = helperOutput.fileHandleForWriting
        process.standardError = helperError.fileHandleForWriting
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.cleanupSession(terminateHelper: false)
            }
        }
        try process.run()
        helperProcess = process
        pipeWriter = helperInput.fileHandleForWriting
        pipeReader = helperOutput.fileHandleForReading
        pipeErrorReader = helperError.fileHandleForReading
        installPipeReader(helperOutput.fileHandleForReading)
        pipeErrorReader?.readabilityHandler = { handle in
            _ = handle.availableData
        }
        runningApplication = NSRunningApplication(processIdentifier: process.processIdentifier)
        focusSettings()
    }

    private func settingsHelperURL() throws -> URL {
        let bundleURL = Bundle.main.bundleURL
        let helperURL: URL
        if bundleURL.pathExtension == "app" {
            helperURL = bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        } else {
            helperURL = bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        }
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw SettingsCommandFailure(message: "GlassEQSettings.app was not found in the app bundle.")
        }
        return helperURL
    }

    private func perform(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        guard let model else {
            throw SettingsCommandFailure(message: "GlassEQ is shutting down.")
        }
        return try await model.performSettingsCommand(command)
    }

    private func focusSettings() {
        runningApplication?.activate(options: [.activateAllWindows])
    }

    private func send(_ event: SettingsEvent) {
        guard settingsConnected else {
            return
        }
        guard let launchToken else {
            return
        }
        do {
            try writePipeMessage(.event(sessionToken: launchToken, event: event))
        } catch {
            failPipeSession(error)
        }
    }

    private func installPipeReader(_ readHandle: FileHandle) {
        let decoder = pipeDecoder
        readHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                Task { @MainActor in
                    self?.cleanupSession(terminateHelper: false)
                }
                return
            }
            Task {
                do {
                    let messages = try await decoder.append(data)
                    await MainActor.run {
                        self?.handlePipeMessages(messages)
                    }
                } catch {
                    await MainActor.run {
                        self?.failPipeSession(error)
                    }
                }
            }
        }
    }

    private func handlePipeMessages(_ messages: [SettingsPipeMessage]) {
        do {
            for message in messages {
                try handlePipeMessage(message)
            }
        } catch {
            failPipeSession(error)
        }
    }

    private func handlePipeMessage(_ message: SettingsPipeMessage) throws {
        guard let launchToken else {
            throw SettingsPipeError.sessionTokenMismatch
        }
        try message.validateSessionToken(launchToken)

        switch message {
        case let .request(_, id, .connect, _):
            handleConnect(requestID: id)
        case let .request(_, id, .command, command):
            guard let command else {
                sendError("Settings IPC command payload was missing.", requestID: id)
                return
            }
            handleCommand(command, requestID: id)
        case .request(_, _, .disconnect, _):
            cleanupSession(terminateHelper: false)
        case .response, .event:
            break
        }
    }

    private func handleConnect(requestID: String) {
        guard let model else {
            sendError("GlassEQ is shutting down.", requestID: requestID)
            return
        }
        settingsConnected = true
        let snapshot = model.settingsSnapshot()
        lastSentSnapshot = snapshot
        sendResponse(SettingsCommandResponse(snapshot: snapshot), requestID: requestID)
        if pendingFocusRequest {
            pendingFocusRequest = false
            send(.focusRequested)
        }
    }

    private func handleCommand(_ command: SettingsCommand, requestID: String) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                suppressModelChangeEvents = true
                let response = try await perform(command)
                suppressModelChangeEvents = false
                if let snapshot = response.snapshot {
                    lastSentSnapshot = snapshot
                }
                sendResponse(response, requestID: requestID)
            } catch {
                suppressModelChangeEvents = false
                sendError(error.localizedDescription, requestID: requestID)
            }
        }
    }

    private func sendSnapshotUpdate(_ snapshot: SettingsSnapshot) {
        guard settingsConnected else {
            return
        }

        guard let previous = lastSentSnapshot else {
            lastSentSnapshot = snapshot
            send(.snapshotChanged(snapshot))
            return
        }

        if previous.profiles != snapshot.profiles {
            lastSentSnapshot = snapshot
            send(.snapshotChanged(snapshot))
            return
        }

        var patch = SettingsSnapshotPatchDTO()
        var didPatch = false

        if previous.statusMessage != snapshot.statusMessage {
            patch.statusMessage = snapshot.statusMessage
            didPatch = true
        }
        if previous.isPreviewing != snapshot.isPreviewing {
            patch.isPreviewing = snapshot.isPreviewing
            didPatch = true
        }
        if previous.selectedProfileID != snapshot.selectedProfileID {
            patch.selectedProfileID = snapshot.selectedProfileID
            didPatch = true
        }
        if previous.draftProfile != snapshot.draftProfile {
            patch.draftProfile = snapshot.draftProfile
            didPatch = true
        }
        if previous.activeProfileID != snapshot.activeProfileID {
            patch.activeProfileID = snapshot.activeProfileID
            didPatch = true
        }
        if previous.activeProfileName != snapshot.activeProfileName {
            patch.activeProfileName = snapshot.activeProfileName
            didPatch = true
        }
        if previous.fallbackProfileID != snapshot.fallbackProfileID {
            patch.fallbackProfileID = snapshot.fallbackProfileID
            didPatch = true
        }
        if previous.currentOutputName != snapshot.currentOutputName ||
            previous.currentOutputUID != snapshot.currentOutputUID ||
            previous.currentOutputSampleRate != snapshot.currentOutputSampleRate ||
            previous.currentOutputChannelCount != snapshot.currentOutputChannelCount ||
            previous.currentOutputBufferFrameSize != snapshot.currentOutputBufferFrameSize {
            patch.currentOutput = SettingsOutputDTO(
                name: snapshot.currentOutputName,
                uid: snapshot.currentOutputUID,
                sampleRate: snapshot.currentOutputSampleRate,
                channelCount: snapshot.currentOutputChannelCount,
                bufferFrameSize: snapshot.currentOutputBufferFrameSize
            )
            didPatch = true
        }
        if previous.currentOutputMappedProfileID != snapshot.currentOutputMappedProfileID {
            if let profileID = snapshot.currentOutputMappedProfileID {
                patch.currentOutputMappedProfileID = .set(profileID)
            } else {
                patch.currentOutputMappedProfileID = .clear
            }
            didPatch = true
        }

        guard didPatch else {
            lastSentSnapshot = snapshot
            return
        }

        lastSentSnapshot = snapshot
        send(.snapshotPatched(patch))
    }

    private func sendResponse(_ response: SettingsCommandResponse, requestID: String) {
        guard let launchToken else {
            return
        }
        do {
            try writePipeMessage(.response(sessionToken: launchToken, id: requestID, response: response, error: nil))
        } catch {
            failPipeSession(error)
        }
    }

    private func sendError(_ message: String, requestID: String) {
        guard let launchToken else {
            return
        }
        do {
            try writePipeMessage(.response(sessionToken: launchToken, id: requestID, response: nil, error: message))
        } catch {
            failPipeSession(error)
        }
    }

    private func writePipeMessage(_ message: SettingsPipeMessage) throws {
        guard let pipeWriter else {
            throw SettingsCommandFailure(message: localized("Settings IPC pipe is not connected."))
        }
        do {
            try pipeWriter.write(contentsOf: SettingsPipeCodec.encodeLine(message))
        } catch {
            throw SettingsCommandFailure(message: localized("Settings IPC write failed: \(error.localizedDescription)"))
        }
    }

    private func failPipeSession(_ error: Error) {
        statusMessageForIPCFailure(error)
        cleanupSession(terminateHelper: true)
    }

    private func statusMessageForIPCFailure(_ error: Error) {
        model?.statusMessage = localized("Settings IPC failed: \(error.localizedDescription)")
        model?.notifyModelDidChangeFromCoordinator()
    }

    private func cleanupSession(terminateHelper: Bool) {
        model?.stopMetricsPolling()
        let processToTerminate = terminateHelper ? helperProcess : nil
        pipeReader?.readabilityHandler = nil
        pipeErrorReader?.readabilityHandler = nil
        try? pipeReader?.close()
        try? pipeErrorReader?.close()
        try? pipeWriter?.close()
        pipeReader = nil
        pipeErrorReader = nil
        pipeWriter = nil
        launchToken = nil
        pendingFocusRequest = false
        suppressModelChangeEvents = false
        lastSentSnapshot = nil
        runningApplication = nil
        helperProcess = nil
        settingsConnected = false
        if let processToTerminate {
            SettingsHelperTerminator.terminate(process: processToTerminate)
        }
    }
}

private enum SettingsHelperTerminator {
    static func terminate(process: Process) {
        let terminator = ProcessTerminator(process: process)
        Task.detached(priority: .utility) {
            await terminator.run()
        }
    }

    private final class ProcessTerminator: @unchecked Sendable {
        private let process: Process

        init(process: Process) {
            self.process = process
        }

        func run() async {
            if await waitForExit(seconds: 1.0) {
                return
            }
            process.terminate()
            if await waitForExit(seconds: 0.5) {
                return
            }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }

        private func waitForExit(seconds: Double) async -> Bool {
            let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1_000))
            while ContinuousClock.now < deadline {
                if !process.isRunning {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return !process.isRunning
        }
    }
}

struct SettingsCodeSignatureInfo: Equatable, Sendable {
    var signingIdentifier: String?
    var teamIdentifier: String?
}

protocol SettingsCodeSigningValidating {
    func signatureInfo(for url: URL) throws -> SettingsCodeSignatureInfo
}

enum SettingsHelperVerifier {
    static let hostBundleIdentifier = "com.glasseq.app"
    static let helperBundleIdentifier = "com.glasseq.app.settings"

    static func validatedExecutableURL(
        for helperURL: URL,
        hostBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default,
        codeSigningValidator: any SettingsCodeSigningValidating = SecuritySettingsCodeSigningValidator()
    ) throws -> URL {
        let standardizedHelperURL = helperURL.standardizedFileURL
        let standardizedHostURL = hostBundleURL.standardizedFileURL

        guard fileManager.fileExists(atPath: standardizedHelperURL.path) else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app was not found in the app bundle."))
        }
        if standardizedHostURL.pathExtension == "app" {
            let helpersURL = standardizedHostURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .standardizedFileURL
            guard standardizedHelperURL.path.hasPrefix(helpersURL.path + "/") else {
                throw SettingsCommandFailure(message: localized("GlassEQSettings.app is not contained in the GlassEQ app bundle."))
            }
        }

        guard let helperBundle = Bundle(url: standardizedHelperURL),
              helperBundle.bundleIdentifier == helperBundleIdentifier else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app has an unexpected bundle identifier."))
        }

        let executableName = helperBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "GlassEQSettings"
        let executableURL = standardizedHelperURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
            .standardizedFileURL
        guard executableURL.path.hasPrefix(standardizedHelperURL.path + "/"),
              fileManager.fileExists(atPath: executableURL.path) else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings executable was not found in the app bundle."))
        }

        let helperSignature = try codeSigningValidator.signatureInfo(for: standardizedHelperURL)
        if let signingIdentifier = helperSignature.signingIdentifier,
           signingIdentifier != helperBundleIdentifier {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app has an unexpected code-signing identifier."))
        }

        let hostSignature: SettingsCodeSignatureInfo?
        if standardizedHostURL.pathExtension == "app" {
            hostSignature = try codeSigningValidator.signatureInfo(for: standardizedHostURL)
        } else {
            hostSignature = try? codeSigningValidator.signatureInfo(for: standardizedHostURL)
        }

        guard let hostTeamIdentifier = hostSignature?.teamIdentifier,
              !hostTeamIdentifier.isEmpty else {
            return executableURL
        }
        guard helperSignature.teamIdentifier == hostTeamIdentifier else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app was not signed by the same team as GlassEQ."))
        }

        return executableURL
    }
}

struct SecuritySettingsCodeSigningValidator: SettingsCodeSigningValidating {
    func signatureInfo(for url: URL) throws -> SettingsCodeSignatureInfo {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw SettingsCommandFailure(message: localized("Code signing validation failed for \(url.lastPathComponent): \(status)"))
        }

        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        status = SecStaticCodeCheckValidity(staticCode, validationFlags, nil)
        guard status == errSecSuccess else {
            throw SettingsCommandFailure(message: localized("Code signing validation failed for \(url.lastPathComponent): \(status)"))
        }

        var info: CFDictionary?
        status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard status == errSecSuccess,
              let dictionary = info as? [String: Any] else {
            throw SettingsCommandFailure(message: localized("Code signing information was unavailable for \(url.lastPathComponent)."))
        }

        return SettingsCodeSignatureInfo(
            signingIdentifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }
}

extension GlassEQAppModel {
    func openSettings() {
        settingsCoordinator.openSettings()
    }

    func notifyModelDidChangeFromCoordinator() {
        notifyModelDidChange()
    }

    func performSettingsCommand(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        switch command {
        case .createProfile(let kind):
            try createProfile(kind: kind)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .duplicateProfile(let id):
            try duplicateProfile(id: id)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .deleteProfile(let id):
            try deleteProfile(id: id)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .applyProfile(let profile):
            try validateIncomingProfile(profile)
            try apply(profile: profile)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .useProfileForCurrentOutput(let profile):
            try validateIncomingProfile(profile)
            try useForCurrentOutput(profile: profile)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .setFallback(let profile):
            try validateIncomingProfile(profile)
            try setFallback(profile: profile)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case let .importProfile(format, name, text):
            let imported = try await importProfile(format: format, name: name, text: text)
            return SettingsCommandResponse(snapshot: settingsSnapshot(), importSucceeded: imported)

        case .preview(let profile):
            try validateIncomingProfile(profile)
            preview(profile: profile)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .stopPreview:
            stopPreview()
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .resetDiagnostics:
            resetDiagnostics()
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .retryAudioEngine:
            retryAudioEngine()
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .openPrivacySettings:
            try openPrivacySettings()
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .startMetricsPolling:
            startMetricsPolling()
            return SettingsCommandResponse()

        case .stopMetricsPolling:
            stopMetricsPolling()
            return SettingsCommandResponse()
        }
    }

    private func validateIncomingProfile(_ profile: EQProfile) throws {
        var store = profileStore
        if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
            store.profiles[index] = profile
        } else {
            store.profiles.append(profile)
        }
        try ProfilePersistence.validate(store)
    }
}
