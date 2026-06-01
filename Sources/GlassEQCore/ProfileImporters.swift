import Foundation

public struct ProfileImportLimits: Equatable, Sendable {
    public var maxUTF8Bytes: Int
    public var maxLineCount: Int
    public var maxFiltersPerChannel: Int
    public var maxTotalFilters: Int
    public var frequencyRange: ClosedRange<Double>
    public var gainRange: ClosedRange<Double>
    public var preampRange: ClosedRange<Double>
    public var qRange: ClosedRange<Double>

    public init(
        maxUTF8Bytes: Int,
        maxLineCount: Int,
        maxFiltersPerChannel: Int,
        maxTotalFilters: Int,
        frequencyRange: ClosedRange<Double>,
        gainRange: ClosedRange<Double>,
        preampRange: ClosedRange<Double>,
        qRange: ClosedRange<Double>
    ) {
        self.maxUTF8Bytes = maxUTF8Bytes
        self.maxLineCount = maxLineCount
        self.maxFiltersPerChannel = maxFiltersPerChannel
        self.maxTotalFilters = maxTotalFilters
        self.frequencyRange = frequencyRange
        self.gainRange = gainRange
        self.preampRange = preampRange
        self.qRange = qRange
    }

    public static let `default` = ProfileImportLimits(
        maxUTF8Bytes: 1_048_576,
        maxLineCount: 10_000,
        maxFiltersPerChannel: 128,
        maxTotalFilters: 256,
        frequencyRange: 1...96_000,
        gainRange: -120...120,
        preampRange: -120...120,
        qRange: 0.01...100
    )
}

public enum ProfileImportError: Error, Equatable, Sendable, LocalizedError {
    case noSupportedFilters
    case inputTooLarge(byteCount: Int, maximum: Int)
    case tooManyLines(lineCount: Int, maximum: Int)
    case invalidNumber(line: Int, field: String, value: String)
    case missingNumber(line: Int, field: String)
    case valueOutOfRange(line: Int, field: String, value: Double, range: ClosedRange<Double>)
    case tooManyFilters(line: Int, channel: String, count: Int, maximum: Int)
    case tooManyTotalFilters(line: Int, count: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .noSupportedFilters:
            return "No supported filters were found in the imported profile."
        case let .inputTooLarge(byteCount, maximum):
            return "Imported profile is \(byteCount) UTF-8 bytes, which exceeds the \(maximum)-byte limit."
        case let .tooManyLines(lineCount, maximum):
            return "Imported profile has \(lineCount) lines, which exceeds the \(maximum)-line limit."
        case let .invalidNumber(line, field, value):
            return "Line \(line) has an invalid \(field) value: \(value)."
        case let .missingNumber(line, field):
            return "Line \(line) is missing a numeric \(field) value."
        case let .valueOutOfRange(line, field, value, range):
            return "Line \(line) has \(field) \(format(value)), outside the allowed range \(format(range.lowerBound))...\(format(range.upperBound))."
        case let .tooManyFilters(line, channel, count, maximum):
            return "Line \(line) adds filter \(count) to \(channel), which exceeds the \(maximum)-filter channel limit."
        case let .tooManyTotalFilters(line, count, maximum):
            return "Line \(line) adds filter \(count), which exceeds the \(maximum)-filter total limit."
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

public enum EQProfileTextImporter {
    private enum ImportChannel {
        case linked
        case left
        case right
    }

    public static func importAutoEQ(
        _ text: String,
        profileName: String = "Imported AutoEQ",
        limits: ProfileImportLimits = .default
    ) throws -> EQProfile {
        try validateInput(text, limits: limits)

        var filters: [EQFilter] = []
        var leftFilters: [EQFilter] = []
        var rightFilters: [EQFilter] = []
        var preampDB = 0.0
        var leftPreampDB: Double?
        var rightPreampDB: Double?
        var currentChannel = ImportChannel.linked

        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            let tokens = line
                .replacingOccurrences(of: ":", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)

            if tokens.first?.caseInsensitiveCompare("Channel") == .orderedSame,
               let channel = tokens.dropFirst().first {
                switch channel.uppercased() {
                case "L", "LEFT":
                    currentChannel = .left
                case "R", "RIGHT":
                    currentChannel = .right
                default:
                    currentChannel = .linked
                }
                continue
            }

            if tokens.first?.caseInsensitiveCompare("Preamp") == .orderedSame,
               let value = try requiredValue(after: "Preamp", in: tokens, field: "preamp", line: lineNumber) {
                try validate(value, in: limits.preampRange, field: "preamp", line: lineNumber)
                switch currentChannel {
                case .linked:
                    preampDB = value
                case .left:
                    leftPreampDB = value
                case .right:
                    rightPreampDB = value
                }
                continue
            }

            guard tokens.first?.caseInsensitiveCompare("Filter") == .orderedSame else {
                continue
            }

            let isEnabled = !tokens.contains { $0.caseInsensitiveCompare("OFF") == .orderedSame }
            guard isEnabled,
                  let kindToken = value(afterAnyOf: ["ON", "OFF"], in: tokens),
                  let kind = parseEqualizerAPOKind(kindToken) else {
                continue
            }

            guard let frequency = try requiredValue(afterAnyOf: ["Fc", "F"], in: tokens, field: "frequency", line: lineNumber) else {
                throw ProfileImportError.missingNumber(line: lineNumber, field: "frequency")
            }
            try validate(frequency, in: limits.frequencyRange, field: "frequency", line: lineNumber)

            let gain = try optionalValue(after: "Gain", in: tokens, field: "gain", line: lineNumber) ?? 0
            try validate(gain, in: limits.gainRange, field: "gain", line: lineNumber)

            let q = try optionalValue(after: "Q", in: tokens, field: "Q", line: lineNumber) ?? 0.707_106_781_18
            try validate(q, in: limits.qRange, field: "Q", line: lineNumber)

            let filter = EQFilter(kind: kind, frequency: frequency, gainDB: gain, q: q)
            switch currentChannel {
            case .linked:
                try append(
                    filter,
                    to: &filters,
                    channelName: "linked",
                    line: lineNumber,
                    limits: limits,
                    totalFilterCount: totalFilterCount(filters: filters, leftFilters: leftFilters, rightFilters: rightFilters)
                )
            case .left:
                try append(
                    filter,
                    to: &leftFilters,
                    channelName: "left",
                    line: lineNumber,
                    limits: limits,
                    totalFilterCount: totalFilterCount(filters: filters, leftFilters: leftFilters, rightFilters: rightFilters)
                )
            case .right:
                try append(
                    filter,
                    to: &rightFilters,
                    channelName: "right",
                    line: lineNumber,
                    limits: limits,
                    totalFilterCount: totalFilterCount(filters: filters, leftFilters: leftFilters, rightFilters: rightFilters)
                )
            }
        }

        let hasStereoFilters = !leftFilters.isEmpty || !rightFilters.isEmpty
        guard !filters.isEmpty || hasStereoFilters || preampDB != 0 || leftPreampDB != nil || rightPreampDB != nil else {
            throw ProfileImportError.noSupportedFilters
        }

        if hasStereoFilters {
            let fallbackFilters = filters
            return EQProfile(
                name: profileName,
                mode: .parametric,
                channelMode: .stereo,
                preampDB: preampDB,
                filters: fallbackFilters,
                leftPreampDB: leftPreampDB ?? preampDB,
                leftFilters: leftFilters.isEmpty ? fallbackFilters : leftFilters,
                rightPreampDB: rightPreampDB ?? preampDB,
                rightFilters: rightFilters.isEmpty ? fallbackFilters : rightFilters
            )
        }

        return EQProfile(name: profileName, mode: .parametric, preampDB: preampDB, filters: filters)
    }

    public static func importREW(
        _ text: String,
        profileName: String = "Imported REW",
        limits: ProfileImportLimits = .default
    ) throws -> EQProfile {
        try validateInput(text, limits: limits)

        var filters: [EQFilter] = []

        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("*") else {
                continue
            }

            let tokens = line
                .replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)

            guard tokens.first?.caseInsensitiveCompare("Filter") == .orderedSame else {
                continue
            }

            let enabled = !tokens.contains { $0.caseInsensitiveCompare("None") == .orderedSame }
            guard enabled else {
                continue
            }

            let kind = tokens.contains { $0.caseInsensitiveCompare("PK") == .orderedSame || $0.caseInsensitiveCompare("Modal") == .orderedSame }
                ? FilterKind.peak
                : FilterKind.peak

            guard let frequency = try requiredValue(afterAnyOf: ["Fc", "F"], in: tokens, field: "frequency", line: lineNumber) ??
                firstNumberFollowingFrequencyUnit(in: tokens, line: lineNumber) else {
                throw ProfileImportError.missingNumber(line: lineNumber, field: "frequency")
            }
            try validate(frequency, in: limits.frequencyRange, field: "frequency", line: lineNumber)

            let gain = try value(beforeUnit: "dB", in: tokens, field: "gain", line: lineNumber) ?? 0
            try validate(gain, in: limits.gainRange, field: "gain", line: lineNumber)

            let q = try optionalValue(after: "Q", in: tokens, field: "Q", line: lineNumber) ??
                lastNumericToken(in: tokens, field: "Q", line: lineNumber) ??
                0.707_106_781_18
            try validate(q, in: limits.qRange, field: "Q", line: lineNumber)

            try append(
                EQFilter(kind: kind, frequency: frequency, gainDB: gain, q: q),
                to: &filters,
                channelName: "linked",
                line: lineNumber,
                limits: limits,
                totalFilterCount: filters.count
            )
        }

        guard !filters.isEmpty else {
            throw ProfileImportError.noSupportedFilters
        }

        return EQProfile(name: profileName, mode: .parametric, filters: filters)
    }

    private static func parseEqualizerAPOKind(_ token: String) -> FilterKind? {
        switch token.uppercased() {
        case "PK", "PEQ":
            return .peak
        case "LS", "LSC":
            return .lowShelf
        case "HS", "HSC":
            return .highShelf
        case "HP", "HPQ":
            return .highPass
        case "LP", "LPQ":
            return .lowPass
        default:
            return nil
        }
    }

    private static func optionalValue(after label: String, in tokens: [String], field: String, line: Int) throws -> Double? {
        guard let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else {
            return nil
        }
        guard tokens.indices.contains(index + 1) else {
            throw ProfileImportError.missingNumber(line: line, field: field)
        }

        return try parseNumber(tokens[index + 1], field: field, line: line)
    }

    private static func requiredValue(after label: String, in tokens: [String], field: String, line: Int) throws -> Double? {
        if let value = try optionalValue(after: label, in: tokens, field: field, line: line) {
            return value
        }
        return try firstNumericToken(in: tokens.dropFirst(), field: field, line: line)
    }

    private static func requiredValue(afterAnyOf labels: [String], in tokens: [String], field: String, line: Int) throws -> Double? {
        for label in labels {
            if let value = try optionalValue(after: label, in: tokens, field: field, line: line) {
                return value
            }
        }
        return nil
    }

    private static func value(afterAnyOf labels: [String], in tokens: [String]) -> String? {
        for label in labels {
            if let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }),
               tokens.indices.contains(index + 1) {
                return tokens[index + 1]
            }
        }
        return nil
    }

    private static func value(beforeUnit unit: String, in tokens: [String], field: String, line: Int) throws -> Double? {
        guard let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(unit) == .orderedSame }),
              index > tokens.startIndex else {
            return nil
        }
        return try parseNumber(tokens[index - 1], field: field, line: line)
    }

    private static func firstNumberFollowingFrequencyUnit(in tokens: [String], line: Int) throws -> Double? {
        guard let unitIndex = tokens.firstIndex(where: { $0.caseInsensitiveCompare("Hz") == .orderedSame }),
              unitIndex > tokens.startIndex else {
            return nil
        }
        return try parseNumber(tokens[unitIndex - 1], field: "frequency", line: line)
    }

    private static func firstNumericToken<S: Sequence>(in tokens: S, field: String, line: Int) throws -> Double? where S.Element == String {
        for token in tokens {
            if let value = Double(token) {
                guard value.isFinite else {
                    throw ProfileImportError.invalidNumber(line: line, field: field, value: token)
                }
                return value
            }
        }
        return nil
    }

    private static func lastNumericToken(in tokens: [String], field: String, line: Int) throws -> Double? {
        for token in tokens.reversed() {
            if let value = Double(token) {
                guard value.isFinite else {
                    throw ProfileImportError.invalidNumber(line: line, field: field, value: token)
                }
                return value
            }
        }
        return nil
    }

    private static func parseNumber(_ token: String, field: String, line: Int) throws -> Double {
        guard let value = Double(token), value.isFinite else {
            throw ProfileImportError.invalidNumber(line: line, field: field, value: token)
        }
        return value
    }

    private static func validate(_ value: Double, in range: ClosedRange<Double>, field: String, line: Int) throws {
        guard value.isFinite else {
            throw ProfileImportError.invalidNumber(line: line, field: field, value: String(value))
        }
        guard range.contains(value) else {
            throw ProfileImportError.valueOutOfRange(line: line, field: field, value: value, range: range)
        }
    }

    private static func validateInput(_ text: String, limits: ProfileImportLimits) throws {
        let byteCount = text.utf8.count
        guard byteCount <= limits.maxUTF8Bytes else {
            throw ProfileImportError.inputTooLarge(byteCount: byteCount, maximum: limits.maxUTF8Bytes)
        }

        let lineCount = lineCount(in: text)
        guard lineCount <= limits.maxLineCount else {
            throw ProfileImportError.tooManyLines(lineCount: lineCount, maximum: limits.maxLineCount)
        }
    }

    private static func lineCount(in text: String) -> Int {
        guard !text.isEmpty else {
            return 0
        }

        let newlineCount = text.reduce(0) { count, character in
            character.isNewline ? count + 1 : count
        }
        return text.last?.isNewline == true ? newlineCount : newlineCount + 1
    }

    private static func append(
        _ filter: EQFilter,
        to filters: inout [EQFilter],
        channelName: String,
        line: Int,
        limits: ProfileImportLimits,
        totalFilterCount: Int
    ) throws {
        let channelCount = filters.count + 1
        guard channelCount <= limits.maxFiltersPerChannel else {
            throw ProfileImportError.tooManyFilters(
                line: line,
                channel: channelName,
                count: channelCount,
                maximum: limits.maxFiltersPerChannel
            )
        }

        let totalCount = totalFilterCount + 1
        guard totalCount <= limits.maxTotalFilters else {
            throw ProfileImportError.tooManyTotalFilters(line: line, count: totalCount, maximum: limits.maxTotalFilters)
        }

        filters.append(filter)
    }

    private static func totalFilterCount(
        filters: [EQFilter],
        leftFilters: [EQFilter],
        rightFilters: [EQFilter]
    ) -> Int {
        filters.count + leftFilters.count + rightFilters.count
    }
}

public enum EQProfileTextExporter {
    public static func exportEqualizerAPO(_ profile: EQProfile) -> String {
        var lines: [String] = []

        switch profile.channelMode {
        case .linked:
            lines.append(String(format: "Preamp: %.2f dB", profile.preampDB))
            lines.append(contentsOf: filterLines(profile.filters))
        case .stereo:
            lines.append(String(format: "Preamp: %.2f dB", profile.preampDB))
            lines.append("")
            lines.append("Channel: L")
            if profile.leftPreampDB != profile.preampDB {
                lines.append(String(format: "Preamp: %.2f dB", profile.leftPreampDB))
            }
            lines.append(contentsOf: filterLines(profile.leftFilters))
            lines.append("")
            lines.append("Channel: R")
            if profile.rightPreampDB != profile.preampDB {
                lines.append(String(format: "Preamp: %.2f dB", profile.rightPreampDB))
            }
            lines.append(contentsOf: filterLines(profile.rightFilters))
        }

        return lines.joined(separator: "\n")
    }

    private static func filterLines(_ filters: [EQFilter]) -> [String] {
        filters.enumerated().map { index, filter in
            String(
                format: "Filter %d: %@ %@ Fc %.1f Hz Gain %.2f dB Q %.2f",
                index + 1,
                filter.isEnabled ? "ON" : "OFF",
                equalizerAPOKind(filter.kind),
                filter.frequency,
                filter.gainDB,
                filter.q
            )
        }
    }

    private static func equalizerAPOKind(_ kind: FilterKind) -> String {
        switch kind {
        case .peak:
            "PK"
        case .lowShelf:
            "LS"
        case .highShelf:
            "HS"
        case .highPass:
            "HP"
        case .lowPass:
            "LP"
        }
    }
}
