import Foundation
@testable import HealthLog
import Testing

/// **Parity 1.7 — the illness write bodies must send an explicit `null`, not an
/// absent key, for their clearable fields.**
///
/// The server merges `note` / `functionalImpact` / `feverC` as *"key omitted ⇒
/// keep the stored value, key present ⇒ replace"*
/// (`src/lib/illness/day-log-write.ts:118-143`,
/// `api/illness/episodes/[id]/route.ts:144`). Both bodies used
/// `encodeIfPresent`, which drops the key for `nil` — so clearing a note was
/// impossible: the deleted text came straight back on the next read. These
/// tests assert on the *raw JSON*, because the bug lives entirely in the
/// omitted-vs-null distinction that a round-trip through `Codable` would hide.
@Suite("Illness write bodies encode explicit null")
struct IllnessNullEncodingTests {
    /// Encode a body and return its top-level JSON object, keeping `null`
    /// values (`NSNull`) so absence and null stay distinguishable — the whole
    /// point of these tests.
    private static func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder.hlDefault.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    // MARK: - Day-log upsert

    @Test("Cleared note encodes as explicit null, not an omitted key")
    func dayLogClearedNoteIsNull() throws {
        let body = IllnessDayLogUpsert(date: "2026-03-10", note: nil)
        let json = try Self.jsonObject(body)
        // The key must be PRESENT …
        #expect(json.keys.contains("note"))
        // … and its value must be JSON null, not a string.
        #expect(json["note"] is NSNull)
    }

    @Test("Raw JSON literally contains \"note\":null")
    func dayLogRawJSONContainsNullLiteral() throws {
        let data = try JSONEncoder.hlDefault.encode(
            IllnessDayLogUpsert(date: "2026-03-10", note: nil)
        )
        let raw = String(bytes: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"note\":null"))
    }

    @Test("A present note still encodes its text")
    func dayLogPresentNoteEncodes() throws {
        let json = try Self.jsonObject(
            IllnessDayLogUpsert(date: "2026-03-10", note: "Fieber gesunken")
        )
        #expect(json["note"] as? String == "Fieber gesunken")
    }

    /// The `FUNCTIONAL_IMPACT` burden track the server derives `gapDriverType`
    /// from must not be fed a phantom value — an unspecified impact is `null`,
    /// and `0` ("fully functional") is a real, distinct answer.
    @Test("Unspecified functionalImpact encodes as null, and 0 stays 0")
    func dayLogFunctionalImpactNullability() throws {
        let unspecified = try Self.jsonObject(IllnessDayLogUpsert(date: "2026-03-10"))
        #expect(unspecified.keys.contains("functionalImpact"))
        #expect(unspecified["functionalImpact"] is NSNull)

        let zero = try Self.jsonObject(
            IllnessDayLogUpsert(date: "2026-03-10", functionalImpact: 0)
        )
        #expect(zero["functionalImpact"] as? Int == 0)
    }

    @Test("Switched-off fever encodes as null so the stored value is cleared")
    func dayLogFeverCleared() throws {
        let json = try Self.jsonObject(IllnessDayLogUpsert(date: "2026-03-10", feverC: nil))
        #expect(json.keys.contains("feverC"))
        #expect(json["feverC"] is NSNull)
    }

    @Test("An empty symptom list is still emitted (valid \"no symptoms today\")")
    func dayLogEmptySymptomsEmitted() throws {
        let json = try Self.jsonObject(IllnessDayLogUpsert(date: "2026-03-10"))
        #expect(json["symptoms"] is [Any])
    }

    // MARK: - Episode patch

    @Test("Episode patch sends note: null when the note was cleared")
    func episodePatchClearedNoteIsNull() throws {
        let json = try Self.jsonObject(IllnessEpisodePatch(label: "Grippe", note: nil))
        #expect(json.keys.contains("note"))
        #expect(json["note"] is NSNull)
        #expect(json["label"] as? String == "Grippe")
    }

    /// Clearable relationship/lifecycle fields are full-value fields: `nil`
    /// means "clear", not "untouched". Scalar fields remain partial.
    @Test("Reopening and unlinking encode explicit null while scalar fields stay absent")
    func episodePatchClearableFieldsAreNull() throws {
        let json = try Self.jsonObject(IllnessEpisodePatch(note: "immer noch krank"))
        #expect(!json.keys.contains("label"))
        #expect(!json.keys.contains("type"))
        #expect(!json.keys.contains("lifecycle"))
        #expect(!json.keys.contains("onsetAt"))
        #expect(json.keys.contains("resolvedAt"))
        #expect(json["resolvedAt"] is NSNull)
        #expect(json.keys.contains("parentConditionId"))
        #expect(json["parentConditionId"] is NSNull)
        #expect(json["note"] as? String == "immer noch krank")
    }

    @Test("Reopen and unlink raw JSON contains both null literals")
    func episodePatchClearableFieldsRawJSON() throws {
        let data = try JSONEncoder.hlDefault.encode(IllnessEpisodePatch())
        let raw = String(bytes: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"resolvedAt\":null"))
        #expect(raw.contains("\"parentConditionId\":null"))
    }

    @Test("Present resolution and parent still encode their values")
    func episodePatchClearableFieldsEncodeValues() throws {
        let json = try Self.jsonObject(IllnessEpisodePatch(
            resolvedAt: "2026-03-10T12:00:00Z",
            parentConditionId: "parent-1"
        ))
        #expect(json["resolvedAt"] as? String == "2026-03-10T12:00:00Z")
        #expect(json["parentConditionId"] as? String == "parent-1")
    }
}
