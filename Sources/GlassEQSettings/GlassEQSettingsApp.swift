import AppKit
import Darwin
import Foundation
import GlassEQSettingsIPC
import GlassEQSettingsUI
import SwiftUI

@main
struct GlassEQSettingsApp: App {
    @NSApplicationDelegateAdaptor(SettingsAppDelegate.self) private var appDelegate
    @State private var model = GlassEQSettingsViewModel()

    var body: some Scene {
        WindowGroup(String(localized: "Configure GlassEQ")) {
            SettingsView(model: model)
                .frame(minWidth: 760, minHeight: 500)
                .onAppear {
                    appDelegate.attach(model: model)
                }
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: GlassEQSettingsViewModel?
    private var client: SettingsPipeClient?
    private var pendingLaunchInfo: SettingsLaunchInfo?
    private var connectedToken: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        pendingLaunchInfo = SettingsLaunchInfo(commandLineArguments: CommandLine.arguments)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        client?.disconnect()
    }

    func attach(model: GlassEQSettingsViewModel) {
        self.model = model
        if let pendingLaunchInfo {
            self.pendingLaunchInfo = nil
            Task { @MainActor in
                await connect(launchInfo: pendingLaunchInfo, model: model)
            }
            return
        }
        model.commandErrorMessage = "Settings was not launched by GlassEQ."
    }

    private func connect(launchInfo: SettingsLaunchInfo, model: GlassEQSettingsViewModel) async {
        do {
            guard launchInfo.token != connectedToken else {
                return
            }
            let client = try SettingsPipeClient(launchInfo: launchInfo, model: model)
            let snapshot = try await client.connect()
            self.client = client
            connectedToken = client.token
            model.attach(client: client, snapshot: snapshot)
        } catch {
            model.commandErrorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class SettingsPipeClient: NSObject, SettingsCommanding, @unchecked Sendable {
    let token: String
    private let mainProcessIdentifier: pid_t
    private weak var model: GlassEQSettingsViewModel?
    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput
    private var mainTerminationObserver: NSObjectProtocol?
    private var continuations: [String: CheckedContinuation<SettingsCommandResponse, any Error>] = [:]
    private let pipeDecoder = SettingsPipeLineDecoder()
    private var disconnected = false

    fileprivate init(launchInfo: SettingsLaunchInfo, model: GlassEQSettingsViewModel) throws {
        self.token = launchInfo.token
        self.mainProcessIdentifier = launchInfo.mainProcessIdentifier
        self.model = model
        super.init()
        try SettingsHostValidator.validate(launchInfo: launchInfo)
        installObservers()
    }

    func connect() async throws -> SettingsSnapshotDTO {
        let response = try await send(kind: .connect)
        guard let snapshot = response.snapshot else {
            throw SettingsCommandFailure(message: "GlassEQ returned an empty settings snapshot.")
        }
        return snapshot
    }

    func perform(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        try await send(kind: .command, command: command)
    }

    func disconnect() {
        guard !disconnected else {
            return
        }
        disconnected = true
        try? writePipeMessage(.request(sessionToken: token, id: UUID().uuidString, kind: .disconnect, command: nil))
        let error = SettingsCommandFailure(message: "Settings disconnected from GlassEQ.")
        continuations.values.forEach { $0.resume(throwing: error) }
        continuations.removeAll()
        input.readabilityHandler = nil
        mainTerminationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        mainTerminationObserver = nil
    }

    private func installObservers() {
        let decoder = pipeDecoder
        input.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                Task { @MainActor in
                    NSApplication.shared.terminate(nil)
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
                        self?.failPending(error)
                        self?.model?.commandErrorMessage = error.localizedDescription
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        mainTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard let self,
                      application?.processIdentifier == self.mainProcessIdentifier else {
                    return
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func send(kind: SettingsPipeRequestKind, command: SettingsCommand? = nil) async throws -> SettingsCommandResponse {
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            continuations[requestID] = continuation
            do {
                try writePipeMessage(.request(sessionToken: token, id: requestID, kind: kind, command: command))
            } catch {
                continuations.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func handlePipeMessages(_ messages: [SettingsPipeMessage]) {
        do {
            for message in messages {
                try handlePipeMessage(message)
            }
        } catch {
            failPending(error)
            model?.commandErrorMessage = error.localizedDescription
            NSApplication.shared.terminate(nil)
        }
    }

    private func handlePipeMessage(_ message: SettingsPipeMessage) throws {
        try message.validateSessionToken(token)

        switch message {
        case let .response(_, id, response, error):
            guard let continuation = continuations.removeValue(forKey: id) else {
                return
            }
            if let error {
                continuation.resume(throwing: SettingsCommandFailure(message: error))
                return
            }
            guard let response else {
                continuation.resume(throwing: SettingsCommandFailure(message: "GlassEQ returned an empty settings response."))
                return
            }
            continuation.resume(returning: response)
        case let .event(_, event):
            handleEvent(event)
        case .request:
            break
        }
    }

    private func handleEvent(_ event: SettingsEvent) {
        guard let model else {
            return
        }

        switch event {
        case .snapshotChanged(let snapshot):
            model.accept(snapshot: snapshot)
        case .snapshotPatched(let patch):
            model.accept(patch: patch)
        case .metricsChanged(let metrics):
            model.accept(metrics: metrics)
        case .commandFailed(let failure):
            model.commandErrorMessage = failure.message
        case .focusRequested:
            SettingsWindowFocus.request()
        case .shutdown:
            NSApplication.shared.terminate(nil)
        }
    }

    private func writePipeMessage(_ message: SettingsPipeMessage) throws {
        try output.write(contentsOf: SettingsPipeCodec.encodeLine(message))
    }

    private func failPending(_ error: any Error) {
        continuations.values.forEach { $0.resume(throwing: error) }
        continuations.removeAll()
    }
}

struct SettingsLaunchInfo {
    var token: String
    var mainProcessIdentifier: pid_t

    init?(commandLineArguments arguments: [String]) {
        guard let tokenIndex = arguments.firstIndex(of: "--glasseq-settings-token"),
              let pidIndex = arguments.firstIndex(of: "--glasseq-main-pid"),
              arguments.indices.contains(tokenIndex + 1),
              arguments.indices.contains(pidIndex + 1),
              let mainPID = Int32(arguments[pidIndex + 1]) else {
            return nil
        }
        self.token = arguments[tokenIndex + 1]
        self.mainProcessIdentifier = mainPID
    }
}

struct SettingsHostProcessSnapshot: Equatable, Sendable {
    var exists: Bool
    var bundleIdentifier: String?
    var parentProcessIdentifier: pid_t?
}

protocol SettingsHostProcessResolving {
    func snapshot(for processIdentifier: pid_t) -> SettingsHostProcessSnapshot
}

enum SettingsHostValidator {
    static let hostBundleIdentifier = "com.glasseq.app"

    static func validate(
        launchInfo: SettingsLaunchInfo,
        resolver: any SettingsHostProcessResolving = RunningApplicationHostProcessResolver()
    ) throws {
        let snapshot = resolver.snapshot(for: launchInfo.mainProcessIdentifier)
        guard snapshot.exists else {
            throw SettingsCommandFailure(message: "GlassEQ is no longer running.")
        }
        if let parentProcessIdentifier = snapshot.parentProcessIdentifier,
           parentProcessIdentifier > 1,
           parentProcessIdentifier != launchInfo.mainProcessIdentifier {
            throw SettingsCommandFailure(message: "Settings was not launched by the current GlassEQ process.")
        }
        if let bundleIdentifier = snapshot.bundleIdentifier,
           !bundleIdentifier.isEmpty,
           bundleIdentifier != hostBundleIdentifier {
            throw SettingsCommandFailure(message: "Settings was launched by an unexpected host application.")
        }
    }
}

struct RunningApplicationHostProcessResolver: SettingsHostProcessResolving {
    func snapshot(for processIdentifier: pid_t) -> SettingsHostProcessSnapshot {
        let application = NSRunningApplication(processIdentifier: processIdentifier)
        let processExists = application != nil || Darwin.kill(processIdentifier, 0) == 0
        return SettingsHostProcessSnapshot(
            exists: processExists,
            bundleIdentifier: application?.bundleIdentifier,
            parentProcessIdentifier: Darwin.getppid()
        )
    }
}
