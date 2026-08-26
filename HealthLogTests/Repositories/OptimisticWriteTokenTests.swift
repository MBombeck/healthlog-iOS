import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **CU-20 (#69) — the shared `baseUpdatedAt` helper.**
///
/// Two server behaviours make this mechanism easy to get subtly wrong, and both
/// are pinned here rather than left to the eight call sites:
///
/// 1. A `baseUpdatedAt` of JSON `null` is **`422 invalid_base_updated_at`**, not
///    a tokenless write (`optimistic-lock.ts:51-72` branches on
///    `typeof !== "string"`). The field must be *absent*. These tests assert on
///    the **actually serialized bytes**, not on a helper's return value — a
///    helper can be right while the encoder still emits a null.
/// 2. Seven of the eight routes guard the same `User.updatedAt`, and three of
///    their GETs are cached 300 s server-side, so a post-409 re-GET can return
///    the *same* stale token. The retry must therefore be bounded and fail
///    visibly instead of looping.
@Suite("CU-20 — optimistic write token helper")
struct OptimisticWriteTokenTests {
    private struct SamplePayload: Encodable {
        let view: String
        let order: [String]
    }

    private func encodedJSON(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder.hlDefault.encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Falle 1: absent, never null

    @Test("Token present: `baseUpdatedAt` is a sibling of the payload's own keys")
    func tokenEncodesAsTopLevelSibling() throws {
        let body = OptimisticWriteBody(
            payload: SamplePayload(view: "cards", order: ["a", "b"]),
            baseUpdatedAt: "2026-07-30T10:00:00.000Z"
        )
        let json = try encodedJSON(body)

        #expect(json["baseUpdatedAt"] as? String == "2026-07-30T10:00:00.000Z")
        // The payload is merged flat, NOT nested under a `payload` key.
        #expect(json["view"] as? String == "cards")
        #expect(json["order"] as? [String] == ["a", "b"])
        #expect(json["payload"] == nil)
        #expect(json.count == 3)
    }

    @Test("Token absent: the key is OMITTED — a JSON null would be a hard 422")
    func absentTokenOmitsTheKeyEntirely() throws {
        let body = OptimisticWriteBody(
            payload: SamplePayload(view: "table", order: []),
            baseUpdatedAt: nil
        )
        let data = try JSONEncoder.hlDefault.encode(body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // `json["baseUpdatedAt"] == nil` alone would ALSO hold for an explicit
        // null (NSNull decodes to a non-nil value, but a sloppy cast hides it),
        // so assert on the raw bytes too: the substring must not occur at all.
        #expect(json.index(forKey: "baseUpdatedAt") == nil)
        #expect(json["baseUpdatedAt"] is NSNull == false)
        let raw = try #require(String(bytes: data, encoding: .utf8))
        #expect(!raw.contains("baseUpdatedAt"))
        #expect(!raw.contains("null"))
        #expect(json.count == 2)
    }

    @Test("Dictionary payloads (coach-prefs) merge flat too")
    func dictionaryPayloadMergesFlat() throws {
        let payload: [String: HLJSONValue] = [
            "tone": .string("warm"),
            "reminderSuggestions": .object(["enabled": .bool(true)])
        ]
        let json = try encodedJSON(OptimisticWriteBody(payload: payload, baseUpdatedAt: "T1"))

        #expect(json["baseUpdatedAt"] as? String == "T1")
        #expect(json["tone"] as? String == "warm")
        #expect((json["reminderSuggestions"] as? [String: Any])?["enabled"] as? Bool == true)
    }

    // MARK: - Conflict identification

    @Test("A 409 with the route's errorCode is recognised; neighbours are not")
    func conflictRecognition() {
        let conflict = HLError.server(status: 409, code: "notification_prefs_conflict", message: "x")
        #expect(conflict.isOptimisticConflict(OptimisticConflictCode.notificationPrefs))
        // Same status, different route → not our conflict.
        #expect(!conflict.isOptimisticConflict(OptimisticConflictCode.moodTagLayout))
        // Same code, different status → not a conflict.
        #expect(!HLError.server(status: 200, code: "notification_prefs_conflict", message: "")
            .isOptimisticConflict(OptimisticConflictCode.notificationPrefs))
        // The unrelated anamnesis 409 must never be mistaken for one of ours.
        #expect(!HLError.server(status: 409, code: "anamnesis.fact.conflict", message: "")
            .isOptimisticConflict(OptimisticConflictCode.aboutMe))
    }

    @Test("422 invalid_base_updated_at is surfaced as its own signal")
    func invalidBaseTokenRecognition() {
        #expect(HLError.server(status: 422, code: "invalid_base_updated_at", message: "").isInvalidBaseToken)
        #expect(!HLError.server(status: 422, code: "modules.invalid", message: "").isInvalidBaseToken)
    }

    @Test("A give-up is non-retriable and must never be parked on the outbox")
    func giveUpIsTerminal() {
        let error = HLError.writeConflictUnresolved(OptimisticConflictCode.insightsLayout)
        // Replaying would re-send the same stale token forever.
        #expect(!error.isRetriable)
        #expect(!error.shouldPersistToOutbox)
        #expect(!error.userFacingDescription.isEmpty)
    }

    // MARK: - Falle 2: bounded retry

    /// Minimal actor so the retry helper's `#isolation` closures have a real
    /// isolation domain to run in, like the repositories do.
    private actor Driver {
        private(set) var writeTokens: [String?] = []
        private(set) var rereadCount = 0

        /// Fails with 409 for the first `conflictCount` attempts, then succeeds.
        func run(conflictCount: Int, maxAttempts: Int = 2, freshTokens: [String?]) async throws -> String {
            var remaining = conflictCount
            var index = 0
            return try await withOptimisticConflictRetry(
                conflictCode: OptimisticConflictCode.dashboardLayout,
                maxAttempts: maxAttempts,
                token: "T0"
            ) { token in
                writeTokens.append(token)
                if remaining > 0 {
                    remaining -= 1
                    throw HLError.server(status: 409, code: OptimisticConflictCode.dashboardLayout, message: "c")
                }
                return "ok(\(token ?? "nil"))"
            } reread: {
                rereadCount += 1
                defer { index += 1 }
                return index < freshTokens.count ? freshTokens[index] : nil
            }
        }
    }

    @Test("Conflict → re-read → the retry lands, carrying the FRESH token")
    func conflictThenRetryLands() async throws {
        let driver = Driver()
        let result = try await driver.run(conflictCount: 1, freshTokens: ["T1"])

        #expect(result == "ok(T1)")
        // First attempt used the stale token, the retry the re-read one.
        #expect(await driver.writeTokens == ["T0", "T1"])
        #expect(await driver.rereadCount == 1)
    }

    @Test("Attempt budget is spent → honest failure, no further requests")
    func attemptsExhaustedFailsVisibly() async throws {
        let driver = Driver()
        await #expect(throws: HLError.writeConflictUnresolved(OptimisticConflictCode.dashboardLayout)) {
            // Never stops conflicting, but each re-read DOES advance the token,
            // so only the budget can stop this.
            try await driver.run(conflictCount: 99, maxAttempts: 3, freshTokens: ["T1", "T2", "T3"])
        }
        // Exactly `maxAttempts` writes, then it gives up — no unbounded loop.
        #expect(await driver.writeTokens == ["T0", "T1", "T2"])
        #expect(await driver.rereadCount == 2)
    }

    /// The 300 s server-side cache case: the re-GET hands back the very token
    /// we just conflicted on, so another attempt is provably identical.
    @Test("Re-read returns the SAME token → stop at once instead of looping")
    func staleRereadShortCircuits() async throws {
        let driver = Driver()
        await #expect(throws: HLError.writeConflictUnresolved(OptimisticConflictCode.dashboardLayout)) {
            // Budget of 5 would allow four retries; the unchanged token must cut
            // it off after the first.
            try await driver.run(conflictCount: 99, maxAttempts: 5, freshTokens: ["T0", "T0", "T0", "T0"])
        }
        #expect(await driver.writeTokens == ["T0"])
        #expect(await driver.rereadCount == 1)
    }

    @Test("No conflict → exactly one write, no re-read")
    func happyPathDoesNotReread() async throws {
        let driver = Driver()
        let result = try await driver.run(conflictCount: 0, freshTokens: [])

        #expect(result == "ok(T0)")
        #expect(await driver.writeTokens == ["T0"])
        #expect(await driver.rereadCount == 0)
    }
}

// swiftlint:enable force_unwrapping
