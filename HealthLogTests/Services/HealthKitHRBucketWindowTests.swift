#if canImport(HealthKit)
    import Foundation
    @testable import HealthLog
    import Testing

    /// Build 273 (A6) — the HR-bucket window must catch up from the persisted
    /// cursor after dormancy instead of being floored at `now - lookback`.
    /// `heartRateBuckets` is not an incremental partition and the raw per-sample
    /// path drops HR once in bucket mode, so a window floored at 48 h left every
    /// hour between the cursor and `now - 48h` in neither shape on the server.
    @Suite("HR-bucket window — catch-up from the cursor")
    struct HealthKitHRBucketWindowTests {
        private func date(_ iso: String) -> Date {
            ISO8601DateFormatter().date(from: iso) ?? Date()
        }

        @Test("cursor 5 days back → window starts one bucket before the cursor, not 48 h ago")
        func cursorWinsOverLookbackFloor() {
            let now = date("2026-06-25T12:00:00Z")
            let cursor = date("2026-06-20T09:40:00Z")
            let start = HealthKitHRBucketSyncCoordinator.windowStart(
                cutover: date("2026-06-01T00:00:00Z"), now: now, lookbackHours: 48, lastUploadedBucket: cursor
            )
            #expect(start == cursor.addingTimeInterval(-HealthKitHRBucketRow.bucketSeconds))
        }

        @Test("no cursor → the lookback floor as before")
        func noCursorKeepsLookback() {
            let now = date("2026-06-25T12:00:00Z")
            let start = HealthKitHRBucketSyncCoordinator.windowStart(
                cutover: date("2026-06-01T00:00:00Z"), now: now, lookbackHours: 48, lastUploadedBucket: nil
            )
            #expect(start == HealthKitHRBucketRow.flooredToUTCTenMinutes(now.addingTimeInterval(-48 * 3600)))
        }

        @Test("cursor 60 days back → bounded at the catch-up maximum")
        func catchUpIsBounded() {
            let now = date("2026-06-25T12:00:00Z")
            let start = HealthKitHRBucketSyncCoordinator.windowStart(
                cutover: date("2026-01-01T00:00:00Z"), now: now, lookbackHours: 48,
                lastUploadedBucket: date("2026-04-01T00:00:00Z")
            )
            let bound = HealthKitHRBucketRow.flooredToUTCTenMinutes(
                now.addingTimeInterval(-HealthKitHRBucketSyncCoordinator.maxCatchUpSeconds)
            )
            #expect(start == bound)
        }

        @Test("the cutover is never crossed")
        func cutoverIsAFloor() {
            let now = date("2026-06-25T12:00:00Z")
            let cutover = date("2026-06-24T00:00:00Z")
            let start = HealthKitHRBucketSyncCoordinator.windowStart(
                cutover: cutover, now: now, lookbackHours: 48, lastUploadedBucket: date("2026-06-20T09:40:00Z")
            )
            #expect(start == cutover)
        }
    }
#endif
