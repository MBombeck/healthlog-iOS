#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    @testable import HealthLog
    import Testing

    // swiftlint:disable force_unwrapping

    /// 1.5 FIX-DATA (#126) — a `value_out_of_range` skip carries, since server
    /// v1.39.1, the value after conversion into the stored unit and the band that
    /// refused it (`entries[].convertedValue`, `entries[].range`). The list of
    /// refused readings shows both; without them it keeps the general sentence.
    @MainActor
    @Suite("Refused readings — converted value and band")
    struct SkippedRefusalDetailTests {
        private static let owner = "user-126"

        /// The deployed route's answer for one body-fat fraction sent as 0.9.
        private static let withDetail = Data(#"""
        {"processed":1,"inserted":0,"duplicates":0,
         "skipped":[{"index":0,"reason":"value_out_of_range"}],
         "entries":[{"index":0,"status":"skipped","reason":"value_out_of_range",
                     "convertedValue":90,"range":{"min":1,"max":80,"unit":"%"}}]}
        """#.utf8)

        /// An older server: the same skip, no detail.
        private static let withoutDetail = Data(#"""
        {"processed":1,"inserted":0,"duplicates":0,
         "skipped":[{"index":0,"reason":"value_out_of_range"}],
         "entries":[{"index":0,"status":"skipped","reason":"value_out_of_range"}]}
        """#.utf8)

        private static func reoffer(answer: Data, register: HealthKitSkippedRowRegister) -> HealthKitSkippedRowReoffer {
            HealthKitSkippedRowReoffer(register: register) { entries in
                let response = try JSONDecoder().decode(HealthKitBatchResponseDTO.self, from: answer)
                return [BatchUploadOutcome(chunk: entries, response: response)]
            }
        }

        private static func refusedRow(answer: Data) async throws -> HealthKitSkippedRow {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let entry = SkipFixture.entry("fat-1", type: "HKQuantityTypeIdentifierBodyFatPercentage", value: 0.9)
            try await register.record(
                [HealthKitSkippedEntry(entry: entry, reason: MeasurementBatchAcceptance.Reason.valueOutOfRange)],
                ownerID: owner,
                build: "299"
            )
            _ = await reoffer(answer: answer, register: register).run(ownerID: owner, build: "300", force: true)
            return try #require(await register.rows(ownerID: owner).first)
        }

        @Test("the entry decodes convertedValue and range; a malformed detail never costs the entry")
        func entryDecodesDetail() throws {
            let response = try JSONDecoder().decode(HealthKitBatchResponseDTO.self, from: Self.withDetail)
            #expect(response.entries.first?.convertedValue == 90)
            #expect(response.entries.first?.range == HealthKitValueRange(min: 1, max: 80, unit: "%"))

            let malformed = Data(#"""
            {"entries":[{"index":0,"status":"skipped","reason":"value_out_of_range",
                         "convertedValue":"ninety","range":{"min":1}}]}
            """#.utf8)
            let tolerant = try JSONDecoder().decode(HealthKitBatchResponseDTO.self, from: malformed)
            #expect(tolerant.entries.first?.status == .skipped)
            #expect(tolerant.entries.first?.convertedValue == nil)
            #expect(tolerant.entries.first?.range == nil)
        }

        @Test("(d) with detail the list shows the converted value and the band")
        func detailIsShown() async throws {
            let row = try await Self.refusedRow(answer: Self.withDetail)
            let detail = try #require(row.detail)
            #expect(detail.convertedValue == 90)
            #expect(detail.range == HealthKitValueRange(min: 1, max: 80, unit: "%"))

            let text = SettingsHKSkippedRowsScreen.reasonText(row)
            let value = SettingsHKSkippedRowsScreen.bandText(90, unit: "%")
            let low = SettingsHKSkippedRowsScreen.bandText(1, unit: "%")
            let high = SettingsHKSkippedRowsScreen.bandText(80, unit: "%")
            #expect(text == String(localized: "settings.hkdiag.skipped_reason_out_of_range_detail \(value) \(low) \(high)"))
            #expect(text.contains(value) && text.contains(high))
            #expect(text != SettingsHKSkippedRowsScreen.reasonText(row.reason))
        }

        @Test("(d) without detail the list keeps the general sentence")
        func noDetailKeepsSentence() async throws {
            let row = try await Self.refusedRow(answer: Self.withoutDetail)
            #expect(row.detail == nil)
            #expect(
                SettingsHKSkippedRowsScreen.reasonText(row)
                    == String(localized: "settings.hkdiag.skipped_reason_out_of_range")
            )
        }

        @Test("only a band, or only a value, still says what it knows")
        func partialDetail() {
            let entry = SkipFixture.entry("p-1", type: "HKQuantityTypeIdentifierHeartRate", value: 12)
            func row(_ detail: HealthKitRefusalDetail?) -> HealthKitSkippedRow {
                HealthKitSkippedRow(
                    ownerID: Self.owner, entry: entry, reason: MeasurementBatchAcceptance.Reason.valueOutOfRange,
                    detail: detail, firstSkippedAt: .now, lastAttemptAt: .now, attempts: 1, lastOfferedBuild: "300"
                )
            }
            let band = HealthKitValueRange(min: 20, max: 300, unit: "bpm")
            let bandOnly = SettingsHKSkippedRowsScreen.reasonText(row(HealthKitRefusalDetail(convertedValue: nil, range: band)))
            #expect(bandOnly == String(localized: "settings.hkdiag.skipped_reason_out_of_range_band \("20 bpm") \("300 bpm")"))
            let valueOnly = SettingsHKSkippedRowsScreen.reasonText(row(HealthKitRefusalDetail(convertedValue: 12, range: nil)))
            #expect(valueOnly == String(localized: "settings.hkdiag.skipped_reason_out_of_range_value \("12")"))
            #expect(HealthKitRefusalDetail(convertedValue: nil, range: nil) == nil)
        }

        @Test("(e) a register file written by 1.4.1 (no detail) still lists its rows")
        func registerFileFrom141Decodes() async throws {
            let entry = SkipFixture.entry("spo2-141", value: 0.42)
            let entryJSON = try #require(try String(data: JSONEncoder().encode(entry), encoding: .utf8))
            // The 1.4.1 `HealthKitSkippedRow` keys, verbatim; the register encodes
            // with a plain `JSONEncoder` (dates as seconds since 2001).
            let file = """
            {"version":1,"overflow":{},"rows":[{"ownerID":"\(Self.owner)","entry":\(entryJSON),
            "reason":"value_out_of_range","firstSkippedAt":800000000,"lastAttemptAt":800000100,
            "attempts":2,"lastOfferedBuild":"299"}]}
            """
            let stored = Data(file.utf8)
            let register = HealthKitSkippedRowRegister(storage: HealthKitSkippedRowStorage(load: { stored }, save: { _ in }))

            let rows = await register.rows(ownerID: Self.owner)

            let row = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(row.entry == entry)
            #expect(row.detail == nil)
            #expect(row.attempts == 2)
            #expect(
                SettingsHKSkippedRowsScreen.reasonText(row)
                    == String(localized: "settings.hkdiag.skipped_reason_out_of_range")
            )
        }
    }

    // swiftlint:enable force_unwrapping
#endif
