import Foundation
@testable import HealthLog
import Testing

/// **Custom-metric write bodies — the omitted-vs-null distinction.**
///
/// Both PATCH routes build their Prisma `data` object field-by-field and treat
/// an omitted key as "leave the column alone" while an explicit `null` CLEARS it
/// (`api/custom-metrics/[id]/route.ts:113-119`,
/// `.../entries/[entryId]/route.ts:73-76`). A plain `encodeIfPresent` collapses
/// those two states, which would make a target bound impossible to clear once
/// set. These tests assert on the RAW JSON, because the whole contract lives in
/// a distinction a `Codable` round-trip would hide.
///
/// The CREATE bodies have the opposite requirement: `createCustomMetricSchema`
/// gives the optional fields no `.or(z.null())` arm, so sending an explicit null
/// there is a 422 — absent must mean absent.
@Suite("Custom metric write bodies")
struct CustomMetricWriteBodyTests {
    /// Encode and return the top-level JSON object, keeping `null` as `NSNull`
    /// so absence and null stay distinguishable — the point of these tests.
    private static func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder.hlDefault.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    // MARK: - Create (absent must mean absent)

    @Test("Create body emits only the fields that are set")
    func createOmitsUnsetFields() throws {
        let json = try Self.jsonObject(CustomMetricCreate(name: "Griffkraft", unit: "kg"))
        #expect(json["name"] as? String == "Griffkraft")
        #expect(json["unit"] as? String == "kg")
        #expect(!json.keys.contains("targetLow"), "the create schema has no null arm for a bound")
        #expect(!json.keys.contains("targetHigh"))
        #expect(!json.keys.contains("decimals"))
        #expect(!json.keys.contains("description"))
    }

    @Test("Create body carries a full target band and display options")
    func createCarriesEveryField() throws {
        let json = try Self.jsonObject(CustomMetricCreate(
            name: "Griffkraft", unit: "kg",
            targetLow: 40, targetHigh: 60, decimals: 1, description: "rechte Hand"
        ))
        #expect(json["targetLow"] as? Double == 40)
        #expect(json["targetHigh"] as? Double == 60)
        #expect(json["decimals"] as? Int == 1)
        #expect(json["description"] as? String == "rechte Hand")
    }

    @Test("Create body never emits an explicit null for an unset bound")
    func createNeverEmitsNull() throws {
        let data = try JSONEncoder.hlDefault.encode(CustomMetricCreate(name: "A", unit: "x"))
        let raw = String(bytes: data, encoding: .utf8) ?? ""
        #expect(!raw.contains("null"), "an explicit null on create is a server 422")
    }

    // MARK: - Metric PATCH (three distinct states)

    @Test("Untouched patch fields are omitted entirely")
    func patchUnchangedOmitsKeys() throws {
        let json = try Self.jsonObject(CustomMetricPatch(name: "Neuer Name"))
        #expect(json["name"] as? String == "Neuer Name")
        #expect(!json.keys.contains("targetLow"), "unchanged must omit the key, not send null")
        #expect(!json.keys.contains("targetHigh"))
        #expect(!json.keys.contains("decimals"))
        #expect(!json.keys.contains("description"))
    }

    @Test("Clearing a target bound emits an explicit JSON null")
    func patchClearEmitsNull() throws {
        let json = try Self.jsonObject(CustomMetricPatch(targetLow: .clear, targetHigh: .clear))
        #expect(json.keys.contains("targetLow"))
        #expect(json["targetLow"] is NSNull, "clear must be a literal null so the server nulls the column")
        #expect(json["targetHigh"] is NSNull)
    }

    @Test("Raw JSON literally contains the null literal for a cleared bound")
    func patchRawNullLiteral() throws {
        let data = try JSONEncoder.hlDefault.encode(CustomMetricPatch(targetLow: .clear))
        let raw = String(bytes: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"targetLow\":null"))
    }

    @Test("Setting a bound emits its value")
    func patchSetEmitsValue() throws {
        let json = try Self.jsonObject(CustomMetricPatch(targetLow: .set(35.5), decimals: .set(2)))
        #expect(json["targetLow"] as? Double == 35.5)
        #expect(json["decimals"] as? Int == 2)
    }

    @Test("fullEdit maps a nil optional to CLEAR, not to an omission")
    func patchFullEditClearsNils() throws {
        // The editor always shows every field, so an emptied box IS the intent —
        // omitting would silently keep the old bound the user just deleted.
        let patch = CustomMetricPatch.fullEdit(
            name: "A", unit: "kg",
            targetLow: nil, targetHigh: 60, decimals: nil, description: nil,
            // CU-35 (3) — the editor also always shows the correlation consent,
            // so a full-surface edit states it too.
            correlationEnabled: false
        )
        let json = try Self.jsonObject(patch)
        #expect(json["targetLow"] is NSNull)
        #expect(json["targetHigh"] as? Double == 60)
        #expect(json["decimals"] is NSNull)
        #expect(json["description"] is NSNull)
        #expect(json["name"] as? String == "A")
    }

    @Test("Metric patch round-trips through the outbox blob preserving tri-state")
    func patchRoundTripsForOutbox() throws {
        // The outbox persists the encoded payload and replays it verbatim, so a
        // queued "clear the band" must still be a clear after a decode cycle.
        let original = CustomMetricPatch(
            name: "A", targetLow: .clear, targetHigh: .set(60), decimals: .unchanged
        )
        let data = try JSONEncoder.hlDefault.encode(original)
        let decoded = try JSONDecoder.hlDefault.decode(CustomMetricPatch.self, from: data)
        #expect(decoded.targetLow == .clear)
        #expect(decoded.targetHigh == .set(60))
        #expect(decoded.decimals == .unchanged)
        #expect(decoded == original)
    }

    // MARK: - Entry bodies

    @Test("Entry create emits value + measuredAt and never a unit")
    func entryCreateOmitsUnit() throws {
        let json = try Self.jsonObject(CustomMetricEntryCreate(
            value: 47.5, measuredAt: "2026-07-02T07:30:00Z", note: "früh"
        ))
        #expect(json["value"] as? Double == 47.5)
        #expect(json["measuredAt"] as? String == "2026-07-02T07:30:00Z")
        #expect(json["note"] as? String == "früh")
        #expect(!json.keys.contains("unit"), "the server snapshots the unit itself — the client must not send one")
    }

    @Test("Entry create omits an unset note")
    func entryCreateOmitsNote() throws {
        let json = try Self.jsonObject(CustomMetricEntryCreate(value: 1, measuredAt: "2026-07-02T07:30:00Z"))
        #expect(!json.keys.contains("note"))
    }

    @Test("A zero value is emitted, not dropped as falsy")
    func entryCreateEmitsZero() throws {
        let json = try Self.jsonObject(CustomMetricEntryCreate(value: 0, measuredAt: "2026-07-02T07:30:00Z"))
        #expect(json["value"] as? Double == 0, "0 is a real reading and must reach the server")
    }

    @Test("Entry patch clears a note with an explicit null")
    func entryPatchClearsNote() throws {
        let json = try Self.jsonObject(CustomMetricEntryPatch.fullEdit(
            value: 3, measuredAt: "2026-07-02T07:30:00Z", note: nil
        ))
        #expect(json["value"] as? Double == 3)
        #expect(json["note"] is NSNull, "note is the one clearable column on the entry schema")
    }

    @Test("Entry patch leaves an untouched note absent")
    func entryPatchUnchangedNote() throws {
        let json = try Self.jsonObject(CustomMetricEntryPatch(value: 3))
        #expect(json["value"] as? Double == 3)
        #expect(!json.keys.contains("note"))
        #expect(!json.keys.contains("measuredAt"))
    }
}
