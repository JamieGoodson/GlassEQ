import AppKit
import GlassEQAudio
import GlassEQCore
import GlassEQSettingsIPC
import SwiftUI

@main
struct GlassEQApp: App {
    @NSApplicationDelegateAdaptor(GlassEQAppDelegate.self) private var appDelegate
    @State private var model = GlassEQAppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
                .frame(width: 340)
        } label: {
            Image(systemName: model.isRunning ? "slider.horizontal.3" : "slider.horizontal.2.gobackward")
                .accessibilityLabel(Text(model.isRunning ? localized("GlassEQ active") : localized("GlassEQ stopped")))
                .accessibilityValue(Text(model.statusMessage))
                .accessibilityHint(Text(localized("Opens GlassEQ controls")))
        }
        .menuBarExtraStyle(.window)
    }
}

final class GlassEQAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak static var model: GlassEQAppModel?
    private static let allowImmediateTermination = NSLock()
    nonisolated(unsafe) private static var shouldAllowImmediateTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.allowImmediateTermination.lock()
        let allowImmediateTermination = Self.shouldAllowImmediateTermination
        Self.shouldAllowImmediateTermination = false
        Self.allowImmediateTermination.unlock()
        if allowImmediateTermination {
            return .terminateNow
        }

        Task { @MainActor in
            guard let model = Self.model else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let shouldTerminate = await model.flushStoreBeforeQuit()
            if shouldTerminate {
                model.cleanupForTermination()
            }
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    static func allowNextTerminationImmediately() {
        allowImmediateTermination.lock()
        shouldAllowImmediateTermination = true
        allowImmediateTermination.unlock()
    }
}

typealias ImportFormat = SettingsImportFormat
typealias SettingsSnapshot = SettingsSnapshotDTO

extension SettingsImportFormat {
    var title: String {
        switch self {
        case .autoEQ:
            localized("AutoEQ / EqualizerAPO")
        case .rew:
            localized("REW")
        }
    }
}

private extension Notification.Name {
    static let glassEQModelDidChange = Notification.Name("com.glasseq.modelDidChange")
    static let glassEQMetricsDidChange = Notification.Name("com.glasseq.metricsDidChange")
    static let glassEQBringSettingsToFront = Notification.Name("com.glasseq.bringSettingsToFront")
}

private enum AppBuildInfo {
    static var displayVersion: String {
        let bundle = Bundle.main
        if let releaseLabel = bundle.object(forInfoDictionaryKey: "GlassEQReleaseLabel") as? String,
           !releaseLabel.isEmpty {
            return releaseLabel
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.7.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "9"
        return "v\(version) (\(build))"
    }
}

private enum WakeReconnectPolicy {
    static let maximumAttempts = 12
    static let retryDelay: Duration = .seconds(1)
}

private enum SessionActivationReconnectPolicy {
    static let reconnectDelay: Duration = .milliseconds(650)
}

private enum OutputChangeReconnectPolicy {
    static let routeSwitchDelay: Duration = .milliseconds(50)
    static let fallbackDelay: Duration = .milliseconds(350)
}

private let appResourcesBundle: Bundle = {
    let resourceBundleName = "GlassEQ_GlassEQApp.bundle"
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
        Bundle.main.bundleURL.appendingPathComponent(resourceBundleName),
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(resourceBundleName)
    ].compactMap { $0 }

    for candidate in candidates {
        if let bundle = Bundle(url: candidate) {
            return bundle
        }
    }

    return Bundle.main
}()

func localized(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: appResourcesBundle)
}

private func localizedDecimal(
    _ value: Double,
    minimumFractionDigits: Int,
    maximumFractionDigits: Int,
    signed: Bool = false
) -> String {
    let formatter = NumberFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = minimumFractionDigits
    formatter.maximumFractionDigits = maximumFractionDigits
    if signed {
        formatter.positivePrefix = formatter.plusSign
    }
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

private func localizedInteger(_ value: Int) -> String {
    value.formatted(.number.locale(.autoupdatingCurrent))
}

private func localizedInteger(_ value: UInt32) -> String {
    UInt64(value).formatted(.number.locale(.autoupdatingCurrent))
}

private func localizedInteger(_ value: UInt64) -> String {
    value.formatted(.number.locale(.autoupdatingCurrent))
}

private func localizedDecibels(_ value: Double, fractionDigits: Int = 1) -> String {
    let number = localizedDecimal(
        value,
        minimumFractionDigits: fractionDigits,
        maximumFractionDigits: fractionDigits,
        signed: true
    )
    return localized("\(number) dB")
}

private func localizedFrequency(_ value: Double) -> String {
    if value >= 1_000 {
        let number = localizedDecimal(value / 1_000, minimumFractionDigits: 1, maximumFractionDigits: 1)
        return localized("\(number) kHz")
    }
    let number = localizedDecimal(value, minimumFractionDigits: 0, maximumFractionDigits: 0)
    return localized("\(number) Hz")
}

private func localizedFrameCount(_ value: Int) -> String {
    let number = localizedInteger(value)
    return value == 1 ? localized("\(number) frame") : localized("\(number) frames")
}

private func localizedFrameCount(_ value: UInt32) -> String {
    let number = localizedInteger(value)
    return value == 1 ? localized("\(number) frame") : localized("\(number) frames")
}

private func localizedLatency(milliseconds: Double) -> String {
    let number = localizedDecimal(milliseconds, minimumFractionDigits: 2, maximumFractionDigits: 2)
    return localized("\(number) ms")
}

private var noOutputName: String {
    localized("No output")
}

enum GlassEQAppLifecycleState: Equatable {
    case stopped
    case running
    case sleeping
    case waking
    case terminating
}

protocol AudioEngineControlling: AnyObject, Sendable {
    var state: AudioEngineState { get }

    func start(output: AudioOutputDevice, profile: EQProfile) throws
    func update(profile: EQProfile) throws
    @discardableResult func updateDSP(profile: EQProfile) -> Bool
    func setBypassed(_ isBypassed: Bool)
    func muteOutputForTransition()
    func stop()
    func snapshotMetrics() -> AudioEngineMetrics
    func resetDiagnostics()
}

extension SystemTapAudioEngine: AudioEngineControlling {}

protocol DefaultOutputLookingUp: Sendable {
    func defaultOutputDevice() throws -> AudioOutputDevice
}

struct CoreAudioDefaultOutputLookup: DefaultOutputLookingUp {
    func defaultOutputDevice() throws -> AudioOutputDevice {
        try CoreAudioDeviceQuery.defaultOutputDevice()
    }
}

typealias DefaultOutputObserverHandler = @Sendable (Result<AudioOutputDevice, Error>) -> Void

protocol DefaultOutputObserving: AnyObject {
    func start(sendInitialValue: Bool) throws
    func stop()
}

extension DefaultOutputDeviceObserver: DefaultOutputObserving {}

protocol DefaultOutputObservingMaking {
    func makeObserver(onChange: @escaping DefaultOutputObserverHandler) -> any DefaultOutputObserving
}

struct CoreAudioDefaultOutputObserverFactory: DefaultOutputObservingMaking {
    func makeObserver(onChange: @escaping DefaultOutputObserverHandler) -> any DefaultOutputObserving {
        DefaultOutputDeviceObserver(onChange: onChange)
    }
}

@MainActor
protocol WorkspaceOpening {
    func open(_ url: URL) -> Bool
}

extension NSWorkspace: WorkspaceOpening {}

extension SettingsAudioMetricsDTO {
    init(_ metrics: AudioEngineMetrics) {
        self.init(
            capturedFrames: metrics.capturedFrames,
            playedFrames: metrics.playedFrames,
            playbackUnderrunFrames: metrics.playbackUnderrunFrames,
            saturatedSamples: metrics.saturatedSamples,
            currentBufferedFrames: metrics.currentBufferedFrames,
            maxBufferedFrames: metrics.maxBufferedFrames,
            maximumPlaybackBufferedFrames: metrics.maximumPlaybackBufferedFrames,
            minimumPlaybackBufferedFrames: metrics.minimumPlaybackBufferedFrames,
            averagePlaybackBufferedFrames: metrics.averagePlaybackBufferedFrames,
            playbackBufferObservations: metrics.playbackBufferObservations,
            maximumCaptureCallbackFrames: metrics.maximumCaptureCallbackFrames,
            maximumPlaybackCallbackFrames: metrics.maximumPlaybackCallbackFrames
        )
    }
}

private actor ProfileStoreWriter {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func save(_ store: ProfileStore) throws {
        try ProfilePersistence.save(store, to: url)
    }

    func saveAndSynchronize(_ store: ProfileStore) throws {
        try save(store)
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        try handle.synchronize()
    }
}

@MainActor
@Observable
final class GlassEQAppModel {
    var currentOutputName = noOutputName
    var currentOutputUID = ""
    var currentOutputSampleRate = 0.0
    var currentOutputChannelCount = 0
    var currentOutputBufferFrameSize: UInt32 = 0
    var statusMessage = localized("Stopped")
    var isRunning = false
    var activeProfile: EQProfile
    var profileStore: ProfileStore
    var selectedProfileID: UUID
    var draftProfile: EQProfile
    var importFormat: ImportFormat = .autoEQ
    var importName = localized("Imported Profile")
    var importText = ""
    var engineMetrics = AudioEngineMetrics()
    var previewReturnProfile: EQProfile?
    private(set) var lifecycleState: GlassEQAppLifecycleState = .stopped

    private let engine: any AudioEngineControlling
    private let defaultOutputLookup: any DefaultOutputLookingUp
    private let observerFactory: any DefaultOutputObservingMaking
    private let workspaceOpener: any WorkspaceOpening
    private let outputChangeSettlingDelayOverride: Duration?
    private let wakeReconnectDelayOverride: Duration?
    private let saveDebounceDelay: Duration
    private var observer: (any DefaultOutputObserving)?
    private var metricsTask: Task<Void, Never>?
    private var outputChangeTask: Task<Void, Never>?
    private var engineStartTask: Task<Void, Never>?
    private var pendingSaveTask: Task<Void, Never>?
    private var lifecycleObserverTokens: [NSObjectProtocol] = []
    private var wasRunningBeforeSleep = false
    private var wakeReconnectAttempts = 0
    private var observerCallbackGeneration = 0
    private var outputChangeGeneration = 0
    private var engineStartGeneration = 0
    private var pendingEngineStartOutput: AudioOutputDevice?
    private let storeWriter: ProfileStoreWriter
    @ObservationIgnored lazy var settingsCoordinator = SettingsCoordinator(model: self)

    private enum EngineWork: Sendable {
        case start(output: AudioOutputDevice, profile: EQProfile)
        case restart(profile: EQProfile)
    }

    private enum EngineWorkResult: Sendable {
        case success(AudioOutputDevice)
        case failure(any Error, AudioOutputDevice?)
        case cancelled
    }

    private struct EngineWorkFailure: Error, LocalizedError, Sendable {
        var message: String

        var errorDescription: String? {
            message
        }
    }

    init(
        profileStore providedStore: ProfileStore? = nil,
        storeURL: URL = ProfilePersistence.defaultStoreURL(),
        engine: any AudioEngineControlling = SystemTapAudioEngine(),
        defaultOutputLookup: any DefaultOutputLookingUp = CoreAudioDefaultOutputLookup(),
        observerFactory: any DefaultOutputObservingMaking = CoreAudioDefaultOutputObserverFactory(),
        autoStart: Bool = true,
        installLifecycleObservers shouldInstallLifecycleObservers: Bool = true,
        registerAppDelegate: Bool = true,
        workspaceOpener: any WorkspaceOpening = NSWorkspace.shared,
        saveDebounceDelay: Duration = .milliseconds(250),
        outputChangeSettlingDelayOverride: Duration? = nil,
        wakeReconnectDelayOverride: Duration? = nil
    ) {
        let loadResult: ProfileStoreLoadResult?
        let loadedStore: ProfileStore
        if let providedStore {
            loadResult = nil
            loadedStore = providedStore
        } else {
            let result = ProfilePersistence.load(from: storeURL)
            loadResult = result
            loadedStore = result.store
        }
        let initialProfile = loadedStore.profile(forOutputUID: nil)
        self.profileStore = loadedStore
        self.activeProfile = initialProfile
        self.selectedProfileID = initialProfile.id
        self.draftProfile = initialProfile
        self.engine = engine
        self.defaultOutputLookup = defaultOutputLookup
        self.observerFactory = observerFactory
        self.workspaceOpener = workspaceOpener
        self.saveDebounceDelay = saveDebounceDelay
        self.outputChangeSettlingDelayOverride = outputChangeSettlingDelayOverride
        self.wakeReconnectDelayOverride = wakeReconnectDelayOverride
        self.storeWriter = ProfileStoreWriter(url: storeURL)
        if registerAppDelegate {
            GlassEQAppDelegate.model = self
        }
        if shouldInstallLifecycleObservers {
            installLifecycleObservers()
        }
        if let loadResult {
            if let loadStatusMessage = Self.profileStoreLoadStatusMessage(loadResult.status) {
                statusMessage = loadStatusMessage
            }
        } else {
            let repairSummary = profileStore.repairReferences()
            if repairSummary.didRepair {
                statusMessage = Self.profileStoreRepairStatus(repairSummary)
                saveStore()
            }
        }

        if autoStart {
            Task { @MainActor [weak self] in
                self?.start()
            }
        }
    }

    var hasUnsavedDraft: Bool {
        draftProfile != selectedProfile
    }

    var selectedProfile: EQProfile {
        profileStore.profiles.first(where: { $0.id == selectedProfileID }) ?? activeProfile
    }

    var currentOutputMappedProfileID: UUID? {
        profileStore.outputMappings.first(where: { $0.outputDeviceUID == currentOutputUID })?.profileID
    }

    func settingsSnapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            profiles: profileStore.profiles,
            selectedProfileID: selectedProfileID,
            draftProfile: draftProfile,
            activeProfileID: activeProfile.id,
            activeProfileName: activeProfile.name,
            currentOutputName: currentOutputName,
            currentOutputUID: currentOutputUID,
            currentOutputSampleRate: currentOutputSampleRate,
            currentOutputChannelCount: currentOutputChannelCount,
            currentOutputBufferFrameSize: currentOutputBufferFrameSize,
            currentOutputMappedProfileID: currentOutputMappedProfileID,
            fallbackProfileID: profileStore.fallbackProfileID,
            statusMessage: statusMessage,
            metrics: SettingsAudioMetricsDTO(engineMetrics),
            isPreviewing: previewReturnProfile != nil
        )
    }

    func start() {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }
        startObserver(sendInitialValue: true)
    }

    private func startObserver(sendInitialValue: Bool) {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }

        guard observer == nil else {
            do {
                try observer?.start(sendInitialValue: sendInitialValue)
            } catch {
                statusMessage = localized("Default output observer failed: \(error.localizedDescription)")
                lifecycleState = .stopped
                isRunning = false
            }
            notifyModelDidChange()
            return
        }

        observerCallbackGeneration += 1
        let generation = observerCallbackGeneration
        let observer = observerFactory.makeObserver { [weak self] result in
            Task { @MainActor in
                self?.scheduleDefaultOutputChange(result, observerGeneration: generation)
            }
        }
        self.observer = observer

        do {
            try observer.start(sendInitialValue: sendInitialValue)
        } catch {
            statusMessage = localized("Default output observer failed: \(error.localizedDescription)")
            if lifecycleState == .waking {
                scheduleWakeReconnectRetry(status: statusMessage)
            } else {
                lifecycleState = .stopped
                isRunning = false
            }
        }
        notifyModelDidChange()
    }

    func stop() {
        guard lifecycleState != .terminating else {
            return
        }
        wasRunningBeforeSleep = false
        stopObserver()
        invalidatePendingOutputChange()
        invalidatePendingEngineStart()
        metricsTask?.cancel()
        metricsTask = nil
        engine.stop()
        engineMetrics = engine.snapshotMetrics()
        previewReturnProfile = nil
        lifecycleState = .stopped
        isRunning = false
        statusMessage = localized("Stopped")
        notifyModelDidChange()
    }

    func selectProfile(_ id: UUID) {
        guard let profile = profileStore.profiles.first(where: { $0.id == id }) else {
            return
        }

        selectedProfileID = id
        draftProfile = profile
        notifyModelDidChange()
    }

    func applyDraft() {
        do {
            try apply(profile: draftProfile)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func apply(profile: EQProfile) throws {
        var store = profileStore
        upsertProfile(profile, in: &store)
        try ProfilePersistence.validate(store)

        profileStore = store
        activeProfile = profile
        selectedProfileID = profile.id
        draftProfile = profile
        saveStore()
        if lifecycleState == .waking {
            reschedulePendingEngineStartWithActiveProfile()
            notifyModelDidChange()
            return
        }
        if isRunning {
            if engine.updateDSP(profile: profile) {
                statusMessage = processingStatus(outputName: currentOutputName, profileName: profile.name)
            } else {
                restartEngineWithActiveProfile()
            }
        } else {
            restartEngineWithActiveProfile()
        }
        notifyModelDidChange()
    }

    func revertDraft() {
        draftProfile = selectedProfile
    }

    func useDraftForCurrentOutput() {
        do {
            try useForCurrentOutput(profile: draftProfile)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func useForCurrentOutput(profile: EQProfile) throws {
        guard !currentOutputUID.isEmpty else {
            return
        }

        var store = profileStore
        upsertProfile(profile, in: &store)
        store.outputMappings.removeAll { $0.outputDeviceUID == currentOutputUID }
        store.outputMappings.append(
            OutputDeviceProfileMapping(outputDeviceUID: currentOutputUID, profileID: profile.id)
        )
        try ProfilePersistence.validate(store)

        profileStore = store
        activeProfile = profile
        selectedProfileID = profile.id
        draftProfile = profile
        saveStore()
        if lifecycleState == .waking {
            reschedulePendingEngineStartWithActiveProfile()
            notifyModelDidChange()
            return
        }
        if isRunning {
            if engine.updateDSP(profile: profile) {
                statusMessage = processingStatus(outputName: currentOutputName, profileName: profile.name)
            } else {
                restartEngineWithActiveProfile()
            }
        } else {
            restartEngineWithActiveProfile()
        }
        notifyModelDidChange()
    }

    func setBypass(_ isBypassed: Bool) {
        var profile = draftProfile
        profile.isBypassed = isBypassed
        var store = profileStore
        upsertProfile(profile, in: &store)
        do {
            try ProfilePersistence.validate(store)
            profileStore = store
            draftProfile = profile
            activeProfile = profile
            saveStore()
            if lifecycleState == .waking {
                reschedulePendingEngineStartWithActiveProfile()
                notifyModelDidChange()
                return
            }
            engine.setBypassed(isBypassed)
            statusMessage = processingStatus(outputName: currentOutputName, profileName: profile.name)
            notifyModelDidChange()
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func createGraphic10Profile() {
        do {
            try createProfile(kind: .graphic10)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func createGraphic31Profile() {
        do {
            try createProfile(kind: .graphic31)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func createParametricProfile() {
        do {
            try createProfile(kind: .parametric)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func duplicateSelectedProfile() {
        do {
            try duplicateProfile(id: selectedProfileID)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func deleteSelectedProfile() {
        do {
            try deleteProfile(id: selectedProfileID)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func importProfile() {
        Task { @MainActor in
            if ((try? await importProfile(format: importFormat, name: importName, text: importText)) ?? false) {
                importText = ""
            }
        }
    }

    func importProfile(format: ImportFormat, name: String, text: String) async throws -> Bool {
        statusMessage = localized("Importing \(format.title)...")
        notifyModelDidChange()

        let result = await Task.detached(priority: .userInitiated) {
            Result<EQProfile, Error> {
                let imported: EQProfile
            switch format {
            case .autoEQ:
                imported = try EQProfileTextImporter.importAutoEQ(text, profileName: name)
            case .rew:
                imported = try EQProfileTextImporter.importREW(text, profileName: name)
            }
                return imported
            }
        }.value

        switch result {
        case .success(let imported):
            do {
                try addProfile(imported, name: imported.name, status: localized("Imported \(imported.name)"))
            } catch {
                statusMessage = localized("Import failed: \(error.localizedDescription)")
                notifyModelDidChange()
                throw error
            }
            statusMessage = localized("Imported \(imported.name)")
            notifyModelDidChange()
            return true
        case .failure(let error):
            statusMessage = localized("Import failed: \(error.localizedDescription)")
            notifyModelDidChange()
            throw error
        }
    }

    func setFallbackToDraft() {
        do {
            try setFallback(profile: draftProfile)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func setFallback(profile: EQProfile) throws {
        var store = profileStore
        upsertProfile(profile, in: &store)
        store.fallbackProfileID = profile.id
        try ProfilePersistence.validate(store)

        profileStore = store
        selectedProfileID = profile.id
        draftProfile = profile
        saveStore()
        statusMessage = localized("Fallback profile set to \(profile.name)")
        notifyModelDidChange()
    }

    func preview(profile: EQProfile) {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping,
              lifecycleState != .waking else {
            return
        }
        if previewReturnProfile == nil {
            previewReturnProfile = activeProfile
        }
        activeProfile = profile
        selectedProfileID = profile.id
        draftProfile = profile
        if engine.updateDSP(profile: profile) {
            statusMessage = localized("Previewing settings for \(profile.name)")
        } else {
            restartEngineWithActiveProfile()
        }
        notifyModelDidChange()
    }

    func stopPreview() {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping,
              lifecycleState != .waking else {
            return
        }
        guard let profile = previewReturnProfile else {
            return
        }
        previewReturnProfile = nil
        activeProfile = profile
        selectedProfileID = profile.id
        draftProfile = profile
        if engine.updateDSP(profile: profile) {
            statusMessage = processingStatus(outputName: currentOutputName, profileName: profile.name)
        } else {
            restartEngineWithActiveProfile()
        }
        notifyModelDidChange()
    }

    func resetDiagnostics() {
        engine.resetDiagnostics()
        engineMetrics = engine.snapshotMetrics()
        notifyModelDidChange()
    }

    @discardableResult
    private func addProfile(_ profile: EQProfile, name: String, status: String? = nil) throws -> EQProfile {
        var profile = profile
        profile.id = UUID()
        profile.name = uniqueProfileName(name)
        var store = profileStore
        store.profiles.append(profile)
        try ProfilePersistence.validate(store)

        profileStore = store
        selectedProfileID = profile.id
        draftProfile = profile
        saveStore()
        if let status {
            statusMessage = status
        }
        notifyModelDidChange()
        return profile
    }

    func createProfile(kind: SettingsProfileKind) throws {
        switch kind {
        case .graphic10:
            try addProfile(.flatGraphic10, name: localized("New 10-Band"), status: localized("Created New 10-Band"))
        case .graphic31:
            try addProfile(.flatGraphic31, name: localized("New 31-Band"), status: localized("Created New 31-Band"))
        case .parametric:
            var profile = EQProfile.flatParametric
            profile.filters = [
                EQFilter(kind: .peak, frequency: 1_000, gainDB: 0, q: 1)
            ]
            try addProfile(profile, name: localized("New Parametric"), status: localized("Created New Parametric"))
        }
    }

    func duplicateProfile(id: UUID) throws {
        guard let source = profileStore.profiles.first(where: { $0.id == id }) else {
            throw SettingsCommandFailure(message: localized("The selected profile no longer exists. Refresh settings and try again."))
        }
        var profile = source
        profile.id = UUID()
        try addProfile(profile, name: localized("\(source.name) Copy"), status: localized("Duplicated \(source.name)"))
    }

    func deleteProfile(id: UUID) throws {
        guard let deletedIndex = profileStore.profiles.firstIndex(where: { $0.id == id }) else {
            throw SettingsCommandFailure(message: localized("The selected profile no longer exists. Refresh settings and try again."))
        }
        guard profileStore.profiles.count > 1 else {
            throw SettingsCommandFailure(message: localized("At least one profile is required."))
        }
        guard id != activeProfile.id else {
            throw SettingsCommandFailure(message: localized("Switch to another profile before deleting the active profile"))
        }

        let previousSelection = selectedProfileID
        var store = profileStore
        store.profiles.removeAll { $0.id == id }
        store.outputMappings.removeAll { $0.profileID == id }
        if store.fallbackProfileID == id {
            store.fallbackProfileID = activeProfile.id
        }

        let nextSelectionID: UUID
        let nextDraft: EQProfile
        if previousSelection == id {
            let nextIndex = min(deletedIndex, store.profiles.count - 1)
            nextDraft = store.profiles[nextIndex]
            nextSelectionID = nextDraft.id
        } else {
            nextSelectionID = previousSelection
            nextDraft = draftProfile
        }

        try ProfilePersistence.validate(store)
        profileStore = store
        selectedProfileID = nextSelectionID
        draftProfile = nextDraft
        saveStore()
        statusMessage = localized("Deleted profile")
        notifyModelDidChange()
    }

    private func uniqueProfileName(_ name: String) -> String {
        let existing = Set(profileStore.profiles.map(\.name))
        guard existing.contains(name) else {
            return name
        }

        var index = 2
        while existing.contains(localized("\(name) \(index)")) {
            index += 1
        }
        return localized("\(name) \(index)")
    }

    private func upsertProfile(_ profile: EQProfile, in store: inout ProfileStore) {
        if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
            store.profiles[index] = profile
        } else {
            store.profiles.append(profile)
        }
    }

    private func reportProfileActionFailure(_ error: Error) {
        statusMessage = localized("Profile action failed: \(error.localizedDescription)")
        notifyModelDidChange()
    }

    private func restartEngineWithActiveProfile() {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping,
              lifecycleState != .waking else {
            return
        }

        statusMessage = localized("Reconnecting audio output...")
        scheduleEngineWork(.restart(profile: activeProfile))
        notifyModelDidChange()
    }

    private func scheduleDefaultOutputChange(_ result: Result<AudioOutputDevice, Error>, observerGeneration: Int) {
        // Observer callbacks can arrive after stop/sleep/restart; the generation gates them to
        // the observer instance that is currently allowed to drive engine state.
        guard observerGeneration == observerCallbackGeneration,
              lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }

        outputChangeGeneration += 1
        let generation = outputChangeGeneration
        let settlingDelay = outputChangeSettlingDelay(for: result)
        outputChangeTask?.cancel()
        if shouldMuteForSettlingOutputChange(result) {
            engine.muteOutputForTransition()
            statusMessage = outputChangeStatusMessage(for: result)
            notifyModelDidChange()
        }
        outputChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: settlingDelay)
            guard !Task.isCancelled,
                  self?.observerCallbackGeneration == observerGeneration else {
                return
            }
            guard self?.outputChangeGeneration == generation else {
                return
            }
            guard self?.lifecycleState != .terminating,
                  self?.lifecycleState != .sleeping else {
                return
            }
            guard let self else {
                return
            }

            let settledResult = Result { try self.defaultOutputLookup.defaultOutputDevice() }
            self.handleDefaultOutputChange(settledResult)
        }
    }

    private func shouldMuteForSettlingOutputChange(_ result: Result<AudioOutputDevice, Error>) -> Bool {
        guard isRunning,
              case .success(let output) = result,
              !currentOutputUID.isEmpty else {
            return false
        }

        return output.uid != currentOutputUID
            || output.nominalSampleRate != currentOutputSampleRate
            || output.bufferFrameSize != currentOutputBufferFrameSize
    }

    private func outputChangeStatusMessage(for result: Result<AudioOutputDevice, Error>) -> String {
        guard case .success(let output) = result else {
            return localized("Audio output changed; rebuilding...")
        }
        if output.uid == currentOutputUID {
            return localized("Audio output format changed; rebuilding...")
        }
        return localized("Audio output changed; rebuilding...")
    }

    private func outputChangeSettlingDelay(for result: Result<AudioOutputDevice, Error>) -> Duration {
        if let outputChangeSettlingDelayOverride {
            return outputChangeSettlingDelayOverride
        }

        guard case .success = result else {
            return OutputChangeReconnectPolicy.fallbackDelay
        }
        return OutputChangeReconnectPolicy.routeSwitchDelay
    }

    private func refreshCurrentOutputMetadata(from output: AudioOutputDevice) {
        currentOutputName = output.name
        currentOutputUID = output.uid
        currentOutputSampleRate = output.nominalSampleRate
        currentOutputChannelCount = output.outputChannelCount
        currentOutputBufferFrameSize = output.bufferFrameSize
    }

    private func handleDefaultOutputChange(_ result: Result<AudioOutputDevice, Error>) {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }

        previewReturnProfile = nil
        switch result {
        case .success(let output):
            refreshCurrentOutputMetadata(from: output)
            activeProfile = profileStore.profile(forOutputUID: output.uid)
            selectedProfileID = activeProfile.id
            draftProfile = activeProfile

            scheduleEngineWork(.start(output: output, profile: activeProfile))
        case .failure(let error):
            if lifecycleState == .waking {
                scheduleWakeReconnectRetry(status: localized("Waiting for audio output after wake: \(error.localizedDescription)"))
                return
            }
            invalidatePendingEngineStart()
            engine.stop()
            lifecycleState = .stopped
            isRunning = false
            statusMessage = localized("Default output unavailable: \(error.localizedDescription)")
        }
        notifyModelDidChange()
    }

    private func scheduleEngineWork(_ work: EngineWork) {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }

        engineStartGeneration += 1
        let generation = engineStartGeneration
        engineStartTask?.cancel()
        switch work {
        case .start(let output, _):
            pendingEngineStartOutput = output
        case .restart:
            pendingEngineStartOutput = nil
        }

        let engine = engine
        let defaultOutputLookup = defaultOutputLookup
        let workTask = Task.detached(priority: .userInitiated) {
            Self.performEngineWork(work, engine: engine, defaultOutputLookup: defaultOutputLookup)
        }

        engineStartTask = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler {
                await workTask.value
            } onCancel: {
                workTask.cancel()
            }
            guard !Task.isCancelled else {
                self?.cleanupCancelledEngineWork(result, generation: generation)
                return
            }
            self?.completeEngineWork(result, generation: generation)
        }
    }

    nonisolated private static func performEngineWork(
        _ work: EngineWork,
        engine: any AudioEngineControlling,
        defaultOutputLookup: any DefaultOutputLookingUp
    ) -> EngineWorkResult {
        var attemptedOutput: AudioOutputDevice?
        do {
            let output: AudioOutputDevice
            switch work {
            case .start(let requestedOutput, let profile):
                guard !Task.isCancelled else {
                    return .cancelled
                }
                attemptedOutput = requestedOutput
                try engine.start(output: requestedOutput, profile: profile)
                if case .running(let activeOutput) = engine.state {
                    output = activeOutput
                } else {
                    output = requestedOutput
                }
            case .restart(let profile):
                switch engine.state {
                case .running(let runningOutput):
                    guard !Task.isCancelled else {
                        return .cancelled
                    }
                    attemptedOutput = runningOutput
                    try engine.update(profile: profile)
                    guard case .running(let activeOutput) = engine.state else {
                        return .failure(
                            EngineWorkFailure(message: localized("Default output unavailable")),
                            attemptedOutput
                        )
                    }
                    output = activeOutput
                case .stopped, .failed:
                    let defaultOutput = try defaultOutputLookup.defaultOutputDevice()
                    attemptedOutput = defaultOutput
                    if Task.isCancelled {
                        return .cancelled
                    }
                    try engine.start(output: defaultOutput, profile: profile)
                    if case .running(let activeOutput) = engine.state {
                        output = activeOutput
                    } else {
                        output = defaultOutput
                    }
                }
            }
            return .success(output)
        } catch {
            return .failure(error, attemptedOutput)
        }
    }

    private func cleanupCancelledEngineWork(_ result: EngineWorkResult, generation: Int) {
        // Cancellation is cooperative: the detached worker may finish `engine.start` after this
        // model has already moved on. Never let a stale worker stop the shared engine while a
        // newer generation is pending or running; only clean up if the app's current intent is no
        // running engine at all.
        guard generation != engineStartGeneration,
              engineStartTask == nil else {
            return
        }
        guard case .success = result else {
            return
        }
        guard lifecycleState == .stopped
                || lifecycleState == .sleeping
                || lifecycleState == .terminating else {
            return
        }
        engine.stop()
        if lifecycleState == .stopped {
            engineMetrics = engine.snapshotMetrics()
        }
    }

    private func completeEngineWork(_ result: EngineWorkResult, generation: Int) {
        guard generation == engineStartGeneration,
              lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }

        engineStartTask = nil
        pendingEngineStartOutput = nil

        switch result {
        case .success(let output):
            refreshCurrentOutputMetadata(from: output)
            lifecycleState = .running
            isRunning = true
            wakeReconnectAttempts = 0
            wasRunningBeforeSleep = false
            statusMessage = processingStatus(outputName: output.name, profileName: activeProfile.name)
        case .failure(let error, let attemptedOutput):
            if let attemptedOutput {
                refreshCurrentOutputMetadata(from: attemptedOutput)
            }
            if lifecycleState == .waking {
                scheduleWakeReconnectRetry(status: audioEngineStatusMessage(error))
                return
            }
            lifecycleState = .stopped
            isRunning = false
            statusMessage = audioEngineStatusMessage(error)
        case .cancelled:
            return
        }
        notifyModelDidChange()
    }

    private func reschedulePendingEngineStartWithActiveProfile() {
        guard lifecycleState == .waking,
              let output = pendingEngineStartOutput else {
            return
        }
        scheduleEngineWork(.start(output: output, profile: activeProfile))
    }

    private func scheduleWakeReconnectRetry(status: String) {
        guard lifecycleState == .waking else {
            return
        }
        guard wakeReconnectAttempts < WakeReconnectPolicy.maximumAttempts else {
            invalidatePendingEngineStart()
            engine.stop()
            lifecycleState = .stopped
            isRunning = false
            statusMessage = status
            notifyModelDidChange()
            return
        }

        statusMessage = status
        notifyModelDidChange()
        outputChangeGeneration += 1
        let generation = outputChangeGeneration
        outputChangeTask?.cancel()
        outputChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.wakeReconnectDelayOverride ?? WakeReconnectPolicy.retryDelay)
            guard !Task.isCancelled,
                  self?.outputChangeGeneration == generation,
                  self?.lifecycleState == .waking else {
                return
            }
            self?.requestWakeReconnectAttempt()
        }
    }

    private func saveStore() {
        let store = profileStore
        let storeWriter = storeWriter
        let saveDebounceDelay = saveDebounceDelay

        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: saveDebounceDelay)
                try Task.checkCancellation()
                try await storeWriter.save(store)
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self?.statusMessage = localized("Save failed: \(error.localizedDescription)")
                    self?.notifyModelDidChange()
                }
            }
        }
    }

    func flushStoreBeforeQuit() async -> Bool {
        pendingSaveTask?.cancel()
        await pendingSaveTask?.value
        pendingSaveTask = nil
        do {
            try await storeWriter.saveAndSynchronize(profileStore)
            return true
        } catch {
            statusMessage = localized("Quit canceled: failed to save profiles: \(error.localizedDescription)")
            notifyModelDidChange()
            return false
        }
    }

    func requestQuit() {
        Task { @MainActor [weak self] in
            guard let self else {
                NSApplication.shared.terminate(nil)
                return
            }
            guard await self.flushStoreBeforeQuit() else {
                return
            }
            self.cleanupForTermination()
            GlassEQAppDelegate.allowNextTerminationImmediately()
            NSApplication.shared.terminate(nil)
        }
    }

    func retryAudioEngine() {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }
        guard lifecycleState != .waking else {
            requestWakeReconnectAttempt()
            return
        }
        restartEngineWithActiveProfile()
    }

    func openPrivacySettings() throws {
        let urls = [
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security")
        ].compactMap { $0 }
        for url in urls where workspaceOpener.open(url) {
            return
        }
        throw SettingsCommandFailure(
            message: localized("Could not open System Settings. Open Privacy & Security manually and enable system audio capture for GlassEQ.")
        )
    }

    private func processingStatus(outputName: String, profileName: String) -> String {
        guard !outputName.isEmpty, outputName != noOutputName else {
            return localized("Processing \(profileName)")
        }
        return localized("Processing \(outputName) with \(profileName)")
    }

    func startMetricsPolling() {
        guard lifecycleState != .terminating else {
            return
        }
        guard metricsTask == nil else {
            return
        }

        engineMetrics = engine.snapshotMetrics()
        notifyMetricsDidChange()

        metricsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else {
                    return
                }
                let nextMetrics = self.engine.snapshotMetrics()
                guard nextMetrics != self.engineMetrics else {
                    continue
                }
                self.engineMetrics = nextMetrics
                self.notifyMetricsDidChange()
            }
        }
    }

    func stopMetricsPolling() {
        metricsTask?.cancel()
        metricsTask = nil
    }

    func notifyModelDidChange() {
        NotificationCenter.default.post(name: .glassEQModelDidChange, object: self)
        settingsCoordinator.modelDidChange()
    }

    private func notifyMetricsDidChange() {
        NotificationCenter.default.post(name: .glassEQMetricsDidChange, object: self)
        settingsCoordinator.metricsDidChange()
    }

    private func stopObserver() {
        observerCallbackGeneration += 1
        observer?.stop()
        observer = nil
    }

    private func invalidatePendingOutputChange() {
        outputChangeGeneration += 1
        outputChangeTask?.cancel()
        outputChangeTask = nil
    }

    private func invalidatePendingEngineStart() {
        engineStartGeneration += 1
        engineStartTask?.cancel()
        engineStartTask = nil
        pendingEngineStartOutput = nil
    }

    private func installLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        lifecycleObserverTokens.append(
            workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleWillSleep()
                }
            }
        )
        lifecycleObserverTokens.append(
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleDidWake()
                }
            }
        )
        lifecycleObserverTokens.append(
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSessionDidBecomeActive()
                }
            }
        )
        lifecycleObserverTokens.append(
            workspaceCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSessionDidBecomeActive()
                }
            }
        )
        lifecycleObserverTokens.append(
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.cleanupForTermination()
                }
            }
        )
    }

    func handleWillSleep() {
        guard lifecycleState != .terminating else {
            return
        }

        wasRunningBeforeSleep = isRunning || wasRunningBeforeSleep
        invalidatePendingOutputChange()
        invalidatePendingEngineStart()
        stopObserver()
        engine.stop()
        previewReturnProfile = nil
        lifecycleState = .sleeping
        isRunning = false
        statusMessage = localized("Paused for system sleep")
        notifyModelDidChange()
    }

    func handleDidWake() {
        guard lifecycleState != .terminating else {
            return
        }
        guard lifecycleState == .sleeping else {
            return
        }

        guard wasRunningBeforeSleep else {
            wasRunningBeforeSleep = false
            lifecycleState = .stopped
            isRunning = false
            statusMessage = localized("Stopped")
            notifyModelDidChange()
            return
        }
        beginAudioReconnect(
            status: localized("Reconnecting audio output..."),
            initialDelay: wakeReconnectDelayOverride ?? .seconds(1)
        )
    }

    func handleSessionDidBecomeActive() {
        guard lifecycleState != .terminating else {
            return
        }
        guard lifecycleState != .sleeping else {
            handleDidWake()
            return
        }
        guard !wasRunningBeforeSleep else {
            beginAudioReconnect(
                status: localized("Reconnecting audio output..."),
                initialDelay: wakeReconnectDelayOverride ?? SessionActivationReconnectPolicy.reconnectDelay
            )
            return
        }
    }

    private func beginAudioReconnect(status: String, initialDelay: Duration) {
        guard lifecycleState != .waking else {
            statusMessage = status
            notifyModelDidChange()
            return
        }
        invalidatePendingOutputChange()
        let generation = outputChangeGeneration
        wakeReconnectAttempts = 0
        lifecycleState = .waking
        statusMessage = status
        notifyModelDidChange()
        outputChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: initialDelay)
            guard !Task.isCancelled,
                  self?.outputChangeGeneration == generation,
                  self?.lifecycleState == .waking else {
                return
            }
            self?.requestWakeReconnectAttempt()
        }
    }

    private func requestWakeReconnectAttempt() {
        guard lifecycleState == .waking else {
            return
        }
        wakeReconnectAttempts += 1
        startObserver(sendInitialValue: true)
    }

    func cleanupForTermination() {
        guard lifecycleState != .terminating else {
            return
        }
        lifecycleState = .terminating
        wasRunningBeforeSleep = false
        invalidatePendingOutputChange()
        invalidatePendingEngineStart()
        metricsTask?.cancel()
        metricsTask = nil
        stopObserver()
        engine.stop()
        previewReturnProfile = nil
        isRunning = false
        settingsCoordinator.shutdown()
        notifyModelDidChange()
    }

    private func audioEngineStatusMessage(_ error: Error) -> String {
        if let coreAudioError = error as? CoreAudioError {
            return audioEngineStatusMessage(classifyCoreAudioError(coreAudioError))
        }
        if let availabilityError = error as? AudioDeviceAvailabilityError {
            if case .unsupportedOutputChannelCount = availabilityError {
                return localized("Output format unsupported: \(availabilityError.description)")
            }
            return localized("Default output unavailable: \(availabilityError.description)")
        }
        return localized("Audio engine failed: \(error.localizedDescription)")
    }

    private func audioEngineStatusMessage(_ failure: AudioEngineFailure) -> String {
        switch failure.category {
        case .systemAudioCapturePermission:
            return localized("System audio capture permission required. Enable GlassEQ in System Settings, then retry.")
        case .outputDeviceUnavailable:
            return localized("Default output unavailable: \(failure.userMessage)")
        case .deviceFormatUnsupported:
            return localized("Output format unsupported: \(failure.operation)")
        case .coreAudioOperationFailed:
            if let status = failure.status {
                return localized("Audio engine failed at \(failure.operation) (\(formatOSStatus(status)))")
            }
            return localized("Audio engine failed: \(failure.userMessage)")
        }
    }

    private static func profileStoreLoadStatusMessage(_ status: ProfileStoreLoadStatus) -> String? {
        switch status {
        case .loaded, .missingStore:
            return nil
        case .repairedReferences(let summary):
            return profileStoreRepairStatus(summary)
        case .recoveredDefaults:
            return localized("Profile store was invalid; backed it up and restored defaults")
        case .backupFailed:
            return localized("Profile store was invalid; using defaults, but backup failed")
        }
    }

    private static func profileStoreRepairStatus(_ summary: ProfileStoreRepairSummary) -> String {
        if summary.repairedFallbackProfileID && summary.removedOutputMappings > 0 {
            return localized("Profile store repaired: reset fallback and removed unavailable output mappings")
        }
        if summary.repairedFallbackProfileID {
            return localized("Profile store repaired: fallback reset")
        }
        if summary.removedOutputMappings > 0 || summary.deduplicatedOutputMappings > 0 {
            return localized("Profile store repaired: removed unavailable output mapping")
        }
        return localized("Profile store repaired")
    }
}

private struct MenuBarView: View {
    @Bindable var model: GlassEQAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            popoverValue(title: localized("Output"), value: model.currentOutputName)

            VStack(alignment: .leading, spacing: 5) {
                Text(localized("Profile"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(localized("Profile"), selection: Binding(
                    get: { model.selectedProfileID },
                    set: { model.selectProfile($0) }
                )) {
                    ForEach(model.profileStore.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(Text(localized("Profile")))
                .accessibilityValue(Text(model.selectedProfile.name))
                .accessibilityHint(Text(localized("Chooses the active profile")))
            }

            HStack(spacing: 10) {
                Button {
                    model.setBypass(!model.draftProfile.isBypassed)
                } label: {
                    Label(
                        model.draftProfile.isBypassed ? localized("Enable") : localized("Disable"),
                        systemImage: model.draftProfile.isBypassed ? "speaker.wave.2" : "speaker.slash"
                    )
                        .frame(minWidth: 82, minHeight: 28)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .buttonStyle(.glass)
                .tint(popoverControlsAreActive ? enableButtonTint : nil)
                .accessibilityLabel(Text(model.draftProfile.isBypassed ? localized("Enable equalizer") : localized("Disable equalizer")))
                .accessibilityValue(Text(statusBadgeTitle))
                .accessibilityHint(Text(localized("Toggles audio bypass for the selected profile")))

                Button {
                    dismiss()
                    model.openSettings()
                } label: {
                    Label(localized("Settings"), systemImage: "slider.horizontal.3")
                        .frame(minWidth: 86, minHeight: 28)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .buttonStyle(.glass)

                Button(role: .destructive) {
                    model.requestQuit()
                } label: {
                    Label(localized("Quit"), systemImage: "power")
                        .frame(minWidth: 58, minHeight: 28)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .buttonStyle(.glass)
                .tint(popoverControlsAreActive ? .macOSSystemRed : nil)
            }

            Text(model.statusMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(model.isRunning ? Color.secondary : Color.macOSSystemRed)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(localized("Status")))
                .accessibilityValue(Text(model.statusMessage))
        }
        .padding()
        .background { PopoverGlassConfigurator() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(localized("GlassEQ"))
                    .font(.title3.weight(.semibold))
                Text(AppBuildInfo.displayVersion)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(statusBadgeTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusBadgeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    statusBadgeColor.opacity(0.12),
                    in: .capsule
                )
                .accessibilityLabel(Text(localized("Menu bar state")))
                .accessibilityValue(Text(statusBadgeTitle))
        }
    }

    private var statusBadgeTitle: String {
        guard model.isRunning else {
            return localized("Stopped")
        }
        return model.draftProfile.isBypassed ? localized("Disabled") : localized("Active")
    }

    private var statusBadgeColor: Color {
        model.isRunning && !model.draftProfile.isBypassed ? .macOSSystemGreen : .macOSSystemRed
    }

    private var enableButtonTint: Color {
        model.draftProfile.isBypassed ? .macOSSystemGreen : .macOSSystemYellow
    }

    private var popoverControlsAreActive: Bool {
        controlActiveState != .inactive
    }

    private func popoverValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
    }
}


private enum PopoverGlassAppearance {
    /// Opacity applied to the popover's system Liquid Glass backing (NSGlassView).
    /// 1.0 keeps the full system frost; lower values thin it so more of the desktop shows
    /// through. Our content is a sibling of the backing, so it stays fully opaque regardless.
    static let backingAlpha: CGFloat = 0.2
}

private final class PopoverGlassConfiguringView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            return
        }
        let root = window.contentView?.superview ?? window.contentView
        root.map(Self.dimGlassBacking)
    }

    private static func dimGlassBacking(_ view: NSView) {
        if String(describing: type(of: view)) == "NSGlassView" {
            view.alphaValue = PopoverGlassAppearance.backingAlpha
        }
        for subview in view.subviews {
            dimGlassBacking(subview)
        }
    }
}

private struct PopoverGlassConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> PopoverGlassConfiguringView {
        PopoverGlassConfiguringView()
    }

    func updateNSView(_ nsView: PopoverGlassConfiguringView, context: Context) {}
}

private extension Color {
    static let macOSSystemGreen = Color(nsColor: .systemGreen)
    static let macOSSystemRed = Color(nsColor: .systemRed)
    static let macOSSystemYellow = Color(nsColor: .systemYellow)
}
