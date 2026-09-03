import Foundation
@testable import HealthLog
import Testing

/// Build 273 (A7) — re-login on a day that already carries bucket rows must
/// continue in bucket mode from the persisted cursor. Logout clears the cutover
/// (per-user key), and re-arming at the NEXT UTC midnight sent the rest of that
/// day raw while the morning was already bucketed: the double-count the store's
/// own header forbids.
@Suite("HR-bucket cutover — re-arming honours the persisted cursor")
struct HRBucketCutoverReloginTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "test.hrcutover.relogin.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? Date()
    }

    @Test("no stored cutover + a last-bucket cursor today → armed at that bucket's UTC day")
    func reArmsAtCursorDay() {
        let d = isolatedDefaults()
        d.set(date("2026-06-25T09:40:00Z"), forKey: HRBucketCutoverStore.lastBucketKey(for: "user-1"))
        let armed = HRBucketCutoverStore.cutover(userId: "user-1", now: date("2026-06-25T12:00:00Z"), defaults: d)
        #expect(armed == date("2026-06-25T00:00:00Z"))
    }

    @Test("no cursor → next UTC midnight as before")
    func noCursorArmsAtNextMidnight() {
        let d = isolatedDefaults()
        let armed = HRBucketCutoverStore.cutover(userId: "user-1", now: date("2026-06-25T12:00:00Z"), defaults: d)
        #expect(armed == date("2026-06-26T00:00:00Z"))
    }

    @Test("another user's cursor does not arm this user's cutover")
    func cursorIsPerUser() {
        let d = isolatedDefaults()
        d.set(date("2026-06-25T09:40:00Z"), forKey: HRBucketCutoverStore.lastBucketKey(for: "user-2"))
        let armed = HRBucketCutoverStore.cutover(userId: "user-1", now: date("2026-06-25T12:00:00Z"), defaults: d)
        #expect(armed == date("2026-06-26T00:00:00Z"))
    }
}
