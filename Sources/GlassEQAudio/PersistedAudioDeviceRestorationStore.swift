import Foundation

struct PersistedAudioDeviceRestorationRecord: Codable, Equatable, Sendable {
    var uid: String
    var originalSampleRate: Double?
    var originalBufferFrameSize: UInt32?

    var isEmpty: Bool {
        originalSampleRate == nil && originalBufferFrameSize == nil
    }
}

enum PersistedAudioDeviceRestorationStore {
    static func defaultURL(
        applicationSupportDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("GlassEQ", isDirectory: true)
            .appendingPathComponent("DeviceRestorations.json", isDirectory: false)
    }

    static func load(from url: URL) -> [String: PersistedAudioDeviceRestorationRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([PersistedAudioDeviceRestorationRecord].self, from: data) else {
            return [:]
        }
        var recordsByUID: [String: PersistedAudioDeviceRestorationRecord] = [:]
        for record in records {
            guard !record.uid.isEmpty else {
                continue
            }
            if var existing = recordsByUID[record.uid] {
                if existing.originalSampleRate == nil {
                    existing.originalSampleRate = record.originalSampleRate
                }
                if existing.originalBufferFrameSize == nil {
                    existing.originalBufferFrameSize = record.originalBufferFrameSize
                }
                recordsByUID[record.uid] = existing
            } else {
                recordsByUID[record.uid] = record
            }
        }
        return recordsByUID
    }

    static func save(_ recordsByUID: [String: PersistedAudioDeviceRestorationRecord], to url: URL) throws {
        let records = recordsByUID.values
            .filter { !$0.isEmpty }
            .sorted { $0.uid < $1.uid }
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func recordSampleRate(uid: String, originalSampleRate: Double, at url: URL) throws {
        var records = load(from: url)
        var record = records[uid] ?? PersistedAudioDeviceRestorationRecord(uid: uid)
        if record.originalSampleRate == nil {
            record.originalSampleRate = originalSampleRate
        }
        records[uid] = record
        try save(records, to: url)
    }

    static func recordBufferFrameSize(uid: String, originalFrameSize: UInt32, at url: URL) throws {
        var records = load(from: url)
        var record = records[uid] ?? PersistedAudioDeviceRestorationRecord(uid: uid)
        if record.originalBufferFrameSize == nil {
            record.originalBufferFrameSize = originalFrameSize
        }
        records[uid] = record
        try save(records, to: url)
    }

    static func clearSampleRate(uid: String, at url: URL) throws {
        try update(uid: uid, at: url) { $0.originalSampleRate = nil }
    }

    static func clearBufferFrameSize(uid: String, at url: URL) throws {
        try update(uid: uid, at: url) { $0.originalBufferFrameSize = nil }
    }

    private static func update(
        uid: String,
        at url: URL,
        mutation: (inout PersistedAudioDeviceRestorationRecord) -> Void
    ) throws {
        var records = load(from: url)
        guard var record = records[uid] else {
            return
        }
        mutation(&record)
        records[uid] = record.isEmpty ? nil : record
        try save(records, to: url)
    }
}
