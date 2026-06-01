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
    case recoveredDefaults(backupURL: URL)
    case backupFailed
}

public enum ProfileStoreValidationError: Error, Equatable, Sendable, LocalizedError {
    case inputTooLarge(byteCount: Int, maximum: Int)
    case invalidProfileCount(count: Int, allowed: ClosedRange<Int>)
    case invalidOutputMappingCount(count: Int, allowed: ClosedRange<Int>)
    case missingFallbackProfile(profileID: UUID)
    case emptyProfileName(profileID: UUID)
    case profileNameTooLong(profileID: UUID, byteCount: Int, maximum: Int)
    case outputUIDTooLong(mappingIndex: Int, byteCount: Int, maximum: Int)
    case valueOutOfRange(profileID: UUID, field: String, value: Double, range: ClosedRange<Double>)
    case tooManyActiveFilters(profileID: UUID, channel: String, count: Int, maximum: Int)
    case tooManyStereoActiveFilters(profileID: UUID, count: Int, maximum: Int)
    case invalidGraphicBandCount(profileID: UUID, channel: String, count: Int, expected: Int)

    public var errorDescription: String? {
        switch self {
        case let .inputTooLarge(byteCount, maximum):
            return "Profile store is \(byteCount) bytes, which exceeds the \(maximum)-byte limit."
        case let .invalidProfileCount(count, allowed):
            return "Profile store has \(count) profiles; expected \(allowed.lowerBound)...\(allowed.upperBound)."
        case let .invalidOutputMappingCount(count, allowed):
            return "Profile store has \(count) output mappings; expected \(allowed.lowerBound)...\(allowed.upperBound)."
        case let .missingFallbackProfile(profileID):
            return "Profile store fallback profile \(profileID) does not exist."
        case .emptyProfileName:
            return "Profile store contains an empty profile name."
        case let .profileNameTooLong(_, byteCount, maximum):
            return "Profile store contains a profile name with \(byteCount) UTF-8 bytes, which exceeds the \(maximum)-byte limit."
        case let .outputUIDTooLong(mappingIndex, byteCount, maximum):
            return "Output mapping \(mappingIndex) has \(byteCount) UTF-8 bytes, which exceeds the \(maximum)-byte limit."
        case let .valueOutOfRange(_, field, value, range):
            return "Profile store contains \(field) \(format(value)), outside the allowed range \(format(range.lowerBound))...\(format(range.upperBound))."
        case let .tooManyActiveFilters(_, channel, count, maximum):
            return "Profile store contains \(count) active \(channel) filters, which exceeds the \(maximum)-filter channel limit."
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
    public static let maxProfileNameUTF8Bytes = 120
    public static let maxOutputUIDUTF8Bytes = 512
    public static let maxActiveFiltersPerChannel = 128
    public static let maxStereoActiveFilters = 256
    public static let frequencyRange: ClosedRange<Double> = 1...96_000
    public static let gainRange: ClosedRange<Double> = -120...120
    public static let preampRange: ClosedRange<Double> = -120...120
    public static let qRange: ClosedRange<Double> = 0.01...100

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public static let decoder = JSONDecoder()

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

        let profileIDs = Set(store.profiles.map(\.id))
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
    }

    public static func save(_ store: ProfileStore, to url: URL) throws {
        try validate(store)
        let data = try encode(store)
        try validateStoreSize(byteCount: data.count)
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

        do {
            let data = try Data(contentsOf: url)
            try validateStoreSize(byteCount: data.count)
            var store = try decodeRaw(data)
            let repairSummary = store.repairReferences()
            try validate(store)

            if repairSummary.didRepair {
                try save(store, to: url)
                return ProfileStoreLoadResult(store: store, status: .repairedReferences(repairSummary))
            }

            return ProfileStoreLoadResult(store: store, status: .loaded)
        } catch {
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

        let linkedActiveCount = try validateFilters(profile.filters, channel: "linked", profileID: profile.id)
        let leftActiveCount = try validateFilters(profile.leftFilters, channel: "left", profileID: profile.id)
        let rightActiveCount = try validateFilters(profile.rightFilters, channel: "right", profileID: profile.id)

        if profile.channelMode == .stereo {
            let stereoActiveCount = leftActiveCount + rightActiveCount
            guard stereoActiveCount <= maxStereoActiveFilters else {
                throw ProfileStoreValidationError.tooManyStereoActiveFilters(
                    profileID: profile.id,
                    count: stereoActiveCount,
                    maximum: maxStereoActiveFilters
                )
            }
        }

        if let expectedBandCount = graphicBandCount(for: profile.mode) {
            try validateGraphicBandCount(linkedActiveCount, channel: "linked", expected: expectedBandCount, profileID: profile.id)
            try validateGraphicBandCount(leftActiveCount, channel: "left", expected: expectedBandCount, profileID: profile.id)
            try validateGraphicBandCount(rightActiveCount, channel: "right", expected: expectedBandCount, profileID: profile.id)
        }
    }

    private static func validateFilters(_ filters: [EQFilter], channel: String, profileID: UUID) throws -> Int {
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

        return activeCount
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

    private static func recoverInvalidStore(at url: URL, timestamp: Date) -> ProfileStoreLoadResult {
        let store = defaultStore()
        let backupURL = invalidStoreBackupURL(for: url, timestamp: timestamp)

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: backupURL)
        } catch {
            return ProfileStoreLoadResult(store: store, status: .backupFailed)
        }

        try? save(store, to: url)
        return ProfileStoreLoadResult(store: store, status: .recoveredDefaults(backupURL: backupURL))
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
