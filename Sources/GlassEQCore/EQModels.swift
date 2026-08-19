import Foundation

public enum EQMode: String, Codable, Sendable, CaseIterable {
    case parametric
    case graphic10
    case graphic31
}

public enum EQChannelMode: String, Codable, Sendable, CaseIterable {
    case linked
    case stereo
}

public enum FilterKind: String, Codable, Sendable, CaseIterable {
    case peak
    case lowShelf
    case highShelf
    case highPass
    case lowPass
}

public struct EQFilter: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: FilterKind
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        kind: FilterKind,
        frequency: Double,
        gainDB: Double = 0,
        q: Double = 0.707_106_781_18,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.isEnabled = isEnabled
    }
}

public struct EQProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var mode: EQMode
    public var channelMode: EQChannelMode
    public var preampDB: Double
    public var filters: [EQFilter]
    public var leftPreampDB: Double
    public var leftFilters: [EQFilter]
    public var rightPreampDB: Double
    public var rightFilters: [EQFilter]

    public init(
        id: UUID = UUID(),
        name: String,
        mode: EQMode,
        channelMode: EQChannelMode = .linked,
        preampDB: Double = 0,
        filters: [EQFilter],
        leftPreampDB: Double? = nil,
        leftFilters: [EQFilter]? = nil,
        rightPreampDB: Double? = nil,
        rightFilters: [EQFilter]? = nil
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.channelMode = channelMode
        self.preampDB = preampDB
        self.filters = filters
        self.leftPreampDB = leftPreampDB ?? preampDB
        self.leftFilters = leftFilters ?? filters
        self.rightPreampDB = rightPreampDB ?? preampDB
        self.rightFilters = rightFilters ?? filters
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mode
        case channelMode
        case preampDB
        case filters
        case leftPreampDB
        case leftFilters
        case rightPreampDB
        case rightFilters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mode = try container.decode(EQMode.self, forKey: .mode)
        channelMode = try container.decodeIfPresent(EQChannelMode.self, forKey: .channelMode) ?? .linked
        preampDB = try container.decode(Double.self, forKey: .preampDB)
        filters = try container.decode([EQFilter].self, forKey: .filters)
        leftPreampDB = try container.decodeIfPresent(Double.self, forKey: .leftPreampDB) ?? preampDB
        leftFilters = try container.decodeIfPresent([EQFilter].self, forKey: .leftFilters) ?? filters
        rightPreampDB = try container.decodeIfPresent(Double.self, forKey: .rightPreampDB) ?? preampDB
        rightFilters = try container.decodeIfPresent([EQFilter].self, forKey: .rightFilters) ?? filters
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mode, forKey: .mode)
        try container.encode(channelMode, forKey: .channelMode)
        try container.encode(preampDB, forKey: .preampDB)
        try container.encode(filters, forKey: .filters)
        try container.encode(leftPreampDB, forKey: .leftPreampDB)
        try container.encode(leftFilters, forKey: .leftFilters)
        try container.encode(rightPreampDB, forKey: .rightPreampDB)
        try container.encode(rightFilters, forKey: .rightFilters)
    }

    public static let flatParametric = EQProfile(
        name: "Flat",
        mode: .parametric,
        filters: []
    )

    public static let flatGraphic10 = EQProfile(
        name: "Flat 10-Band",
        mode: .graphic10,
        filters: GraphicEQBands.tenBand.map {
            EQFilter(kind: .peak, frequency: $0, gainDB: 0, q: GraphicEQBands.graphicQ)
        }
    )

    public static let flatGraphic31 = EQProfile(
        name: "Flat 31-Band",
        mode: .graphic31,
        filters: GraphicEQBands.thirtyOneBand.map {
            EQFilter(kind: .peak, frequency: $0, gainDB: 0, q: GraphicEQBands.graphicQ)
        }
    )
}

public enum GraphicEQBands {
    public static let graphicQ = 1.414_213_562_37

    public static let tenBand: [Double] = [
        31.25, 62.5, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]

    public static let thirtyOneBand: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100,
        125, 160, 200, 250, 315, 400, 500, 630, 800,
        1_000, 1_250, 1_600, 2_000, 2_500, 3_150, 4_000,
        5_000, 6_300, 8_000, 10_000, 12_500, 16_000, 20_000
    ]
}

public struct OutputDeviceProfileMapping: Codable, Equatable, Sendable {
    public var outputDeviceUID: String
    public var profileID: UUID

    public init(outputDeviceUID: String, profileID: UUID) {
        self.outputDeviceUID = outputDeviceUID
        self.profileID = profileID
    }
}

public struct ProfileStoreRepairSummary: Equatable, Sendable {
    public var migratedSchemaVersion: Bool
    public var restoredDefaultProfiles: Bool
    public var repairedFallbackProfileID: Bool
    public var removedOutputMappings: Int
    public var deduplicatedOutputMappings: Int
    public var removedBypassedOutputDeviceUIDs: Int
    public var deduplicatedBypassedOutputDeviceUIDs: Int
    public var removedInvalidProfiles: Int

    public var didRepair: Bool {
        migratedSchemaVersion ||
            restoredDefaultProfiles ||
            repairedFallbackProfileID ||
            removedOutputMappings > 0 ||
            deduplicatedOutputMappings > 0 ||
            removedBypassedOutputDeviceUIDs > 0 ||
            deduplicatedBypassedOutputDeviceUIDs > 0 ||
            removedInvalidProfiles > 0
    }

    public init(
        migratedSchemaVersion: Bool = false,
        restoredDefaultProfiles: Bool = false,
        repairedFallbackProfileID: Bool = false,
        removedOutputMappings: Int = 0,
        deduplicatedOutputMappings: Int = 0,
        removedBypassedOutputDeviceUIDs: Int = 0,
        deduplicatedBypassedOutputDeviceUIDs: Int = 0,
        removedInvalidProfiles: Int = 0
    ) {
        self.migratedSchemaVersion = migratedSchemaVersion
        self.restoredDefaultProfiles = restoredDefaultProfiles
        self.repairedFallbackProfileID = repairedFallbackProfileID
        self.removedOutputMappings = removedOutputMappings
        self.deduplicatedOutputMappings = deduplicatedOutputMappings
        self.removedBypassedOutputDeviceUIDs = removedBypassedOutputDeviceUIDs
        self.deduplicatedBypassedOutputDeviceUIDs = deduplicatedBypassedOutputDeviceUIDs
        self.removedInvalidProfiles = removedInvalidProfiles
    }

    mutating func merge(_ other: ProfileStoreRepairSummary) {
        migratedSchemaVersion = migratedSchemaVersion || other.migratedSchemaVersion
        restoredDefaultProfiles = restoredDefaultProfiles || other.restoredDefaultProfiles
        repairedFallbackProfileID = repairedFallbackProfileID || other.repairedFallbackProfileID
        removedOutputMappings += other.removedOutputMappings
        deduplicatedOutputMappings += other.deduplicatedOutputMappings
        removedBypassedOutputDeviceUIDs += other.removedBypassedOutputDeviceUIDs
        deduplicatedBypassedOutputDeviceUIDs += other.deduplicatedBypassedOutputDeviceUIDs
        removedInvalidProfiles += other.removedInvalidProfiles
    }
}

public struct ProfileStore: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let defaultProfiles: [EQProfile] = [.flatGraphic31, .flatGraphic10, .flatParametric]

    public var schemaVersion: Int
    public var profiles: [EQProfile]
    public var outputMappings: [OutputDeviceProfileMapping]
    public var isBypassed: Bool
    public var bypassedOutputDeviceUIDs: [String]
    public var fallbackProfileID: UUID

    public init(
        schemaVersion: Int = ProfileStore.currentSchemaVersion,
        profiles: [EQProfile] = ProfileStore.defaultProfiles,
        outputMappings: [OutputDeviceProfileMapping] = [],
        isBypassed: Bool = false,
        bypassedOutputDeviceUIDs: [String] = [],
        fallbackProfileID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.outputMappings = outputMappings
        self.isBypassed = isBypassed
        self.bypassedOutputDeviceUIDs = bypassedOutputDeviceUIDs
        self.fallbackProfileID = fallbackProfileID ?? profiles.first?.id ?? EQProfile.flatParametric.id
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profiles
        case outputMappings
        case isBypassed
        case bypassedOutputDeviceUIDs
        case fallbackProfileID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        profiles = try container.decode([EQProfile].self, forKey: .profiles)
        outputMappings = try container.decode([OutputDeviceProfileMapping].self, forKey: .outputMappings)
        isBypassed = try container.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
        bypassedOutputDeviceUIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .bypassedOutputDeviceUIDs
        ) ?? []
        fallbackProfileID = try container.decode(UUID.self, forKey: .fallbackProfileID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(outputMappings, forKey: .outputMappings)
        try container.encode(isBypassed, forKey: .isBypassed)
        try container.encode(bypassedOutputDeviceUIDs, forKey: .bypassedOutputDeviceUIDs)
        try container.encode(fallbackProfileID, forKey: .fallbackProfileID)
    }

    @discardableResult
    public mutating func repairReferences() -> ProfileStoreRepairSummary {
        var summary = ProfileStoreRepairSummary()

        if schemaVersion > 0, schemaVersion < Self.currentSchemaVersion {
            schemaVersion = Self.currentSchemaVersion
            summary.migratedSchemaVersion = true
        }

        if profiles.isEmpty {
            profiles = Self.defaultProfiles
            summary.restoredDefaultProfiles = true
        }

        let profileIDs = Set(profiles.map(\.id))
        if !profileIDs.contains(fallbackProfileID), let firstProfileID = profiles.first?.id {
            fallbackProfileID = firstProfileID
            summary.repairedFallbackProfileID = true
        }

        let mappingCountBeforeRemoval = outputMappings.count
        outputMappings.removeAll { mapping in
            mapping.outputDeviceUID.isEmpty || !profileIDs.contains(mapping.profileID)
        }
        summary.removedOutputMappings = mappingCountBeforeRemoval - outputMappings.count

        var seenOutputUIDs = Set<String>()
        var dedupedReversed: [OutputDeviceProfileMapping] = []
        for mapping in outputMappings.reversed() {
            if seenOutputUIDs.insert(mapping.outputDeviceUID).inserted {
                dedupedReversed.append(mapping)
            } else {
                summary.deduplicatedOutputMappings += 1
            }
        }
        outputMappings = dedupedReversed.reversed()

        let bypassCountBeforeRemoval = bypassedOutputDeviceUIDs.count
        bypassedOutputDeviceUIDs.removeAll(where: \.isEmpty)
        summary.removedBypassedOutputDeviceUIDs = bypassCountBeforeRemoval - bypassedOutputDeviceUIDs.count

        var seenBypassedOutputUIDs = Set<String>()
        bypassedOutputDeviceUIDs = bypassedOutputDeviceUIDs.filter { uid in
            if seenBypassedOutputUIDs.insert(uid).inserted {
                return true
            }
            summary.deduplicatedBypassedOutputDeviceUIDs += 1
            return false
        }

        return summary
    }

    public func profile(forOutputUID uid: String?) -> EQProfile {
        if let uid,
           let profileID = outputMappings.first(where: { $0.outputDeviceUID == uid })?.profileID,
           let profile = profiles.first(where: { $0.id == profileID }) {
            return profile
        }

        return profiles.first(where: { $0.id == fallbackProfileID }) ?? profiles.first ?? .flatParametric
    }

    public func bypassesOutputDevice(uid: String?) -> Bool {
        guard let uid, !uid.isEmpty else {
            return false
        }
        return bypassedOutputDeviceUIDs.contains(uid)
    }
}
