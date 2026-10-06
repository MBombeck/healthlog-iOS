import Foundation
@testable import HealthLog
import Testing

/// #111 / server PR #892 — an `EXTERNAL` row (written through the
/// `measurements:write` ingest token: a Home Assistant bridge, a scale script)
/// arriving on the `/api/sync/changes` delta page.
///
/// The app has no `/api/sync/changes` consumer of its own today (only the
/// intake upsert type exists, `SyncIntakeUpsert`), so this pins the one thing a
/// consumer will rely on: the measurement upsert element, in the exact
/// `SyncMeasurementUpsert` shape the server publishes
/// (`docs/api/openapi.yaml` at v1.39.0, `SyncChangesEnvelope` →
/// `changes.measurements.upserts[]`), decodes through the app's own
/// ``MeasurementWireDTO`` with its `EXTERNAL` source intact and lands in the
/// owner-editable column — the same decision the list path makes.
@Suite("EXTERNAL source on the sync/changes page (#111)")
struct ExternalSourceSyncChangesTests {
    /// Local mirror of the envelope's path down to the measurement upserts.
    /// Everything else on the page (mood, intakes, cycle, tombstones) is left
    /// to the decoder's ignore-unknown-keys default.
    private struct Page: Decodable {
        struct Changes: Decodable {
            struct Measurements: Decodable {
                let upserts: [MeasurementWireDTO]
            }

            let measurements: Measurements
        }

        struct Payload: Decodable {
            let hasMore: Bool
            let changes: Changes
        }

        let data: Payload
    }

    /// Every `SyncMeasurementUpsert` property the v1.39.0 schema lists, filled
    /// the way the server fills a bridge-written weight row: `EXTERNAL` source,
    /// the bridge's own `externalId`, `deviceType: "scale"`, and the nullable
    /// per-type columns (`glucoseContext`, `sleepStage`, `rhythmClassification`,
    /// `valueMin`/`valueMax`) explicitly `null`.
    static let pageJSON = #"""
    {
      "data": {
        "serverNow": "2026-09-24T12:00:00.000Z",
        "cursor": "opaque-cursor-1",
        "hasMore": false,
        "cursorExpired": false,
        "changes": {
          "measurements": {
            "upserts": [
              {
                "id": "cmext0001",
                "type": "WEIGHT",
                "value": 81.4,
                "unit": "kg",
                "measuredAt": "2026-09-24T06:40:00.000Z",
                "source": "EXTERNAL",
                "notes": null,
                "userId": "user-1",
                "valueMin": null,
                "valueMax": null,
                "externalId": "ha-scale-2026-09-24T06:40",
                "externalSourceVersion": null,
                "glucoseContext": null,
                "sleepStage": null,
                "rhythmClassification": null,
                "deviceType": "scale",
                "syncVersion": 3
              },
              {
                "id": "cmman0001",
                "type": "WEIGHT",
                "value": 81.9,
                "unit": "kg",
                "measuredAt": "2026-09-23T06:40:00.000Z",
                "source": "MANUAL",
                "notes": "after run",
                "userId": "user-1",
                "valueMin": null,
                "valueMax": null,
                "externalId": null,
                "externalSourceVersion": null,
                "glucoseContext": null,
                "sleepStage": null,
                "rhythmClassification": null,
                "deviceType": null,
                "syncVersion": 2
              }
            ],
            "tombstones": []
          },
          "mood": { "upserts": [], "tombstones": [] },
          "intakes": { "upserts": [], "tombstones": [] },
          "cycleDays": { "upserts": [], "tombstones": [] },
          "cycles": { "upserts": [], "tombstones": [] }
        }
      },
      "error": null,
      "meta": { "requestId": "req-1" }
    }
    """#

    private func decodePage() throws -> Page {
        try JSONDecoder.hlDefault.decode(Page.self, from: Data(Self.pageJSON.utf8))
    }

    @Test("an EXTERNAL upsert decodes with its source intact")
    func externalUpsertDecodes() throws {
        let upserts = try decodePage().data.changes.measurements.upserts
        #expect(upserts.count == 2)
        let external = try #require(upserts.first { $0.id == "cmext0001" })
        #expect(external.source == .external)
        #expect(external.externalId == "ha-scale-2026-09-24T06:40")
        #expect(external.value == 81.4)
    }

    @Test("the EXTERNAL row is owner-editable, like the list path decides")
    func externalUpsertIsEditable() throws {
        let upserts = try decodePage().data.changes.measurements.upserts
        let wire = try #require(upserts.first { $0.id == "cmext0001" })
        let domain = try #require(wire.toDomain())
        #expect(domain.source == .external)
        #expect(!domain.isServerDerivedReadOnly)
        // The chronological feed offers the edit on exactly this condition.
        #expect(MeasurementChronoModel.ChronoEntry.single(domain).editableMeasurement?.id == "cmext0001")
    }

    @Test("a server-owned ingest row next to it stays read-only")
    func providerRowStaysReadOnly() throws {
        // Guard against the move taking the whole ingest family with it: a
        // Withings-style connector the server refuses (here NIGHTSCOUT, which
        // the app gates) must keep its read-only column.
        let json = Self.pageJSON.replacingOccurrences(of: "\"EXTERNAL\"", with: "\"NIGHTSCOUT\"")
        let page = try JSONDecoder.hlDefault.decode(Page.self, from: Data(json.utf8))
        let wire = try #require(page.data.changes.measurements.upserts.first { $0.id == "cmext0001" })
        let domain = try #require(wire.toDomain())
        #expect(domain.isServerDerivedReadOnly)
        #expect(MeasurementChronoModel.ChronoEntry.single(domain).editableMeasurement == nil)
    }
}
