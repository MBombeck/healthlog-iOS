#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **MIRROR (1.5, #152, server #1272)** — the app writes exactly the rows
    /// the server marks with `appleHealthMirror`, and falls back to its own
    /// source rule only where the key is missing.
    ///
    /// The planner is fed a fake Health state (no Health database in CI), as in
    /// `HealthKitServerMirrorDedupTests`.
    @Suite("Server mirror flag: the server decides per row (#152)")
    struct ServerMirrorFlagTests {
        private static let instant = Date(timeIntervalSince1970: 1_762_000_000)

        /// Server ids already stamped on a Health sample; everything authorized.
        private struct FakeHealth {
            var stampedIDs: Set<String> = []

            var probe: HealthKitServerMirrorProbe {
                let stamped = stampedIDs
                return HealthKitServerMirrorProbe(
                    isShareAuthorized: { _ in true },
                    existsWithExternalIDs: { ids, _ in !stamped.isDisjoint(with: ids) },
                    ownSamplesNear: { _, _ in [] }
                )
            }
        }

        private func weight(id: String, source: MeasurementSource, flag: Bool?) -> HealthLog.Measurement {
            var row = HealthLog.Measurement(
                id: id,
                kind: .weight,
                recordedAt: Self.instant,
                value: .scalar(81.4),
                source: source
            )
            row.appleHealthMirror = flag
            return row
        }

        private func decodeWire(_ json: String) throws -> MeasurementWireDTO {
            try JSONDecoder.hlDefault.decode(MeasurementWireDTO.self, from: Data(json.utf8))
        }

        private func wireJSON(source: String, flag: String?) -> String {
            let flagField = flag.map { #","appleHealthMirror":\#($0)"# } ?? ""
            return #"{"id":"m1","type":"WEIGHT","value":80.5,"unit":"kg","measuredAt":"2026-11-03T06:30:00.000Z","source":"\#(source)","externalId":null\#(flagField)}"#
        }

        // MARK: - Decode by key presence

        @Test("the key decodes as written: true, false, and absent is nil, never false")
        func decodesByKeyPresence() throws {
            #expect(try decodeWire(wireJSON(source: "EXTERNAL", flag: "true")).appleHealthMirror == true)
            #expect(try decodeWire(wireJSON(source: "WITHINGS", flag: "false")).appleHealthMirror == false)
            #expect(try decodeWire(wireJSON(source: "WITHINGS", flag: nil)).appleHealthMirror == nil)
        }

        @Test("a malformed or null flag costs the flag, never the row")
        func malformedFlagKeepsTheRow() throws {
            let null = try decodeWire(wireJSON(source: "IMPORT", flag: "null"))
            #expect(null.appleHealthMirror == nil)
            let text = try decodeWire(wireJSON(source: "IMPORT", flag: #""yes""#))
            #expect(text.appleHealthMirror == nil)
            #expect(text.value == 80.5)
        }

        @Test("the flag reaches the domain row, and a merged blood pressure keeps the stricter answer")
        func flagReachesTheDomainRow() throws {
            let wire = try decodeWire(wireJSON(source: "EXTERNAL", flag: "true"))
            #expect(wire.toDomain()?.appleHealthMirror == true)

            func half(_ id: String, _ type: ServerMeasurementType, _ flag: Bool?) -> MeasurementWireDTO {
                var row = MeasurementWireDTO(id: id, type: type, value: 120, measuredAt: Self.instant, source: .external)
                row.appleHealthMirror = flag
                return row
            }
            struct Pair {
                let sys: Bool?
                let dia: Bool?
                let expected: Bool?
            }
            let cases = [
                Pair(sys: true, dia: true, expected: true), Pair(sys: true, dia: false, expected: false),
                Pair(sys: false, dia: true, expected: false), Pair(sys: true, dia: nil, expected: true),
                Pair(sys: nil, dia: false, expected: false), Pair(sys: nil, dia: nil, expected: nil)
            ]
            for pair in cases {
                let (sys, dia, expected) = (pair.sys, pair.dia, pair.expected)
                let merged = MeasurementAggregator.mergeBloodPressure([
                    half("s", .bloodPressureSystolic, sys),
                    half("d", .bloodPressureDiastolic, dia)
                ])
                #expect(merged.count == 1)
                #expect(merged.first?.appleHealthMirror == expected, "sys \(String(describing: sys)) dia \(String(describing: dia))")
            }
        }

        @Test("a list page cached by 1.4.1 (no flag) still decodes, and the flag survives the cache")
        func cachedRowsFromOlderBuildsDecode() throws {
            // The SWR cache stores `[Measurement]`. A 1.4.1 entry has no key.
            let cached = #"[{"id":"w1","kind":"weight","recordedAt":783000000,"value":{"scalar":81.4},"source":"withings"}]"#
            let rows = try JSONDecoder().decode([HealthLog.Measurement].self, from: Data(cached.utf8))
            #expect(rows.first?.appleHealthMirror == nil)
            #expect(rows.first?.isServerMirrorAllowed == true)

            let flagged = weight(id: "x1", source: .external, flag: true)
            let roundTripped = try JSONDecoder().decode(
                HealthLog.Measurement.self,
                from: JSONEncoder().encode(flagged)
            )
            #expect(roundTripped.appleHealthMirror == true)
        }

        // MARK: - The five cases from #152

        @Test("(a1) a row with appleHealthMirror true and source EXTERNAL is written")
        func externalOptedInIsWritten() async {
            let row = weight(id: "ext-1", source: .external, flag: true)
            #expect(HealthKitService.shouldMirrorFromServer(row))
            let plan = await HealthKitServerMirrorPlanner.plan([row], excluding: [], probe: FakeHealth().probe)
            #expect(plan.rowCount == 1)
            #expect(plan.samples.first?.metadata?[HKMetadataKeyExternalUUID] as? String == "ext-1")
        }

        @Test("(a2) a row with appleHealthMirror false and source WITHINGS is not written")
        func serverFalseWinsOverTheSource() async {
            let row = weight(id: "wi-1", source: .withings, flag: false)
            #expect(!HealthKitService.shouldMirrorFromServer(row))
            let plan = await HealthKitServerMirrorPlanner.plan([row], excluding: [], probe: FakeHealth().probe)
            #expect(plan.samples.isEmpty)
        }

        @Test("(a3) without the key the source rule decides, for every source", arguments: [
            MeasurementSource.manual, .appleHealth, .withings, .whoop, .fitbit, .googleHealth, .computed,
            .strava, .oura, .polar, .nightscout, .healthConnect, .garmin, .telegram, .mcp, .external,
            .import_, .unknown
        ])
        func missingKeyFallsBackToTheSourceRule(source: MeasurementSource) {
            let row = weight(id: "row", source: source, flag: nil)
            #expect(row.isServerMirrorAllowed == source.isServerMirrorEligible)
            #expect(HealthKitService.shouldMirrorFromServer(row) == source.isServerMirrorEligible)
        }

        @Test("(a4) an old server's answer to appleHealthMirror=true with APPLE_HEALTH rows writes none of them")
        func oldServerAppleHealthRowsAreNeverWritten() async throws {
            // A server before 1.46.0 ignores the filter and drops nothing: every
            // source comes back, and no row carries the key.
            let page = #"""
            {"measurements":[
              {"id":"ah-1","type":"WEIGHT","value":80.1,"measuredAt":"2026-11-03T06:30:00.000Z","source":"APPLE_HEALTH"},
              {"id":"ah-2","type":"PULSE","value":61,"measuredAt":"2026-11-03T06:31:00.000Z","source":"APPLE_HEALTH"},
              {"id":"ah-3","type":"BLOOD_PRESSURE_SYS","value":121,"measuredAt":"2026-11-03T06:32:00.000Z","source":"APPLE_HEALTH"},
              {"id":"ah-4","type":"BLOOD_PRESSURE_DIA","value":79,"measuredAt":"2026-11-03T06:32:00.000Z","source":"APPLE_HEALTH"}
            ]}
            """#
            let response = try JSONDecoder.hlDefault.decode(MeasurementListWireResponse.self, from: Data(page.utf8))
            let rows = MeasurementAggregator.mergeBloodPressure(response.measurements)
            #expect(rows.count == 3)
            #expect(rows.allSatisfy { $0.appleHealthMirror == nil })
            let plan = await HealthKitServerMirrorPlanner.plan(rows, excluding: [], probe: FakeHealth().probe)
            #expect(plan.samples.isEmpty)

            // Even a flag that said true would not write an Apple Health row back.
            let flagged = weight(id: "ah-5", source: .appleHealth, flag: true)
            #expect(!flagged.isServerMirrorAllowed)
        }

        @Test("(a5) a row that turns false deletes nothing in Apple Health")
        func turningFalseDeletesNothing() async throws {
            // Written earlier, now switched off: the plan simply leaves it alone.
            let health = FakeHealth(stampedIDs: ["ext-2"])
            let row = weight(id: "ext-2", source: .external, flag: false)
            let plan = await HealthKitServerMirrorPlanner.plan([row], excluding: [], probe: health.probe)
            #expect(plan.objects.isEmpty)
            #expect(plan.linkageIDs.isEmpty)

            // And no mirror path owns a delete call at all.
            for path in [
                "HealthLog/Services/HealthKit/HealthKitServerMirrorPlanner.swift",
                "HealthLog/Services/HealthKit/ServerMirrorBackgroundPass.swift",
                "HealthLog/Models/Measurement+MirrorPolicy.swift",
                "HealthLog/Models/MeasurementDTO+MirrorFlag.swift"
            ] {
                let source = try Self.source(path)
                #expect(!source.contains(".delete("), "\(path) must never delete from Apple Health")
            }
        }

        @Test("a blood pressure with a zero half is never written")
        func halfPairIsNeverWritten() {
            var lone = HealthLog.Measurement(
                id: "s1",
                kind: .bloodPressure,
                recordedAt: Self.instant,
                value: .bloodPressure(systolic: 124, diastolic: 0),
                source: .external
            )
            lone.appleHealthMirror = true
            #expect(!HealthKitService.shouldMirrorFromServer(lone))
        }

        private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
            let root = URL(fileURLWithPath: file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        }
    }
#endif
