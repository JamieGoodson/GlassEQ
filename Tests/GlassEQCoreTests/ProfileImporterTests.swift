import GlassEQCore
import Testing

@Suite
struct ProfileImporterTests {
    @Test
    func importsEqualizerAPOText() throws {
        let text = """
        Preamp: -5.4 dB
        Filter 1: ON PK Fc 105 Hz Gain -2.1 dB Q 1.41
        Filter 2: ON LS Fc 80 Hz Gain 3.0 dB Q 0.70
        """

        let profile = try EQProfileTextImporter.importAutoEQ(text)

        #expect(profile.preampDB == -5.4)
        #expect(profile.filters.count == 2)
        #expect(profile.filters[0].kind == .peak)
        #expect(profile.filters[0].frequency == 105)
        #expect(profile.filters[0].gainDB == -2.1)
        #expect(profile.filters[1].kind == .lowShelf)
    }

    @Test
    func ignoresDisabledEqualizerAPOFilters() throws {
        let text = """
        Filter 1: OFF PK Fc 1000 Hz Gain 6 dB Q 1
        Filter 2: ON PK Fc 2000 Hz Gain 3 dB Q 1
        """

        let profile = try EQProfileTextImporter.importAutoEQ(text)

        #expect(profile.filters.count == 1)
        #expect(profile.filters[0].frequency == 2_000)
    }

    @Test
    func importsEqualizerAPOChannelSectionsAsStereoProfile() throws {
        let text = """
        Preamp: -5.96 dB

        Channel: L
        Filter 1:  ON  PK  Fc 37 Hz  Gain 6 dB  Q 1
        Filter 2:  ON  PK  Fc 47 Hz  Gain -16.7 dB  Q 5

        Channel: R
        Filter 1:  ON  PK  Fc 61 Hz  Gain 2.7 dB  Q 7.5
        Filter 2:  ON  PK  Fc 67 Hz  Gain -6.8 dB  Q 5
        """

        let profile = try EQProfileTextImporter.importAutoEQ(text)

        #expect(profile.channelMode == EQChannelMode.stereo)
        #expect(profile.preampDB == -5.96)
        #expect(profile.leftPreampDB == -5.96)
        #expect(profile.rightPreampDB == -5.96)
        #expect(profile.filters.isEmpty)
        #expect(profile.leftFilters.count == 2)
        #expect(profile.rightFilters.count == 2)
        #expect(profile.leftFilters[0].frequency == 37)
        #expect(profile.leftFilters[1].gainDB == -16.7)
        #expect(profile.rightFilters[0].frequency == 61)
        #expect(profile.rightFilters[1].q == 5)
    }

    @Test
    func importsREWText() throws {
        let text = """
        Filter 1: ON PK Fc 45.0 Hz Gain -4.5 dB Q 3.20
        Filter 2: ON PK Fc 120.0 Hz Gain 2.0 dB Q 1.10
        """

        let profile = try EQProfileTextImporter.importREW(text)

        #expect(profile.filters.count == 2)
        #expect(profile.filters[0].frequency == 45)
        #expect(profile.filters[0].gainDB == -4.5)
        #expect(profile.filters[0].q == 3.2)
    }

    @Test
    func importsREWFrequencyImmediatelyBeforeHz() throws {
        let profile = try EQProfileTextImporter.importREW("Filter 1: ON PK 45.0 Hz Gain -4.5 dB Q 3.20")

        #expect(profile.filters.count == 1)
        #expect(profile.filters[0].frequency == 45)
    }

    @Test
    func importsREWFrequencyAfterFLabel() throws {
        let profile = try EQProfileTextImporter.importREW("Filter 1: ON PK F 45.0 Hz Gain -4.5 dB Q 3.20")

        #expect(profile.filters.count == 1)
        #expect(profile.filters[0].frequency == 45)
    }

    @Test
    func rejectsREWBareNumericFilterLineAsMissingFrequency() throws {
        let text = "Filter 1: ON PK 45.0 Gain -4.5 dB Q 3.20"

        do {
            _ = try EQProfileTextImporter.importREW(text)
            Issue.record("Expected missing REW frequency to fail")
        } catch let error as ProfileImportError {
            #expect(error == .missingNumber(line: 1, field: "frequency"))
        }
    }

    @Test
    func rejectsAutoEQBareFrequencyWithoutFcOrF() throws {
        let text = "Filter 1: ON PK 45.0 Hz Gain -4.5 dB Q 3.20"

        do {
            _ = try EQProfileTextImporter.importAutoEQ(text)
            Issue.record("Expected missing AutoEQ frequency to fail")
        } catch let error as ProfileImportError {
            #expect(error == .missingNumber(line: 1, field: "frequency"))
        }
    }

    @Test
    func rejectsInputOverUTF8ByteLimit() throws {
        var limits = ProfileImportLimits.default
        limits.maxUTF8Bytes = 8

        do {
            _ = try EQProfileTextImporter.importAutoEQ("Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1", limits: limits)
            Issue.record("Expected oversized input to fail")
        } catch let error as ProfileImportError {
            #expect(error == .inputTooLarge(byteCount: 39, maximum: 8))
            #expect(error.errorDescription?.contains("UTF-8 bytes") == true)
        }
    }

    @Test
    func rejectsInputOverLineLimit() throws {
        var limits = ProfileImportLimits.default
        limits.maxLineCount = 2

        do {
            _ = try EQProfileTextImporter.importAutoEQ("one\ntwo\nthree", limits: limits)
            Issue.record("Expected line limit to fail")
        } catch let error as ProfileImportError {
            #expect(error == .tooManyLines(lineCount: 3, maximum: 2))
        }
    }

    @Test
    func rejectsAutoEQNumericFieldsOutsideLimitsWithLineNumber() throws {
        let text = """
        Preamp: -3 dB
        Filter 1: ON PK Fc 97000 Hz Gain 0 dB Q 1
        """

        do {
            _ = try EQProfileTextImporter.importAutoEQ(text)
            Issue.record("Expected frequency limit to fail")
        } catch let error as ProfileImportError {
            #expect(error == .valueOutOfRange(line: 2, field: "frequency", value: 97_000, range: 1...96_000))
            #expect(error.errorDescription?.contains("Line 2") == true)
        }
    }

    @Test
    func rejectsREWInvalidNumericFieldWithLineNumber() throws {
        let text = "Filter 1: ON PK Fc nope Hz Gain 0 dB Q 1"

        do {
            _ = try EQProfileTextImporter.importREW(text)
            Issue.record("Expected invalid frequency to fail")
        } catch let error as ProfileImportError {
            #expect(error == .invalidNumber(line: 1, field: "frequency", value: "nope"))
        }
    }

    @Test
    func enforcesPerChannelFilterLimit() throws {
        var limits = ProfileImportLimits.default
        limits.maxFiltersPerChannel = 1
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1
        Filter 2: ON PK Fc 200 Hz Gain 0 dB Q 1
        """

        do {
            _ = try EQProfileTextImporter.importAutoEQ(text, limits: limits)
            Issue.record("Expected per-channel filter limit to fail")
        } catch let error as ProfileImportError {
            #expect(error == .tooManyFilters(line: 2, channel: "linked", count: 2, maximum: 1))
        }
    }

    @Test
    func enforcesTotalFilterLimitAcrossStereoChannels() throws {
        var limits = ProfileImportLimits.default
        limits.maxFiltersPerChannel = 4
        limits.maxTotalFilters = 2
        let text = """
        Channel: L
        Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1
        Filter 2: ON PK Fc 200 Hz Gain 0 dB Q 1
        Channel: R
        Filter 1: ON PK Fc 300 Hz Gain 0 dB Q 1
        """

        do {
            _ = try EQProfileTextImporter.importAutoEQ(text, limits: limits)
            Issue.record("Expected total filter limit to fail")
        } catch let error as ProfileImportError {
            #expect(error == .tooManyTotalFilters(line: 5, count: 3, maximum: 2))
        }
    }
}
