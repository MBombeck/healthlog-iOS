import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **GH #47** — the tolerant, exhaustive ``IntakeSource`` decode. The whole
/// point is that a `/api/sync/changes` intake row carrying `source:"APPLE_HEALTH"`
/// (or any other / absent value) NEVER fails to decode and drops the row.
@Suite("IntakeSource — tolerant decode (no drop)")
struct IntakeSourceTests {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test("APPLE_HEALTH decodes to .appleHealth (exact spelling)")
    func appleHealthDecodes() throws {
        let data = Data(#""APPLE_HEALTH""#.utf8)
        let source = try decoder().decode(IntakeSource.self, from: data)
        #expect(source == .appleHealth)
        #expect(source.isAppleHealth)
        #expect(source.wireValue == "APPLE_HEALTH")
    }

    @Test("MANUAL decodes to .manual")
    func manualDecodes() throws {
        let source = try decoder().decode(IntakeSource.self, from: Data(#""MANUAL""#.utf8))
        #expect(source == .manual)
        #expect(!source.isAppleHealth)
    }

    @Test("An unknown source never throws — it maps to .other verbatim")
    func unknownDecodesToOther() throws {
        let source = try decoder().decode(IntakeSource.self, from: Data(#""SOME_FUTURE_SOURCE""#.utf8))
        #expect(source == .other("SOME_FUTURE_SOURCE"))
        // Round-trips verbatim so a re-encode never loses the value.
        #expect(source.wireValue == "SOME_FUTURE_SOURCE")
    }

    @Test("A sync-changes intake row with source APPLE_HEALTH decodes (no drop)")
    func syncIntakeRowWithAppleHealthSourceDecodes() throws {
        let json = #"""
        {
          "id": "intake-1",
          "medicationId": "med-1",
          "scheduledFor": "2026-07-07T08:00:00Z",
          "takenAt": "2026-07-07T08:05:00Z",
          "skipped": false,
          "source": "APPLE_HEALTH",
          "syncVersion": 3
        }
        """#
        let row = try decoder().decode(SyncIntakeUpsert.self, from: Data(json.utf8))
        #expect(row.id == "intake-1")
        #expect(row.medicationId == "med-1")
        #expect(row.source == .appleHealth)
        #expect(row.takenAt != nil)
        #expect(row.syncVersion == 3)
    }

    @Test("A sync-changes intake row with an unknown / absent source still decodes")
    func syncIntakeRowUnknownAndAbsentSourceDecode() throws {
        // Unknown source.
        let unknownJSON = #"""
        { "id": "i2", "medicationId": "m2", "scheduledFor": "2026-07-07T09:00:00Z",
          "skipped": true, "source": "INTEGRATION_XYZ" }
        """#
        let unknown = try decoder().decode(SyncIntakeUpsert.self, from: Data(unknownJSON.utf8))
        #expect(unknown.source == .other("INTEGRATION_XYZ"))
        #expect(unknown.skipped)

        // Absent source (older server) → defaults to .manual, never a decode drop.
        let absentJSON = #"""
        { "id": "i3", "medicationId": "m3", "scheduledFor": "2026-07-07T10:00:00Z" }
        """#
        let absent = try decoder().decode(SyncIntakeUpsert.self, from: Data(absentJSON.utf8))
        #expect(absent.source == .manual)
        #expect(!absent.skipped)
    }

    @Test("A whole page of mixed-source intake rows decodes without dropping any")
    func mixedSourcePageDecodesFully() throws {
        let json = #"""
        [
          { "id": "a", "medicationId": "m", "scheduledFor": "2026-07-07T08:00:00Z", "source": "MANUAL" },
          { "id": "b", "medicationId": "m", "scheduledFor": "2026-07-07T09:00:00Z", "source": "APPLE_HEALTH" },
          { "id": "c", "medicationId": "m", "scheduledFor": "2026-07-07T10:00:00Z", "source": "FUTURE" }
        ]
        """#
        let rows = try decoder().decode([SyncIntakeUpsert].self, from: Data(json.utf8))
        #expect(rows.count == 3)
        #expect(rows.map(\.source) == [.manual, .appleHealth, .other("FUTURE")])
    }
}

// swiftlint:enable force_unwrapping
