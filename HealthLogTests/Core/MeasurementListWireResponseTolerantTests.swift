import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.6.2.1 — F3 regression lock. The drill-down "Alle Messungen
/// anzeigen" calls `GET /api/measurements?limit=400`, decoded as
/// `MeasurementListWireResponse`. Whenever the server's mixed-type page
/// carries a row whose `type` is not present in `ServerMeasurementType`
/// (e.g. `ACTIVITY_STEPS`, `SLEEP_DURATION`, `ACTIVE_ENERGY_BURNED`,
/// `FLIGHTS_CLIMBED`, `WALKING_RUNNING_DISTANCE`, `TIME_IN_DAYLIGHT`,
/// the Withings-only mass / vascular kinds), the whole array decode
/// blew up with `dataCorrupted` on the unknown enum case and the user
/// saw "Daten konnten nicht gelesen werden" plus an empty list.
///
/// These tests pin the tolerant contract: known rows survive, unknown
/// rows drop silently, `meta` round-trips.
@Suite("MeasurementListWireResponse — tolerant decode (F3)")
struct MeasurementListWireResponseTolerantTests {
    @Test("Known types decode unchanged")
    func knownTypesDecodeUnchanged() throws {
        let json = """
        {
          "measurements": [
            {
              "id": "row-1",
              "type": "WEIGHT",
              "value": 72.4,
              "measuredAt": "2026-05-24T08:00:00Z"
            },
            {
              "id": "row-2",
              "type": "PULSE",
              "value": 68,
              "measuredAt": "2026-05-24T08:01:00Z"
            }
          ],
          "meta": { "total": 2, "limit": 400, "offset": 0 }
        }
        """
        let response = try JSONDecoder.hlDefault.decode(
            MeasurementListWireResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.measurements.count == 2)
        #expect(response.measurements[0].type == .weight)
        #expect(response.measurements[1].type == .pulse)
        #expect(response.meta?.total == 2)
    }

    @Test("Genuinely-unknown server type drops the row, keeps the rest")
    func unknownTypeDropsRowKeepsRest() throws {
        // ACTIVITY_STEPS is the operator's reported case (845 entries on
        // the Steps drill-down) — but it is now a *known* type for this
        // page only via the series route, so we use a synthetic
        // server-only type to exercise the tolerant-drop path without
        // coupling to whichever enum cases iOS has caught up on.
        let json = """
        {
          "measurements": [
            {
              "id": "row-known-1",
              "type": "WEIGHT",
              "value": 72.4,
              "measuredAt": "2026-05-24T08:00:00Z"
            },
            {
              "id": "row-future",
              "type": "FUTURE_SERVER_ONLY_TYPE",
              "value": 8421,
              "measuredAt": "2026-05-24T09:00:00Z"
            },
            {
              "id": "row-known-2",
              "type": "PULSE",
              "value": 68,
              "measuredAt": "2026-05-24T08:01:00Z"
            }
          ],
          "meta": { "total": 3, "limit": 400, "offset": 0 }
        }
        """
        let response = try JSONDecoder.hlDefault.decode(
            MeasurementListWireResponse.self,
            from: Data(json.utf8)
        )
        // Two known rows survive; the one genuinely-unknown enum case drops.
        #expect(response.measurements.count == 2)
        #expect(response.measurements.map(\.id).sorted() == ["row-known-1", "row-known-2"])
        // meta still round-trips — the count reflects the wire's claim,
        // not what iOS rendered.
        #expect(response.meta?.total == 3)
    }

    /// v0.11 marathon regression lock. SLEEP_DURATION + five sibling
    /// read-types (RESPIRATORY_RATE, AUDIO_EXPOSURE_ENV,
    /// AUDIO_EXPOSURE_HEADPHONE, WALKING_ASYMMETRY, WALKING_DOUBLE_SUPPORT)
    /// were persisted server-side but silently DROPPED by the tolerant list
    /// decoder because `ServerMeasurementType` had no case for them.
    /// Operator: "Bei Schlaf werden keine Messwerte angezeigt — auch nicht
    /// unter 'Daten'." This pins that all six now decode AND that SLEEP's
    /// per-night total is converted to hours from the server's EXPLICIT
    /// `unit: "minutes"` (v1.11.5 contract — the LIST collapses SLEEP_DURATION
    /// to one per-night time-asleep row in minutes; iOS renders hours).
    @Test("Sleep + 5 siblings now decode; sleep night total reads explicit unit → hours")
    func newlySupportedTypesDecode() throws {
        // v1.11.5: the `/api/measurements` LIST sends ONE per-night SLEEP_DURATION
        // row (time asleep) with an explicit `unit: "minutes"` (432 min = 7.2 h).
        let json = """
        {
          "measurements": [
            { "id": "sleep", "type": "SLEEP_DURATION", "value": 432, "unit": "minutes", "measuredAt": "2026-05-24T07:00:00Z" },
            { "id": "resp", "type": "RESPIRATORY_RATE", "value": 14.5, "unit": "count/min", "measuredAt": "2026-05-24T07:01:00Z" },
            { "id": "audio-env", "type": "AUDIO_EXPOSURE_ENV", "value": 62, "unit": "dBASPL", "measuredAt": "2026-05-24T07:02:00Z" },
            { "id": "audio-hp", "type": "AUDIO_EXPOSURE_HEADPHONE", "value": 78, "unit": "dBASPL", "measuredAt": "2026-05-24T07:03:00Z" },
            { "id": "walk-asym", "type": "WALKING_ASYMMETRY", "value": 3.2, "unit": "%", "measuredAt": "2026-05-24T07:04:00Z" },
            { "id": "walk-ds", "type": "WALKING_DOUBLE_SUPPORT", "value": 28.4, "unit": "%", "measuredAt": "2026-05-24T07:05:00Z" }
          ],
          "meta": { "total": 6, "limit": 400, "offset": 0 }
        }
        """
        let response = try JSONDecoder.hlDefault.decode(
            MeasurementListWireResponse.self,
            from: Data(json.utf8)
        )
        // All six survive the decode (previously every one dropped).
        #expect(response.measurements.count == 6)

        let byId = Dictionary(uniqueKeysWithValues: response.measurements.map { ($0.id, $0) })
        #expect(byId["sleep"]?.type == .sleepDuration)
        #expect(byId["resp"]?.type == .respiratoryRate)
        #expect(byId["audio-env"]?.type == .audioExposureEnvironment)
        #expect(byId["audio-hp"]?.type == .audioExposureHeadphone)
        #expect(byId["walk-asym"]?.type == .walkingAsymmetry)
        #expect(byId["walk-ds"]?.type == .walkingDoubleSupport)

        // Domain mapping: each wire type lands on its MetricKind.
        let domain = Dictionary(uniqueKeysWithValues: response.measurements.compactMap { wire in wire.toDomain().map { (wire.id, $0) } })
        #expect(domain["sleep"]?.kind == .sleep)
        #expect(domain["resp"]?.kind == .respiratoryRate)
        #expect(domain["audio-env"]?.kind == .audioExposureEnvironment)
        #expect(domain["audio-hp"]?.kind == .audioExposureHeadphone)
        #expect(domain["walk-asym"]?.kind == .walkingAsymmetry)
        #expect(domain["walk-ds"]?.kind == .walkingDoubleSupport)

        // SLEEP unit: the LIST sends the per-night total with an explicit
        // `unit: "minutes"` (432 min). `toDomain()` reads that unit and converts
        // to hours (7.2 h) so the value matches the hours-based `.durationHM`
        // formatter + `MetricKind.sleep.unit == "h"`. A real night ≈ 7–8 h —
        // never 432 h (no unit read) nor 0.12 h (a double-divide).
        #expect(domain["sleep"]?.primaryValue == 7.2)
        #expect(byId["sleep"]?.unit == "minutes")
        // Non-sleep types pass through unconverted.
        #expect(domain["resp"]?.primaryValue == 14.5)
        #expect(domain["walk-ds"]?.primaryValue == 28.4)
    }

    /// v0.14 — unit-driven sleep normalisation. If any LIST surface ever sends
    /// the per-night sleep total already in HOURS (`unit: "h"`, as the dashboard
    /// summary + series routes do), `toDomain()` must pass it through verbatim —
    /// NOT divide by 60 again (which would turn 7.2 h into 0.12 h). And a row
    /// with NO unit falls back to the canonical minutes assumption.
    @Test("Sleep value reads explicit unit — hours pass through, minutes convert, absent → minutes")
    func sleepUnitDrivenConversion() throws {
        let json = """
        {
          "measurements": [
            { "id": "sleep-h", "type": "SLEEP_DURATION", "value": 7.2, "unit": "h", "measuredAt": "2026-05-24T07:00:00Z" },
            { "id": "sleep-min", "type": "SLEEP_DURATION", "value": 432, "unit": "minutes", "measuredAt": "2026-05-23T07:00:00Z" },
            { "id": "sleep-none", "type": "SLEEP_DURATION", "value": 432, "measuredAt": "2026-05-22T07:00:00Z" }
          ],
          "meta": { "total": 3, "limit": 400, "offset": 0 }
        }
        """
        let response = try JSONDecoder.hlDefault.decode(
            MeasurementListWireResponse.self,
            from: Data(json.utf8)
        )
        let domain = Dictionary(uniqueKeysWithValues: response.measurements.compactMap { wire in wire.toDomain().map { (wire.id, $0) } })
        // hours → passthrough (no double-divide blow-down to 0.12 h).
        #expect(domain["sleep-h"]?.primaryValue == 7.2)
        // minutes → hours.
        #expect(domain["sleep-min"]?.primaryValue == 7.2)
        // absent unit → assume minutes (canonical SLEEP_DURATION storage).
        #expect(domain["sleep-none"]?.primaryValue == 7.2)
    }

    /// **v0.14.2 M5 — sub-minute / unknown unit guard.** The prior `sleepHours`
    /// divided ANY non-hour token by 60, so a `ns`/`ms`/`s` row (the sleep DTO
    /// universe carries `ns`) would have produced billions of "hours". The
    /// switch is now exhaustive over the sub-hour units with their real factors;
    /// a genuinely unknown token defaults safely to minutes (no blind ÷60 of a
    /// unit we don't recognise — same numeric result here, but explicit).
    @Test("sleepHours scales sub-minute units correctly; unknown defaults to minutes")
    func sleepHoursUnitGuard() {
        // 7.2 h expressed in each unit must all normalise to 7.2 h.
        #expect(MeasurementWireDTO.sleepHours(from: 7.2, unit: "h") == 7.2)
        #expect(MeasurementWireDTO.sleepHours(from: 432, unit: "minutes") == 7.2)
        #expect(MeasurementWireDTO.sleepHours(from: 432, unit: nil) == 7.2)
        #expect(MeasurementWireDTO.sleepHours(from: 25920, unit: "s") == 7.2)
        #expect(MeasurementWireDTO.sleepHours(from: 25_920_000, unit: "ms") == 7.2)
        // ns: 7.2 h = 2.592e13 ns. The old ÷60 would have read ~4.32e11 h.
        let ns = 7.2 * 3_600_000_000_000.0
        #expect(MeasurementWireDTO.sleepHours(from: ns, unit: "ns") == 7.2)
        // Unknown token → safe minutes default (NOT a wild value).
        #expect(MeasurementWireDTO.sleepHours(from: 432, unit: "furlongs") == 7.2)
    }

    @Test("All-unknown page decodes to empty array, not a thrown error")
    func allUnknownDecodesEmpty() throws {
        // A window of types the client doesn't model shouldn't throw — the
        // drill-down can render the empty-state legitimately. (Uses synthetic
        // unknown types so the contract holds as new known types are added.)
        let json = """
        {
          "measurements": [
            { "id": "s1", "type": "UNKNOWN_TYPE_ALPHA", "value": 1000, "measuredAt": "2026-05-24T08:00:00Z" },
            { "id": "s2", "type": "UNKNOWN_TYPE_BETA",  "value": 250,  "measuredAt": "2026-05-24T09:00:00Z" },
            { "id": "s3", "type": "UNKNOWN_TYPE_GAMMA", "value": 12,   "measuredAt": "2026-05-24T10:00:00Z" }
          ],
          "meta": { "total": 3, "limit": 400, "offset": 0 }
        }
        """
        let response = try JSONDecoder.hlDefault.decode(
            MeasurementListWireResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.measurements.isEmpty)
        #expect(response.meta?.total == 3)
    }

    @Test("Empty measurements array round-trips")
    func emptyArrayRoundTrips() throws {
        let json = """
        {
          "measurements": [],
          "meta": { "total": 0, "limit": 400, "offset": 0 }
        }
        """
        let response = try JSONDecoder.hlDefault.decode(
            MeasurementListWireResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.measurements.isEmpty)
        #expect(response.meta?.total == 0)
    }

    @Test("Missing meta is tolerated")
    func missingMetaTolerated() throws {
        let json = """
        {
          "measurements": [
            { "id": "row-1", "type": "WEIGHT", "value": 72, "measuredAt": "2026-05-24T08:00:00Z" }
          ]
        }
        """
        let response = try JSONDecoder.hlDefault.decode(
            MeasurementListWireResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.measurements.count == 1)
        #expect(response.meta == nil)
    }

    @Test("Encode → decode round-trip preserves known rows + meta")
    func encodeDecodeRoundTrip() throws {
        let original = MeasurementListWireResponse(
            measurements: [
                MeasurementWireDTO(
                    id: "w-1",
                    type: .weight,
                    value: 72.4,
                    measuredAt: Date(timeIntervalSince1970: 1_716_540_000)
                ),
                MeasurementWireDTO(
                    id: "p-1",
                    type: .pulse,
                    value: 68,
                    measuredAt: Date(timeIntervalSince1970: 1_716_540_060)
                )
            ],
            meta: MeasurementListResponse.ListMeta(total: 2, limit: 400, offset: 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder.hlDefault.decode(
            MeasurementListWireResponse.self,
            from: data
        )
        #expect(decoded.measurements.count == 2)
        #expect(decoded.measurements.map(\.type) == [.weight, .pulse])
        #expect(decoded.meta?.total == 2)
    }
}
