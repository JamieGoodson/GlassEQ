import Foundation
import GlassEQCore
import Testing

@Suite
struct ProfilePersistenceTests {
    private let timestamp = Date(timeIntervalSince1970: 1_704_067_200)

    @Test
    func loadBacksUpValidationInvalidStoreAndWritesDefaults() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let invalidStore = ProfileStore(
            profiles: [EQProfile(name: "", mode: .parametric, filters: [])],
            fallbackProfileID: UUID()
        )
        let invalidData = try ProfilePersistence.encoder.encode(invalidStore)
        try invalidData.write(to: url)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        guard case .recoveredDefaults(let backupURL) = result.status else {
            Issue.record("Expected invalid store recovery, got \(result.status)")
            return
        }
        #expect(result.store.profiles == ProfileStore.defaultProfiles)
        #expect(try Data(contentsOf: backupURL) == invalidData)

        let savedStore = try ProfilePersistence.decode(Data(contentsOf: url))
        #expect(savedStore.profiles == ProfileStore.defaultProfiles)
    }

    @Test
    func loadLeavesInvalidOriginalUntouchedWhenBackupFails() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let invalidData = Data("not json".utf8)
        try invalidData.write(to: url)
        let backupURL = ProfilePersistence.invalidStoreBackupURL(for: url, timestamp: timestamp)
        let collisionData = Data("existing backup".utf8)
        try collisionData.write(to: backupURL)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        #expect(result.status == .backupFailed)
        #expect(result.store.profiles == ProfileStore.defaultProfiles)
        #expect(try Data(contentsOf: url) == invalidData)
        #expect(try Data(contentsOf: backupURL) == collisionData)
    }

    @Test
    func loadBacksUpOversizedStoreBeforeDecode() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let oversizedData = Data(repeating: 0, count: ProfilePersistence.maxStoreBytes + 1)
        try oversizedData.write(to: url)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        guard case .recoveredDefaults(let backupURL) = result.status else {
            Issue.record("Expected oversized store recovery, got \(result.status)")
            return
        }
        #expect((try Data(contentsOf: backupURL)).count == oversizedData.count)
        #expect(try ProfilePersistence.decode(Data(contentsOf: url)).profiles == ProfileStore.defaultProfiles)
    }

    @Test
    func loadRepairsReferencesAndSavesRepairedStore() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let first = EQProfile(name: "First", mode: .parametric, filters: [])
        let second = EQProfile(name: "Second", mode: .parametric, filters: [])
        let missingProfileID = UUID()
        let store = ProfileStore(
            profiles: [first, second],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: "", profileID: first.id),
                OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: missingProfileID),
                OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: first.id),
                OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: second.id)
            ],
            fallbackProfileID: missingProfileID
        )
        try ProfilePersistence.encoder.encode(store).write(to: url)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        guard case .repairedReferences(let summary) = result.status else {
            Issue.record("Expected repaired references, got \(result.status)")
            return
        }
        #expect(summary.repairedFallbackProfileID)
        #expect(summary.removedOutputMappings == 2)
        #expect(summary.deduplicatedOutputMappings == 1)
        #expect(result.store.outputMappings == [
            OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: second.id)
        ])

        let savedStore = try ProfilePersistence.decode(Data(contentsOf: url))
        #expect(savedStore == result.store)
    }

    @Test
    func decodeRejectsProfileStoreOutsideSizeLimit() throws {
        let oversizedData = Data(repeating: 0, count: ProfilePersistence.maxStoreBytes + 1)

        do {
            _ = try ProfilePersistence.decode(oversizedData)
            Issue.record("Expected oversized profile store to fail")
        } catch let error as ProfileStoreValidationError {
            #expect(error == .inputTooLarge(
                byteCount: oversizedData.count,
                maximum: ProfilePersistence.maxStoreBytes
            ))
        }
    }

    @Test
    func decodeRejectsProfileStoreValidationFailures() throws {
        try expectValidationFailure(
            ProfileStore(profiles: [], fallbackProfileID: UUID()),
            expected: .invalidProfileCount(count: 0, allowed: ProfilePersistence.profileCountRange)
        )

        let profile = EQProfile(name: "Valid", mode: .parametric, filters: [])
        let missingFallbackID = UUID()
        try expectValidationFailure(
            ProfileStore(profiles: [profile], fallbackProfileID: missingFallbackID),
            expected: .missingFallbackProfile(profileID: missingFallbackID)
        )

        let tooManyMappings = (0...ProfilePersistence.outputMappingCountRange.upperBound).map {
            OutputDeviceProfileMapping(outputDeviceUID: "output-\($0)", profileID: EQProfile.flatParametric.id)
        }
        try expectValidationFailure(
            ProfileStore(outputMappings: tooManyMappings),
            expected: .invalidOutputMappingCount(
                count: ProfilePersistence.outputMappingCountRange.upperBound + 1,
                allowed: ProfilePersistence.outputMappingCountRange
            )
        )

        let longNameProfile = EQProfile(
            name: String(repeating: "a", count: ProfilePersistence.maxProfileNameUTF8Bytes + 1),
            mode: .parametric,
            filters: []
        )
        try expectValidationFailure(
            ProfileStore(profiles: [longNameProfile], fallbackProfileID: longNameProfile.id),
            expected: .profileNameTooLong(
                profileID: longNameProfile.id,
                byteCount: ProfilePersistence.maxProfileNameUTF8Bytes + 1,
                maximum: ProfilePersistence.maxProfileNameUTF8Bytes
            )
        )

        try expectValidationFailure(
            ProfileStore(outputMappings: [
                OutputDeviceProfileMapping(
                    outputDeviceUID: String(repeating: "u", count: ProfilePersistence.maxOutputUIDUTF8Bytes + 1),
                    profileID: ProfileStore.defaultProfiles[0].id
                )
            ]),
            expected: .outputUIDTooLong(
                mappingIndex: 0,
                byteCount: ProfilePersistence.maxOutputUIDUTF8Bytes + 1,
                maximum: ProfilePersistence.maxOutputUIDUTF8Bytes
            )
        )
    }

    @Test
    func saveRejectsInvalidStoreAndLeavesExistingFileUntouched() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let validProfile = EQProfile(name: "Valid", mode: .parametric, filters: [])
        let validStore = ProfileStore(profiles: [validProfile], fallbackProfileID: validProfile.id)
        try ProfilePersistence.save(validStore, to: url)
        let originalData = try Data(contentsOf: url)

        let missingFallbackID = UUID()
        let invalidStore = ProfileStore(profiles: [validProfile], fallbackProfileID: missingFallbackID)

        #expect(throws: ProfileStoreValidationError.missingFallbackProfile(profileID: missingFallbackID)) {
            try ProfilePersistence.save(invalidStore, to: url)
        }
        #expect(try Data(contentsOf: url) == originalData)
        #expect(try ProfilePersistence.decode(Data(contentsOf: url)) == validStore)
    }

    @Test
    func decodeRejectsInvalidFilterBoundsAndCounts() throws {
        let invalidFrequency = EQProfile(
            name: "Invalid Frequency",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 0, gainDB: 0, q: 1)]
        )
        try expectValidationFailure(
            ProfileStore(profiles: [invalidFrequency], fallbackProfileID: invalidFrequency.id),
            expected: .valueOutOfRange(
                profileID: invalidFrequency.id,
                field: "frequency",
                value: 0,
                range: ProfilePersistence.frequencyRange
            )
        )

        let tooManyFilters = EQProfile(
            name: "Too Many",
            mode: .parametric,
            filters: (0...ProfilePersistence.maxActiveFiltersPerChannel).map {
                EQFilter(kind: .peak, frequency: Double($0 + 1), gainDB: 0, q: 1)
            }
        )
        try expectValidationFailure(
            ProfileStore(profiles: [tooManyFilters], fallbackProfileID: tooManyFilters.id),
            expected: .tooManyActiveFilters(
                profileID: tooManyFilters.id,
                channel: "linked",
                count: ProfilePersistence.maxActiveFiltersPerChannel + 1,
                maximum: ProfilePersistence.maxActiveFiltersPerChannel
            )
        )
    }

    @Test
    func decodeRejectsGraphicProfilesWithoutExactActiveBandCount() throws {
        var filters = EQProfile.flatGraphic10.filters
        filters[0].isEnabled = false
        let profile = EQProfile(name: "Broken Graphic", mode: .graphic10, filters: filters)

        try expectValidationFailure(
            ProfileStore(profiles: [profile], fallbackProfileID: profile.id),
            expected: .invalidGraphicBandCount(
                profileID: profile.id,
                channel: "linked",
                count: 9,
                expected: 10
            )
        )
    }

    private func expectValidationFailure(
        _ store: ProfileStore,
        expected: ProfileStoreValidationError
    ) throws {
        do {
            _ = try ProfilePersistence.decode(ProfilePersistence.encoder.encode(store))
            Issue.record("Expected profile store validation to fail")
        } catch let error as ProfileStoreValidationError {
            #expect(error == expected)
        }
    }

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Profiles.json")
    }

    private func removeTemporaryStoreDirectory(for url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
