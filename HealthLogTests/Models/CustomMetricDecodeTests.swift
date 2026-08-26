import Foundation
@testable import HealthLog
import Testing

/// **Tolerant decode for the custom-metric wire DTOs.**
///
/// Pins the four tolerance axes against the server's actual serialisers
/// (`src/lib/custom-metrics/custom-metric-store.ts`): a field PRESENT, ABSENT,
/// explicitly NULL, and an UNKNOWN extra key the server might add later. The
/// last one matters most here — this surface carries no wire enum to fuzz, so
/// "an added field never hard-fails the envelope" is the equivalent property.
///
/// The `latest` / `entryCount` axis is the one with a real contract behind it:
/// `GET /api/custom-metrics` emits both, `GET /{id}` and `PATCH /{id}` emit
/// NEITHER (they call the bare `serialiseCustomMetric`). A decoder that required
/// them would break every single-resource read.
@Suite("Custom metric — tolerant decode")
struct CustomMetricDecodeTests {
    // MARK: - CustomMetricDTO

    @Test("Full list row decodes every field incl. latest + entryCount")
    func fullListRowDecodes() throws {
        let json = Data("""
        {
          "id": "cm-1",
          "name": "Griffkraft",
          "unit": "kg",
          "targetLow": 40,
          "targetHigh": 60,
          "decimals": 1,
          "description": "Morgens, rechte Hand",
          "createdAt": "2026-07-01T08:00:00.000Z",
          "updatedAt": "2026-07-02T08:00:00.000Z",
          "latest": { "value": 47.5, "unit": "kg", "measuredAt": "2026-07-02T07:30:00.000Z" },
          "entryCount": 12
        }
        """.utf8)
        let metric = try JSONDecoder.hlDefault.decode(CustomMetricDTO.self, from: json)
        #expect(metric.id == "cm-1")
        #expect(metric.name == "Griffkraft")
        #expect(metric.unit == "kg")
        #expect(metric.targetLow == 40)
        #expect(metric.targetHigh == 60)
        #expect(metric.decimals == 1)
        #expect(metric.description == "Morgens, rechte Hand")
        #expect(metric.entryCount == 12)
        #expect(metric.latest?.value == 47.5)
        #expect(metric.latest?.unit == "kg")
    }

    @Test("Single-resource shape (no latest / entryCount) decodes with safe defaults")
    func singleResourceShapeDecodes() throws {
        // Exactly what `serialiseCustomMetric` emits — the GET /{id} + PATCH /{id}
        // response. Both keys are absent, not null.
        let json = Data("""
        {
          "id": "cm-2",
          "name": "Schlafqualität",
          "unit": "Punkte",
          "targetLow": null,
          "targetHigh": null,
          "decimals": null,
          "description": null,
          "createdAt": "2026-07-01T08:00:00.000Z",
          "updatedAt": "2026-07-01T08:00:00.000Z"
        }
        """.utf8)
        let metric = try JSONDecoder.hlDefault.decode(CustomMetricDTO.self, from: json)
        #expect(metric.latest == nil, "an absent latest key must not fail the decode")
        #expect(metric.entryCount == 0, "entryCount defaults to 0 on the bare shape")
        #expect(metric.targetLow == nil)
        #expect(metric.targetHigh == nil)
        #expect(metric.decimals == nil)
        #expect(metric.description == nil)
        #expect(metric.hasTargetBand == false)
    }

    @Test("Explicit null latest decodes as nil, not a fabricated value")
    func explicitNullLatestDecodes() throws {
        // A metric that exists but has never been logged: the list read emits
        // `"latest": null` (the server's own ternary).
        let json = Data("""
        {"id":"cm-3","name":"VO2","unit":"ml/kg/min","latest":null,"entryCount":0}
        """.utf8)
        let metric = try JSONDecoder.hlDefault.decode(CustomMetricDTO.self, from: json)
        #expect(metric.latest == nil)
        #expect(metric.latestDisplayValue == CustomMetricFormat.absentPlaceholder)
    }

    @Test("Minimal payload fills safe defaults without throwing")
    func minimalPayloadDecodes() throws {
        let json = Data(#"{"id":"cm-4"}"#.utf8)
        let metric = try JSONDecoder.hlDefault.decode(CustomMetricDTO.self, from: json)
        #expect(metric.id == "cm-4")
        #expect(metric.name.isEmpty)
        #expect(metric.unit.isEmpty)
        #expect(metric.entryCount == 0)
        #expect(metric.createdAt.isEmpty)
    }

    @Test("An unknown extra key is ignored rather than failing the envelope")
    func unknownKeyIsTolerated() throws {
        // The equivalent of the unknown-enum-literal axis for a surface with no
        // wire enum: a field the server adds later must never break an older app.
        let json = Data("""
        {
          "id": "cm-5", "name": "Stimmung", "unit": "Punkte",
          "entryCount": 3,
          "aggregationMode": "WEEKLY_MEAN",
          "archivedAt": null
        }
        """.utf8)
        let metric = try JSONDecoder.hlDefault.decode(CustomMetricDTO.self, from: json)
        #expect(metric.name == "Stimmung")
        #expect(metric.entryCount == 3)
    }

    // MARK: - CustomMetricEntryDTO

    @Test("Full entry row decodes, keeping its own snapshotted unit")
    func fullEntryDecodes() throws {
        let json = Data("""
        {
          "id": "e-1",
          "customMetricId": "cm-1",
          "value": 47.5,
          "unit": "kg",
          "measuredAt": "2026-07-02T07:30:00.000Z",
          "note": "nach dem Aufstehen",
          "createdAt": "2026-07-02T07:31:00.000Z"
        }
        """.utf8)
        let entry = try JSONDecoder.hlDefault.decode(CustomMetricEntryDTO.self, from: json)
        #expect(entry.id == "e-1")
        #expect(entry.customMetricId == "cm-1")
        #expect(entry.value == 47.5)
        #expect(entry.unit == "kg")
        #expect(entry.note == "nach dem Aufstehen")
        #expect(entry.valueIsAbsent == false)
    }

    @Test("Null note decodes as nil; a null value stays nil rather than becoming 0")
    func nullFieldsDecodeHonestly() throws {
        // The fabricated-zero bug the labs surface had to unwind (audit A3 /
        // item 1.5): a missing number must read as ABSENT, never as a real 0.
        let json = Data("""
        {"id":"e-2","customMetricId":"cm-1","value":null,"unit":"kg","measuredAt":"2026-07-02T07:30:00.000Z","note":null}
        """.utf8)
        let entry = try JSONDecoder.hlDefault.decode(CustomMetricEntryDTO.self, from: json)
        #expect(entry.value == nil, "a null value must not decode to a fabricated 0")
        #expect(entry.valueIsAbsent)
        #expect(entry.note == nil)
    }

    @Test("A genuine zero value is preserved and is NOT treated as absent")
    func zeroValueIsRealData() throws {
        let json = Data("""
        {"id":"e-3","customMetricId":"cm-1","value":0,"unit":"reps","measuredAt":"2026-07-02T07:30:00.000Z"}
        """.utf8)
        let entry = try JSONDecoder.hlDefault.decode(CustomMetricEntryDTO.self, from: json)
        #expect(entry.value == 0)
        #expect(entry.valueIsAbsent == false, "0 is a real reading, distinct from absence")
    }

    // MARK: - Envelopes

    @Test("List envelope decodes; an absent array degrades to empty")
    func listEnvelopeDecodes() throws {
        let full = Data("""
        {"customMetrics":[{"id":"cm-1","name":"A","unit":"x"},{"id":"cm-2","name":"B","unit":"y"}]}
        """.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(ListCustomMetricsResponse.self, from: full)
        #expect(decoded.customMetrics.count == 2)

        let empty = try JSONDecoder.hlDefault.decode(ListCustomMetricsResponse.self, from: Data("{}".utf8))
        #expect(empty.customMetrics.isEmpty)
    }

    @Test("Entries envelope decodes its pagination meta")
    func entriesEnvelopeDecodes() throws {
        let json = Data("""
        {
          "entries": [
            {"id":"e-1","customMetricId":"cm-1","value":1,"unit":"kg","measuredAt":"2026-07-02T07:30:00.000Z"}
          ],
          "meta": { "total": 137, "limit": 100, "offset": 0 }
        }
        """.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(ListCustomMetricEntriesResponse.self, from: json)
        #expect(decoded.entries.count == 1)
        #expect(decoded.meta.total == 137, "the server total drives the load-more affordance")
        #expect(decoded.meta.limit == 100)
        #expect(decoded.meta.offset == 0)
    }

    @Test("Entries envelope without meta falls back to the loaded count")
    func entriesEnvelopeWithoutMeta() throws {
        let json = Data("""
        {"entries":[{"id":"e-1","customMetricId":"cm-1","value":1,"unit":"kg","measuredAt":"2026-07-02T07:30:00.000Z"}]}
        """.utf8)
        let decoded = try JSONDecoder.hlDefault.decode(ListCustomMetricEntriesResponse.self, from: json)
        #expect(decoded.meta.total == 1, "a missing meta must not claim there are 0 rows")
    }
}
