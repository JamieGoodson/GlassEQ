import Foundation
import GlassEQCore

public enum SettingsImportFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case autoEQ = "AutoEQ / EqualizerAPO"
    case rew = "REW"

    public var id: String { rawValue }
}

public enum SettingsProfileKind: String, Codable, Sendable {
    case graphic10
    case graphic31
    case parametric
}

public struct SettingsAudioMetricsDTO: Codable, Equatable, Sendable {
    public var capturedFrames: UInt64
    public var playedFrames: UInt64
    public var playbackUnderrunFrames: UInt64
    public var saturatedSamples: UInt64
    public var currentBufferedFrames: Int
    public var maxBufferedFrames: Int
    public var maximumPlaybackBufferedFrames: Int
    public var minimumPlaybackBufferedFrames: Int
    public var averagePlaybackBufferedFrames: Double
    public var playbackBufferObservations: UInt64
    public var maximumCaptureCallbackFrames: Int
    public var maximumPlaybackCallbackFrames: Int

    private enum CodingKeys: String, CodingKey {
        case capturedFrames
        case playedFrames
        case playbackUnderrunFrames
        case saturatedSamples
        case currentBufferedFrames
        case maxBufferedFrames
        case maximumPlaybackBufferedFrames
        case minimumPlaybackBufferedFrames
        case averagePlaybackBufferedFrames
        case playbackBufferObservations
        case maximumCaptureCallbackFrames
        case maximumPlaybackCallbackFrames
    }

    public init(
        capturedFrames: UInt64 = 0,
        playedFrames: UInt64 = 0,
        playbackUnderrunFrames: UInt64 = 0,
        saturatedSamples: UInt64 = 0,
        currentBufferedFrames: Int = 0,
        maxBufferedFrames: Int = 0,
        maximumPlaybackBufferedFrames: Int = 0,
        minimumPlaybackBufferedFrames: Int = 0,
        averagePlaybackBufferedFrames: Double = 0,
        playbackBufferObservations: UInt64 = 0,
        maximumCaptureCallbackFrames: Int = 0,
        maximumPlaybackCallbackFrames: Int = 0
    ) {
        self.capturedFrames = capturedFrames
        self.playedFrames = playedFrames
        self.playbackUnderrunFrames = playbackUnderrunFrames
        self.saturatedSamples = saturatedSamples
        self.currentBufferedFrames = currentBufferedFrames
        self.maxBufferedFrames = maxBufferedFrames
        self.maximumPlaybackBufferedFrames = maximumPlaybackBufferedFrames
        self.minimumPlaybackBufferedFrames = minimumPlaybackBufferedFrames
        self.averagePlaybackBufferedFrames = averagePlaybackBufferedFrames
        self.playbackBufferObservations = playbackBufferObservations
        self.maximumCaptureCallbackFrames = maximumCaptureCallbackFrames
        self.maximumPlaybackCallbackFrames = maximumPlaybackCallbackFrames
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            capturedFrames: try container.decodeIfPresent(UInt64.self, forKey: .capturedFrames) ?? 0,
            playedFrames: try container.decodeIfPresent(UInt64.self, forKey: .playedFrames) ?? 0,
            playbackUnderrunFrames: try container.decodeIfPresent(UInt64.self, forKey: .playbackUnderrunFrames) ?? 0,
            saturatedSamples: try container.decodeIfPresent(UInt64.self, forKey: .saturatedSamples) ?? 0,
            currentBufferedFrames: try container.decodeIfPresent(Int.self, forKey: .currentBufferedFrames) ?? 0,
            maxBufferedFrames: try container.decodeIfPresent(Int.self, forKey: .maxBufferedFrames) ?? 0,
            maximumPlaybackBufferedFrames: try container.decodeIfPresent(Int.self, forKey: .maximumPlaybackBufferedFrames) ?? 0,
            minimumPlaybackBufferedFrames: try container.decodeIfPresent(Int.self, forKey: .minimumPlaybackBufferedFrames) ?? 0,
            averagePlaybackBufferedFrames: try container.decodeIfPresent(Double.self, forKey: .averagePlaybackBufferedFrames) ?? 0,
            playbackBufferObservations: try container.decodeIfPresent(UInt64.self, forKey: .playbackBufferObservations) ?? 0,
            maximumCaptureCallbackFrames: try container.decodeIfPresent(Int.self, forKey: .maximumCaptureCallbackFrames) ?? 0,
            maximumPlaybackCallbackFrames: try container.decodeIfPresent(Int.self, forKey: .maximumPlaybackCallbackFrames) ?? 0
        )
    }
}

public struct SettingsOutputDTO: Codable, Equatable, Sendable {
    public var name: String
    public var uid: String
    public var sampleRate: Double
    public var channelCount: Int
    public var bufferFrameSize: UInt32

    public init(name: String, uid: String, sampleRate: Double, channelCount: Int, bufferFrameSize: UInt32) {
        self.name = name
        self.uid = uid
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bufferFrameSize = bufferFrameSize
    }
}

public enum SettingsOptionalUUIDPatchDTO: Codable, Equatable, Sendable {
    case set(UUID)
    case clear
}

public struct SettingsSnapshotPatchDTO: Codable, Equatable, Sendable {
    public var statusMessage: String?
    public var isPreviewing: Bool?
    public var selectedProfileID: UUID?
    public var draftProfile: EQProfile?
    public var activeProfileID: UUID?
    public var activeProfileName: String?
    public var fallbackProfileID: UUID?
    public var currentOutput: SettingsOutputDTO?
    public var currentOutputMappedProfileID: SettingsOptionalUUIDPatchDTO?

    public init(
        statusMessage: String? = nil,
        isPreviewing: Bool? = nil,
        selectedProfileID: UUID? = nil,
        draftProfile: EQProfile? = nil,
        activeProfileID: UUID? = nil,
        activeProfileName: String? = nil,
        fallbackProfileID: UUID? = nil,
        currentOutput: SettingsOutputDTO? = nil,
        currentOutputMappedProfileID: SettingsOptionalUUIDPatchDTO? = nil
    ) {
        self.statusMessage = statusMessage
        self.isPreviewing = isPreviewing
        self.selectedProfileID = selectedProfileID
        self.draftProfile = draftProfile
        self.activeProfileID = activeProfileID
        self.activeProfileName = activeProfileName
        self.fallbackProfileID = fallbackProfileID
        self.currentOutput = currentOutput
        self.currentOutputMappedProfileID = currentOutputMappedProfileID
    }
}

public struct SettingsSnapshotDTO: Codable, Equatable, Sendable {
    public var profiles: [EQProfile]
    public var selectedProfileID: UUID
    public var draftProfile: EQProfile
    public var activeProfileID: UUID
    public var activeProfileName: String
    public var currentOutputName: String
    public var currentOutputUID: String
    public var currentOutputSampleRate: Double
    public var currentOutputChannelCount: Int
    public var currentOutputBufferFrameSize: UInt32
    public var currentOutputMappedProfileID: UUID?
    public var fallbackProfileID: UUID
    public var statusMessage: String
    public var metrics: SettingsAudioMetricsDTO
    public var isPreviewing: Bool

    public init(
        profiles: [EQProfile],
        selectedProfileID: UUID,
        draftProfile: EQProfile,
        activeProfileID: UUID,
        activeProfileName: String,
        currentOutputName: String,
        currentOutputUID: String,
        currentOutputSampleRate: Double,
        currentOutputChannelCount: Int,
        currentOutputBufferFrameSize: UInt32,
        currentOutputMappedProfileID: UUID?,
        fallbackProfileID: UUID,
        statusMessage: String,
        metrics: SettingsAudioMetricsDTO,
        isPreviewing: Bool
    ) {
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.draftProfile = draftProfile
        self.activeProfileID = activeProfileID
        self.activeProfileName = activeProfileName
        self.currentOutputName = currentOutputName
        self.currentOutputUID = currentOutputUID
        self.currentOutputSampleRate = currentOutputSampleRate
        self.currentOutputChannelCount = currentOutputChannelCount
        self.currentOutputBufferFrameSize = currentOutputBufferFrameSize
        self.currentOutputMappedProfileID = currentOutputMappedProfileID
        self.fallbackProfileID = fallbackProfileID
        self.statusMessage = statusMessage
        self.metrics = metrics
        self.isPreviewing = isPreviewing
    }

    public static var disconnected: SettingsSnapshotDTO {
        let profile = EQProfile.flatGraphic31
        return SettingsSnapshotDTO(
            profiles: [profile],
            selectedProfileID: profile.id,
            draftProfile: profile,
            activeProfileID: profile.id,
            activeProfileName: profile.name,
            currentOutputName: "No output",
            currentOutputUID: "",
            currentOutputSampleRate: 0,
            currentOutputChannelCount: 0,
            currentOutputBufferFrameSize: 0,
            currentOutputMappedProfileID: nil,
            fallbackProfileID: profile.id,
            statusMessage: "Connecting to GlassEQ...",
            metrics: SettingsAudioMetricsDTO(),
            isPreviewing: false
        )
    }
}

public enum SettingsCommand: Codable, Equatable, Sendable {
    case createProfile(SettingsProfileKind)
    case duplicateProfile(UUID)
    case deleteProfile(UUID)
    case applyProfile(EQProfile)
    case useProfileForCurrentOutput(EQProfile)
    case setFallback(EQProfile)
    case importProfile(format: SettingsImportFormat, name: String, text: String)
    case preview(EQProfile)
    case stopPreview
    case resetDiagnostics
    case retryAudioEngine
    case openPrivacySettings
    case startMetricsPolling
    case stopMetricsPolling
}

public struct SettingsCommandResponse: Codable, Equatable, Sendable {
    public var snapshot: SettingsSnapshotDTO?
    public var importSucceeded: Bool?

    public init(snapshot: SettingsSnapshotDTO? = nil, importSucceeded: Bool? = nil) {
        self.snapshot = snapshot
        self.importSucceeded = importSucceeded
    }
}

public struct SettingsCommandFailure: Codable, Equatable, Error, LocalizedError, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum SettingsEvent: Codable, Equatable, Sendable {
    case snapshotChanged(SettingsSnapshotDTO)
    case snapshotPatched(SettingsSnapshotPatchDTO)
    case metricsChanged(SettingsAudioMetricsDTO)
    case commandFailed(SettingsCommandFailure)
    case focusRequested
    case shutdown
}

public enum SettingsPipeRequestKind: String, Codable, Equatable, Sendable {
    case connect
    case command
    case disconnect
}

public enum SettingsPipeMessage: Codable, Equatable, Sendable {
    case request(sessionToken: String, id: String, kind: SettingsPipeRequestKind, command: SettingsCommand?)
    case response(sessionToken: String, id: String, response: SettingsCommandResponse?, error: String?)
    case event(sessionToken: String, event: SettingsEvent)

    public var sessionToken: String {
        switch self {
        case .request(let sessionToken, _, _, _),
             .response(let sessionToken, _, _, _),
             .event(let sessionToken, _):
            sessionToken
        }
    }

    public func validateSessionToken(_ expected: String) throws {
        guard sessionToken == expected else {
            throw SettingsPipeError.sessionTokenMismatch
        }
    }
}

public enum SettingsPipeError: Error, Equatable, LocalizedError, Sendable {
    case sessionTokenMismatch
    case frameTooLarge(byteCount: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .sessionTokenMismatch:
            return "Settings IPC session was invalid."
        case let .frameTooLarge(byteCount, maximum):
            return "Settings IPC frame is \(byteCount) bytes, which exceeds the \(maximum)-byte limit."
        }
    }
}

public enum SettingsPipeCodec {
    public static let maximumLineBytes = 8 * 1_024 * 1_024

    public static func encodeLine(
        _ message: SettingsPipeMessage,
        maximumLineBytes: Int = Self.maximumLineBytes
    ) throws -> Data {
        var data = try SettingsPipeJSONCodec.encoder.encode(message)
        guard data.count + 1 <= maximumLineBytes else {
            throw SettingsPipeError.frameTooLarge(byteCount: data.count + 1, maximum: maximumLineBytes)
        }
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ data: Data) throws -> SettingsPipeMessage {
        try SettingsPipeJSONCodec.decoder.decode(SettingsPipeMessage.self, from: data)
    }
}

public struct SettingsPipeLineBuffer: Sendable {
    public private(set) var bufferedByteCount: Int = 0

    private let maximumLineBytes: Int
    private var buffer = Data()

    public init(maximumLineBytes: Int = SettingsPipeCodec.maximumLineBytes) {
        self.maximumLineBytes = maximumLineBytes
    }

    public mutating func append(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else {
            return []
        }

        buffer.append(chunk)
        bufferedByteCount = buffer.count

        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newlineIndex]
            guard line.count + 1 <= maximumLineBytes else {
                throw SettingsPipeError.frameTooLarge(byteCount: line.count + 1, maximum: maximumLineBytes)
            }
            if !line.isEmpty {
                lines.append(Data(line))
            }
            buffer.removeSubrange(...newlineIndex)
        }

        bufferedByteCount = buffer.count
        guard bufferedByteCount <= maximumLineBytes else {
            throw SettingsPipeError.frameTooLarge(byteCount: bufferedByteCount, maximum: maximumLineBytes)
        }

        return lines
    }

    public mutating func removeAll(keepingCapacity: Bool = false) {
        buffer.removeAll(keepingCapacity: keepingCapacity)
        bufferedByteCount = 0
    }
}

public actor SettingsPipeLineDecoder {
    private var buffer: SettingsPipeLineBuffer

    public init(maximumLineBytes: Int = SettingsPipeCodec.maximumLineBytes) {
        self.buffer = SettingsPipeLineBuffer(maximumLineBytes: maximumLineBytes)
    }

    public func append(_ chunk: Data) throws -> [SettingsPipeMessage] {
        let lines = try buffer.append(chunk)
        return try lines.map(SettingsPipeCodec.decodeLine)
    }

    public func removeAll(keepingCapacity: Bool = false) {
        buffer.removeAll(keepingCapacity: keepingCapacity)
    }
}

enum SettingsPipeJSONCodec {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}
