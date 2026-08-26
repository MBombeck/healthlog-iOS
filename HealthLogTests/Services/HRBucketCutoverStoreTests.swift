import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// W-HR-BUCKET-UPLOAD / GH #34 — the per-day-exclusivity boundary.
///
/// These tests pin the cutover-marker mechanics that GUARANTEE no UTC day ever
/// carries both raw per-sample HR rows AND hourly `stats:` rows: the boundary is
/// armed once to the NEXT UTC midnight, is read identically by the per-sample
/// gate and the bucket sweep, and is per-User partitioned.
@Suite("HRBucketCutoverStore — per-day exclusivity boundary")
struct HRBucketCutoverStoreTests {
    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.hrcutover.\(name).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter.fractional.date(from: iso)!
    }

    @Test("arms to the NEXT UTC midnight after now")
    func armsToNextUTCMidnight() {
        let defaults = isolatedDefaults()
        // 2026-06-21T14:37:10Z → next UTC midnight is 2026-06-22T00:00:00Z.
        let now = date("2026-06-21T14:37:10.000Z")
        let cutover = HRBucketCutoverStore.cutover(userId: "u1", now: now, defaults: defaults)
        #expect(cutover == date("2026-06-22T00:00:00.000Z"))
    }

    @Test("exactly at a UTC midnight arms to the FOLLOWING midnight (current day stays per-sample)")
    func atMidnightArmsToFollowing() {
        let defaults = isolatedDefaults()
        let now = date("2026-06-21T00:00:00.000Z")
        let cutover = HRBucketCutoverStore.cutover(userId: "u1", now: now, defaults: defaults)
        // Not 2026-06-21 itself — that day still has raw samples already flowing.
        #expect(cutover == date("2026-06-22T00:00:00.000Z"))
    }

    @Test("cutover is armed once and is stable across later calls with a different now")
    func armOnceStable() {
        let defaults = isolatedDefaults()
        let first = HRBucketCutoverStore.cutover(
            userId: "u1",
            now: date("2026-06-21T14:00:00.000Z"),
            defaults: defaults
        )
        // A much later call must NOT re-arm to a new midnight.
        let later = HRBucketCutoverStore.cutover(
            userId: "u1",
            now: date("2026-06-25T09:00:00.000Z"),
            defaults: defaults
        )
        #expect(first == later)
        #expect(first == date("2026-06-22T00:00:00.000Z"))
    }

    @Test("isOnOrAfterCutover: pre-cutover false, on/after-cutover true (the exclusivity predicate)")
    func onOrAfterPredicate() {
        let defaults = isolatedDefaults()
        let now = date("2026-06-21T14:00:00.000Z") // cutover → 2026-06-22T00:00Z
        // A sample in the partial current day stays per-sample (pre-cutover).
        #expect(
            HRBucketCutoverStore.isOnOrAfterCutover(
                date("2026-06-21T20:00:00.000Z"), userId: "u1", now: now, defaults: defaults
            ) == false
        )
        // A historical sample is pre-cutover too.
        #expect(
            HRBucketCutoverStore.isOnOrAfterCutover(
                date("2026-06-10T08:00:00.000Z"), userId: "u1", now: now, defaults: defaults
            ) == false
        )
        // Exactly at the boundary is bucket-only.
        #expect(
            HRBucketCutoverStore.isOnOrAfterCutover(
                date("2026-06-22T00:00:00.000Z"), userId: "u1", now: now, defaults: defaults
            ) == true
        )
        // After the boundary is bucket-only.
        #expect(
            HRBucketCutoverStore.isOnOrAfterCutover(
                date("2026-06-23T11:00:00.000Z"), userId: "u1", now: now, defaults: defaults
            ) == true
        )
    }

    @Test("per-User partitioned — different users arm independent boundaries")
    func perUserPartition() {
        let defaults = isolatedDefaults()
        let u1 = HRBucketCutoverStore.cutover(
            userId: "u1", now: date("2026-06-21T10:00:00.000Z"), defaults: defaults
        )
        let u2 = HRBucketCutoverStore.cutover(
            userId: "u2", now: date("2026-06-25T10:00:00.000Z"), defaults: defaults
        )
        #expect(u1 == date("2026-06-22T00:00:00.000Z"))
        #expect(u2 == date("2026-06-26T00:00:00.000Z"))
        #expect(u1 != u2)
    }

    @Test("clear re-arms fresh on the next read (re-login)")
    func clearReArms() {
        let defaults = isolatedDefaults()
        let first = HRBucketCutoverStore.cutover(
            userId: "u1", now: date("2026-06-21T10:00:00.000Z"), defaults: defaults
        )
        HRBucketCutoverStore.clear(for: "u1", defaults: defaults)
        #expect(HRBucketCutoverStore.persistedCutover(userId: "u1", defaults: defaults) == nil)
        let reArmed = HRBucketCutoverStore.cutover(
            userId: "u1", now: date("2026-06-30T10:00:00.000Z"), defaults: defaults
        )
        #expect(reArmed == date("2026-07-01T00:00:00.000Z"))
        #expect(reArmed != first)
    }

    @Test("persistedCutover is a pure peek that does NOT arm")
    func peekDoesNotArm() {
        let defaults = isolatedDefaults()
        #expect(HRBucketCutoverStore.persistedCutover(userId: "u1", defaults: defaults) == nil)
        // Peek again — still nil, no side-effect armed it.
        #expect(HRBucketCutoverStore.persistedCutover(userId: "u1", defaults: defaults) == nil)
    }
}

// swiftlint:enable force_unwrapping
