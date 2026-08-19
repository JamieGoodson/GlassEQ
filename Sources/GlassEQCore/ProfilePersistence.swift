import Foundation

public struct ProfileStoreLoadResult: Equatable, Sendable {
    public var store: ProfileStore
    public var status: ProfileStoreLoadStatus

    public init(store: ProfileStore, status: ProfileStoreLoadStatus) {
        self.store = store
        self.status = status
    }
}

public enum ProfileStoreLoadStatus: Equatable, Sendable {
    case loaded
    case missingStore
    case repairedReferences(ProfileStoreRepairSummary)
    case repairedInvalidStore(backupURL: URL, ProfileStoreRepairSummary)
    case recoveredDefaults(backupURL: URL)
    case backupFailed
    case unsupportedSchemaVersion(version: Int, maximumSupported: Int)
}

public enum ProfileStoreValidationError: Error, Equatable, Sendable, LocalizedError {
    case inputTooLarge(byteCount: Int, maximum: Int)
    case unsupportedSchemaVersion(version: Int, maximumSupported: Int)
    case invalidProfileCount(count: Int, allowed: ClosedRange<Int>)
    case invalidOutputMappingCount(count: Int, allowed: ClosedRange<Int>)
    case invalidBypassedOutputDeviceCount(count: Int, allowed: ClosedRange<Int>)
    case duplicateProfileID(profileID: UUID)
    case missingFallbackProfile(profileID: UUID)
    case emptyProfileName(profileID: UUID)
    case profileNameTooLong(profileID: UUID, byteCount: Int, maximum: Int)
    case outputUIDTooLong(mappingIndex: Int, byteCount: Int, maximum: Int)
    case emptyBypassedOutputUID(index: Int)
    case bypassedOutputUIDTooLong(index: Int, byteCount: Int, maximum: Int)
    case duplicateBypassedOutputUID(uid: String)
    case valueOutOfRange(profileID: UUID, field: String, value: Double, range: ClosedRange<Double>)
    case tooManyFilters(profileID: UUID, channel: String, count: Int, maximum: Int)
    case tooManyActiveFilters(profileID: UUID, channel: String, count: Int, maximum: Int)
    case tooManyStereoFilters(profileID: UUID, count: Int, maximum: Int)
    case tooManyStereoActiveFilters(profileID: UUID, count: Int, maximum: Int)
    case invalidGraphicBandCount(profileID: UUID, channel: String, count: Int, expected: Int)

    public var errorDescription: String? {
        switch self {
        case let .inputTooLarge(byteCount, maximum):
            return "Profile store is \(byteCount) bytes, which exceeds the \(maximum)-byte limit."
        case let .unsupportedSchemaVersion(version, maximumSupported):
            return "Profile store schema \(version) is newer than this build supports (\(maximumSupported))."
        case let .invalidProfileCount(count, allowed):
            return "Profile store has \(count) profiles; expected \(allowed.lowerBound)...\(allowed.upperBound)."
        case let .invalidOutputMappingCount(count, allowed):
            return "Profile store has \(count) output mappings; expected \(allowed.lowerBound)...\(allowed.upperBound)."
        case let .invalidBypassedOutputDeviceCount(count, allowed):
            return "Profile store has \(count) bypassed output devices; expected \(allowed.lowerBound)...\(allowed.upperBound)."
        case let .duplicateProfileID(profileID):
            return "Profile store contains duplicate profile ID \(profileID)."
        case let .missingFallbackProfile(profileID):
            return "Profile store fallback profile \(profileID) does not exist."
        case .emptyProfileName:
            return "Profile store contains an empty profile name."
        case let .profileNameTooLong(_, byteCount, maximum):
            return "Profile store contains a profile name with \(byteCount) UTF-8 bytes, which exceeds the \(maximum)-byte limit."
        case let .outputUIDTooLong(mappingIndex, byteCount, maximum):
            return "Output mapping \(mappingIndex) has \(byteCount) UTF-8 bytes, which exceeds the \(maximum)-byte limit."
        case let .emptyBypassedOutputUID(index):
            return "Bypassed output device \(index) has an empty UID."
        case let .bypassedOutputUIDTooLong(index, byteCount, maximum):
            return "Bypassed output device \(index) has \(byteCount) UTF-8 bytes, which exceeds the \(maximum)-byte limit."
        case let .duplicateBypassedOutputUID(uid):
            return "Profile store contains duplicate bypassed output device UID \(uid)."
        case let .valueOutOfRange(_, field, value, range):
            return "Profile store contains \(field) \(format(value)), outside the allowed range \(format(range.lowerBound))...\(format(range.upperBound))."
        case let .tooManyFilters(_, channel, count, maximum):
            return "Profile store contains \(count) \(channel) filters, which exceeds the \(maximum)-filter channel limit."
        case let .tooManyActiveFilters(_, channel, count, maximum):
            return "Profile store contains \(count) active \(channel) filters, which exceeds the \(maximum)-filter channel limit."
        case let .tooManyStereoFilters(_, count, maximum):
            return "Profile store contains \(count) stereo filters, which exceeds the \(maximum)-filter stereo limit."
        case let .tooManyStereoActiveFilters(_, count, maximum):
            return "Profile store contains \(count) active stereo filters, which exceeds the \(maximum)-filter stereo limit."
        case let .invalidGraphicBandCount(_, channel, count, expected):
            return "Graphic profile contains \(count) active \(channel) bands; expected \(expected)."
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

public enum ProfilePersistence {
    public static let maxStoreBytes = 5 * 1_024 * 1_024
    public static let profileCountRange = 1...64
    public static let outputMappingCountRange = 0...256
    public static let bypassedOutputDeviceCountRange = 0...256
    public static let maxProfileNameUTF8Bytes = 120
    public static let maxOutputUIDUTF8Bytes = 512
    public static let maxFiltersPerChannel = 128
    public static let maxStereoFilters = 256
    public static let maxActiveFiltersPerChannel = maxFiltersPerChannel
    public static let maxStereoActiveFilters = maxStereoFilters
    public static let frequencyRange: ClosedRange<Double> = 1...24_000
    public static let gainRange: ClosedRange<Double> = -120...120
    public static let preampRange: ClosedRange<Double> = -120...120
    public static let qRange: ClosedRange<Double> = 0.01...100

    public static var encoder: JSONEncoder {
        makeEncoder()
    }

    public static var decoder: JSONDecoder {
        JSONDecoder()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func encode(_ store: ProfileStore) throws -> Data {
        try encoder.encode(store)
    }

    public static func decode(_ data: Data) throws -> ProfileStore {
        try validateStoreSize(byteCount: data.count)
        let store = try decodeRaw(data)
        try validate(store)
        return store
    }

    private static func decodeRaw(_ data: Data) throws -> ProfileStore {
        try decoder.decode(ProfileStore.self, from: data)
    }

    public static func validate(_ store: ProfileStore) throws {
        guard store.schemaVersion <= ProfileStore.currentSchemaVersion else {
            throw ProfileStoreValidationError.unsupportedSchemaVersion(
                version: store.schemaVersion,
                maximumSupported: ProfileStore.currentSchemaVersion
            )
        }
        guard store.schemaVersion > 0 else {
            throw ProfileStoreValidationError.unsupportedSchemaVersion(
                version: store.schemaVersion,
                maximumSupported: ProfileStore.currentSchemaVersion
            )
        }

        guard profileCountRange.contains(store.profiles.count) else {
            throw ProfileStoreValidationError.invalidProfileCount(
                count: store.profiles.count,
                allowed: profileCountRange
            )
        }

        guard outputMappingCountRange.contains(store.outputMappings.count) else {
            throw ProfileStoreValidationError.invalidOutputMappingCount(
                count: store.outputMappings.count,
                allowed: outputMappingCountRange
            )
        }

        guard bypassedOutputDeviceCountRange.contains(store.bypassedOutputDeviceUIDs.count) else {
            throw ProfileStoreValidationError.invalidBypassedOutputDeviceCount(
                count: store.bypassedOutputDeviceUIDs.count,
                allowed: bypassedOutputDeviceCountRange
            )
        }

        var profileIDs = Set<UUID>()
        for profile in store.profiles {
            guard profileIDs.insert(profile.id).inserted else {
                throw ProfileStoreValidationError.duplicateProfileID(profileID: profile.id)
            }
        }
        guard profileIDs.contains(store.fallbackProfileID) else {
            throw ProfileStoreValidationError.missingFallbackProfile(profileID: store.fallbackProfileID)
        }

        for profile in store.profiles {
            try validate(profile)
        }

        for (index, mapping) in store.outputMappings.enumerated() {
            let byteCount = mapping.outputDeviceUID.utf8.count
            guard byteCount <= maxOutputUIDUTF8Bytes else {
                throw ProfileStoreValidationError.outputUIDTooLong(
                    mappingIndex: index,
                    byteCount: byteCount,
                    maximum: maxOutputUIDUTF8Bytes
                )
            }
        }

        var bypassedOutputUIDs = Set<String>()
        for (index, uid) in store.bypassedOutputDeviceUIDs.enumerated() {
            guard !uid.isEmpty else {
                throw ProfileStoreValidationError.emptyBypassedOutputUID(index: index)
            }
            let byteCount = uid.utf8.count
            guard byteCount <= maxOutputUIDUTF8Bytes else {
                throw ProfileStoreValidationError.bypassedOutputUIDTooLong(
                    index: index,
                    byteCount: byteCount,
                    maximum: maxOutputUIDUTF8Bytes
                )
            }
            guard bypassedOutputUIDs.insert(uid).inserted else {
                throw ProfileStoreValidationError.duplicateBypassedOutputUID(uid: uid)
            }
        }
    }

    public static func validateForCommit(_ store: ProfileStore) throws {
        _ = try encodeForCommit(store)
    }

    public static func save(_ store: ProfileStore, to url: URL) throws {
        let data = try encodeForCommit(store)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL, timestamp: Date = Date()) -> ProfileStoreLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProfileStoreLoadResult(store: defaultStore(), status: .missingStore)
        }

        if let byteCount = storeByteCount(at: url), byteCount > maxStoreBytes {
            return recoverInvalidStore(at: url, timestamp: timestamp)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
            try validateStoreSize(byteCount: data.count)
        } catch {
            return recoverInvalidStore(at: url, timestamp: timestamp)
        }

        do {
            var store = try decodeRaw(data)
            if store.schemaVersion > ProfileStore.currentSchemaVersion {
                return ProfileStoreLoadResult(
                    store: defaultStore(),
                    status: .unsupportedSchemaVersion(
                        version: store.schemaVersion,
                        maximumSupported: ProfileStore.currentSchemaVersion
                    )
                )
            }
            let repairSummary = store.repairReferences()
            do {
                try validate(store)
            } catch {
                return repairInvalidDecodedStore(
                    store,
                    initialRepairSummary: repairSummary,
                    at: url,
                    timestamp: timestamp
                )
            }

            if repairSummary.didRepair {
                try save(store, to: url)
                return ProfileStoreLoadResult(store: store, status: .repairedReferences(repairSummary))
            }

            return ProfileStoreLoadResult(store: store, status: .loaded)
        } catch {
            if let repairable = try? decodeRepairableStore(data) {
                if repairable.store.schemaVersion > ProfileStore.currentSchemaVersion {
                    return ProfileStoreLoadResult(
                        store: defaultStore(),
                        status: .unsupportedSchemaVersion(
                            version: repairable.store.schemaVersion,
                            maximumSupported: ProfileStore.currentSchemaVersion
                        )
                    )
                }
                return repairInvalidDecodedStore(
                    repairable.store,
                    initialRepairSummary: ProfileStoreRepairSummary(
                        removedInvalidProfiles: repairable.removedInvalidProfiles
                    ),
                    at: url,
                    timestamp: timestamp
                )
            }
            return recoverInvalidStore(at: url, timestamp: timestamp)
        }
    }

    public static func invalidStoreBackupURL(for storeURL: URL, timestamp: Date = Date()) -> URL {
        let baseName = storeURL.deletingPathExtension().lastPathComponent
        let pathExtension = storeURL.pathExtension
        let backupName = if pathExtension.isEmpty {
            "\(baseName).invalid-\(timestampString(from: timestamp))"
        } else {
            "\(baseName).invalid-\(timestampString(from: timestamp)).\(pathExtension)"
        }

        return storeURL.deletingLastPathComponent().appendingPathComponent(backupName)
    }

    public static func resetUnsupportedStore(
        at url: URL,
        timestamp: Date = Date()
    ) throws -> (store: ProfileStore, backupURL: URL) {
        let store = defaultStore()
        let backupURL = uniqueInvalidStoreBackupURL(for: url, timestamp: timestamp)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: backupURL)
        do {
            try save(store, to: url)
        } catch {
            try? FileManager.default.moveItem(at: backupURL, to: url)
            throw error
        }
        return (store, backupURL)
    }

    public static func defaultStoreURL(
        applicationSupportDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("GlassEQ", isDirectory: true)
            .appendingPathComponent("Profiles.json")
    }

    private static func validateStoreSize(byteCount: Int) throws {
        guard byteCount <= maxStoreBytes else {
            throw ProfileStoreValidationError.inputTooLarge(byteCount: byteCount, maximum: maxStoreBytes)
        }
    }

    private static func encodeForCommit(_ store: ProfileStore) throws -> Data {
        try validate(store)
        let data = try encode(store)
        try validateStoreSize(byteCount: data.count)
        return data
    }

    private struct ProfileStoreEnvelope: Decodable {
        var schemaVersion: Int
        var outputMappings: [OutputDeviceProfileMapping]
        var isBypassed: Bool
        var bypassedOutputDeviceUIDs: [String]
        var fallbackProfileID: UUID

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case outputMappings
            case isBypassed
            case bypassedOutputDeviceUIDs
            case fallbackProfileID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? ProfileStore.currentSchemaVersion
            outputMappings = try container.decode([OutputDeviceProfileMapping].self, forKey: .outputMappings)
            isBypassed = try container.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
            bypassedOutputDeviceUIDs = try container.decodeIfPresent(
                [String].self,
                forKey: .bypassedOutputDeviceUIDs
            ) ?? []
            fallbackProfileID = try container.decode(UUID.self, forKey: .fallbackProfileID)
        }
    }

    private static func decodeRepairableStore(_ data: Data) throws -> (
        store: ProfileStore,
        removedInvalidProfiles: Int
    ) {
        let envelope = try decoder.decode(ProfileStoreEnvelope.self, from: data)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any],
              let rawProfiles = object["profiles"] as? [Any] else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Profile store profiles array is missing.")
            )
        }

        var profiles: [EQProfile] = []
        var removedInvalidProfiles = 0
        for rawProfile in rawProfiles {
            guard JSONSerialization.isValidJSONObject(rawProfile) else {
                removedInvalidProfiles += 1
                continue
            }
            do {
                let profileData = try JSONSerialization.data(withJSONObject: rawProfile)
                profiles.append(try decoder.decode(EQProfile.self, from: profileData))
            } catch {
                removedInvalidProfiles += 1
            }
        }

        return (
            ProfileStore(
                schemaVersion: envelope.schemaVersion,
                profiles: profiles,
                outputMappings: envelope.outputMappings,
                isBypassed: envelope.isBypassed,
                bypassedOutputDeviceUIDs: envelope.bypassedOutputDeviceUIDs,
                fallbackProfileID: envelope.fallbackProfileID
            ),
            removedInvalidProfiles
        )
    }

    private static func validate(_ profile: EQProfile) throws {
        let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ProfileStoreValidationError.emptyProfileName(profileID: profile.id)
        }

        let nameByteCount = profile.name.utf8.count
        guard nameByteCount <= maxProfileNameUTF8Bytes else {
            throw ProfileStoreValidationError.profileNameTooLong(
                profileID: profile.id,
                byteCount: nameByteCount,
                maximum: maxProfileNameUTF8Bytes
            )
        }

        try validate(profile.preampDB, in: preampRange, field: "preamp", profileID: profile.id)
        try validate(profile.leftPreampDB, in: preampRange, field: "left preamp", profileID: profile.id)
        try validate(profile.rightPreampDB, in: preampRange, field: "right preamp", profileID: profile.id)

        let linkedCounts = try validateFilters(profile.filters, channel: "linked", profileID: profile.id)
        let leftCounts = try validateFilters(profile.leftFilters, channel: "left", profileID: profile.id)
        let rightCounts = try validateFilters(profile.rightFilters, channel: "right", profileID: profile.id)

        if profile.channelMode == .stereo {
            let stereoActiveCount = leftCounts.active + rightCounts.active
            guard stereoActiveCount <= maxStereoActiveFilters else {
                throw ProfileStoreValidationError.tooManyStereoActiveFilters(
                    profileID: profile.id,
                    count: stereoActiveCount,
                    maximum: maxStereoActiveFilters
                )
            }

            let stereoFilterCount = leftCounts.total + rightCounts.total
            guard stereoFilterCount <= maxStereoFilters else {
                throw ProfileStoreValidationError.tooManyStereoFilters(
                    profileID: profile.id,
                    count: stereoFilterCount,
                    maximum: maxStereoFilters
                )
            }
        }

        if let expectedBandCount = graphicBandCount(for: profile.mode) {
            switch profile.channelMode {
            case .linked:
                try validateGraphicBandCount(
                    linkedCounts.active,
                    channel: "linked",
                    expected: expectedBandCount,
                    profileID: profile.id
                )
            case .stereo:
                try validateGraphicBandCount(
                    leftCounts.active,
                    channel: "left",
                    expected: expectedBandCount,
                    profileID: profile.id
                )
                try validateGraphicBandCount(
                    rightCounts.active,
                    channel: "right",
                    expected: expectedBandCount,
                    profileID: profile.id
                )
            }
        }
    }

    private static func validateFilters(
        _ filters: [EQFilter],
        channel: String,
        profileID: UUID
    ) throws -> (active: Int, total: Int) {
        var activeCount = 0

        for filter in filters {
            try validate(filter.frequency, in: frequencyRange, field: "frequency", profileID: profileID)
            try validate(filter.gainDB, in: gainRange, field: "gain", profileID: profileID)
            try validate(filter.q, in: qRange, field: "Q", profileID: profileID)

            if filter.isEnabled {
                activeCount += 1
            }
        }

        guard activeCount <= maxActiveFiltersPerChannel else {
            throw ProfileStoreValidationError.tooManyActiveFilters(
                profileID: profileID,
                channel: channel,
                count: activeCount,
                maximum: maxActiveFiltersPerChannel
            )
        }

        guard filters.count <= maxFiltersPerChannel else {
            throw ProfileStoreValidationError.tooManyFilters(
                profileID: profileID,
                channel: channel,
                count: filters.count,
                maximum: maxFiltersPerChannel
            )
        }

        return (activeCount, filters.count)
    }

    private static func validate(_ value: Double, in range: ClosedRange<Double>, field: String, profileID: UUID) throws {
        guard value.isFinite, range.contains(value) else {
            throw ProfileStoreValidationError.valueOutOfRange(
                profileID: profileID,
                field: field,
                value: value,
                range: range
            )
        }
    }

    private static func validateGraphicBandCount(
        _ count: Int,
        channel: String,
        expected: Int,
        profileID: UUID
    ) throws {
        guard count == expected else {
            throw ProfileStoreValidationError.invalidGraphicBandCount(
                profileID: profileID,
                channel: channel,
                count: count,
                expected: expected
            )
        }
    }

    private static func graphicBandCount(for mode: EQMode) -> Int? {
        switch mode {
        case .parametric:
            return nil
        case .graphic10:
            return 10
        case .graphic31:
            return 31
        }
    }

    private static func repairInvalidDecodedStore(
        _ decodedStore: ProfileStore,
        initialRepairSummary: ProfileStoreRepairSummary,
        at url: URL,
        timestamp: Date
    ) -> ProfileStoreLoadResult {
        var store = decodedStore
        var summary = initialRepairSummary
        let backupURL = uniqueInvalidStoreBackupURL(for: url, timestamp: timestamp)

        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
        } catch {
            return ProfileStoreLoadResult(store: defaultStore(), status: .backupFailed)
        }

        let profileCountBeforeRepair = store.profiles.count
        var seenProfileIDs = Set<UUID>()
        store.profiles = store.profiles.filter { profile in
            guard seenProfileIDs.insert(profile.id).inserted else {
                return false
            }
            return (try? validate(profile)) != nil
        }
        summary.removedInvalidProfiles += profileCountBeforeRepair - store.profiles.count

        if store.profiles.isEmpty {
            let defaultStore = defaultStore()
            do {
                try save(defaultStore, to: url)
                return ProfileStoreLoadResult(store: defaultStore, status: .recoveredDefaults(backupURL: backupURL))
            } catch {
                return ProfileStoreLoadResult(store: defaultStore, status: .backupFailed)
            }
        }

        if store.profiles.count > profileCountRange.upperBound {
            summary.removedInvalidProfiles += store.profiles.count - profileCountRange.upperBound
            store.profiles = Array(store.profiles.prefix(profileCountRange.upperBound))
        }

        let mappingCountBeforeLengthRepair = store.outputMappings.count
        store.outputMappings.removeAll { mapping in
            mapping.outputDeviceUID.utf8.count > maxOutputUIDUTF8Bytes
        }
        summary.removedOutputMappings += mappingCountBeforeLengthRepair - store.outputMappings.count

        if store.outputMappings.count > outputMappingCountRange.upperBound {
            summary.removedOutputMappings += store.outputMappings.count - outputMappingCountRange.upperBound
            store.outputMappings = Array(store.outputMappings.prefix(outputMappingCountRange.upperBound))
        }

        summary.merge(store.repairReferences())

        do {
            try validate(store)
            try save(store, to: url)
            return ProfileStoreLoadResult(store: store, status: .repairedInvalidStore(backupURL: backupURL, summary))
        } catch {
            let defaultStore = defaultStore()
            do {
                try save(defaultStore, to: url)
                return ProfileStoreLoadResult(store: defaultStore, status: .recoveredDefaults(backupURL: backupURL))
            } catch {
                return ProfileStoreLoadResult(store: defaultStore, status: .backupFailed)
            }
        }
    }

    private static func recoverInvalidStore(at url: URL, timestamp: Date) -> ProfileStoreLoadResult {
        let store = defaultStore()
        let backupURL = uniqueInvalidStoreBackupURL(for: url, timestamp: timestamp)

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: backupURL)
        } catch {
            return ProfileStoreLoadResult(store: store, status: .backupFailed)
        }

        try? save(store, to: url)
        return ProfileStoreLoadResult(store: store, status: .recoveredDefaults(backupURL: backupURL))
    }

    private static func uniqueInvalidStoreBackupURL(for storeURL: URL, timestamp: Date) -> URL {
        let first = invalidStoreBackupURL(for: storeURL, timestamp: timestamp)
        guard FileManager.default.fileExists(atPath: first.path) else {
            return first
        }

        let directory = first.deletingLastPathComponent()
        let baseName = first.deletingPathExtension().lastPathComponent
        let pathExtension = first.pathExtension
        for index in 2...999 {
            let candidateName = pathExtension.isEmpty
                ? "\(baseName)-\(index)"
                : "\(baseName)-\(index).\(pathExtension)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent(UUID().uuidString + "-" + first.lastPathComponent)
    }

    private static func defaultStore() -> ProfileStore {
        ProfileStore(
            profiles: ProfileStore.defaultProfiles,
            fallbackProfileID: ProfileStore.defaultProfiles.first?.id
        )
    }

    private static func storeByteCount(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    private static func timestampString(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }
}
