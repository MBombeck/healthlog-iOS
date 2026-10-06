#if canImport(HealthKit)
    import Foundation
    @testable import HealthLog
    import Testing

    /// Build 273 (A6), reworked for #12 — the HR-bucket sweep must catch up
    /// after dormancy instead of being floored at `now - lookback`.
    /// `heartRateBuckets` is not an incremental partition and the raw per-sample
    /// path drops HR once in bucket mode, so a window floored at 48 h left every
    /// hour between the last sweep and `now - 48h` in neither shape on the
    /// server. Since #12 the reach is a set of UTC days, not a cursor.
    @Suite("HR-bucket window — catch-up from the cursor")
    struct HealthKitHRBucketWindowTests {
        private func date(_ iso: String) -> Date {
            ISO8601DateFormatter().date(from: iso) ?? Date()
        }

        private func day(_ iso: String) -> Int {
            HRBucketSyncLedger.day(of: date(iso))
        }

        private func days(cutover: String, now: String, ledger: HRBucketSyncLedger = HRBucketSyncLedger()) -> [Int] {
            HealthKitHRBucketSyncCoordinator.sweepDays(
                cutover: date(cutover), now: date(now), ledger: ledger, isBucketDay: { _ in true }
            )
        }

        @Test("settled up to 5 days back → the sweep resumes on the first unsettled day, not 48 h ago")
        func resumesAfterTheLastSettledDay() {
            var ledger = HRBucketSyncLedger()
            ledger.settledDays = Set(day("2026-06-01T00:00:00Z") ... day("2026-06-20T00:00:00Z"))
            let reach = days(cutover: "2026-06-01T00:00:00Z", now: "2026-06-25T12:00:00Z", ledger: ledger)
            #expect(reach == Array(day("2026-06-21T00:00:00Z") ... day("2026-06-25T00:00:00Z")))
        }

        @Test("no history → every day since the cutover")
        func noHistoryReachesTheCutover() {
            let reach = days(cutover: "2026-06-01T00:00:00Z", now: "2026-06-25T12:00:00Z")
            #expect(reach.first == day("2026-06-01T00:00:00Z"))
            #expect(reach.last == day("2026-06-25T00:00:00Z"))
        }

        @Test("cutover far back → bounded at the backfill maximum")
        func catchUpIsBounded() {
            let reach = days(cutover: "2025-01-01T00:00:00Z", now: "2026-06-25T12:00:00Z")
            #expect(reach.first == day("2026-06-25T00:00:00Z") - HealthKitHRBucketSyncCoordinator.backfillDays)
        }

        @Test("the cutover is never crossed")
        func cutoverIsAFloor() {
            let reach = days(cutover: "2026-06-24T00:00:00Z", now: "2026-06-25T12:00:00Z")
            #expect(reach == [day("2026-06-24T00:00:00Z"), day("2026-06-25T00:00:00Z")])
        }

        @Test("today and yesterday stay open even when settled; raw days and other regimes are skipped")
        func openDaysAndExclusions() {
            var ledger = HRBucketSyncLedger()
            ledger.settledDays = Set(day("2026-06-20T00:00:00Z") ... day("2026-06-25T00:00:00Z"))
            ledger.rawDays = [day("2026-06-25T00:00:00Z")]
            let otherRegime = day("2026-06-24T00:00:00Z")
            let reach = HealthKitHRBucketSyncCoordinator.sweepDays(
                cutover: date("2026-06-20T00:00:00Z"),
                now: date("2026-06-25T12:00:00Z"),
                ledger: ledger,
                isBucketDay: { $0 != otherRegime }
            )
            #expect(reach.isEmpty)

            var withoutRawDays = ledger
            withoutRawDays.rawDays = []
            let withoutRaw = HealthKitHRBucketSyncCoordinator.sweepDays(
                cutover: date("2026-06-20T00:00:00Z"),
                now: date("2026-06-25T12:00:00Z"),
                ledger: withoutRawDays,
                isBucketDay: { _ in true }
            )
            #expect(withoutRaw == [day("2026-06-24T00:00:00Z"), day("2026-06-25T00:00:00Z")])
        }
    }
#endif
