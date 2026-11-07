#if canImport(HealthKit)
    import Foundation
    @testable import HealthLog
    import Testing

    /// SYNC-HR (1.5) — server #586, promise 2 (lutzkind, mbreitkreuz): after a
    /// day that fell back to single readings, the 10-minute heart rate comes
    /// back on the next UTC day.
    ///
    /// The rule "no day in both shapes" stays (``HRBucketNoNeitherDayTests``):
    /// a raw day is never bucketed. What these tests pin is that the fallback
    /// is a day long, not forever, and that it also ends after a stuck sweep,
    /// which in 1.4.1 kept every later sweep waiting until a restart.
    @Suite("SYNC-HR — buckets resume the day after a fallback (#586)", .timeLimit(.minutes(1)))
    struct HRBucketResumeAfterFallbackTests {
        private typealias S = HRBucketSweepTestSupport

        private static let cutover = S.iso("2026-10-06T00:00:00.000Z")

        @Test("(e) a failed sweep makes the day raw; the next UTC day is uploaded as buckets again")
        func nextDayAfterFailureUsesBuckets() async {
            let reader = S.Reader(rows: [S.row("2026-11-01T08:00:00.000Z")])
            let h = S.harness(service: reader, cutover: Self.cutover, now: S.iso("2026-11-01T12:00:00.000Z"))
            h.api.failure = HLError.server(status: 422, code: "validation", message: "no")
            await h.coordinator.sync()
            #expect(!h.rawGateDrops(S.iso("2026-11-01T12:05:00.000Z")), "the failed day did not fall back")
            let rawDay = HRBucketSyncLedger.day(of: S.iso("2026-11-01T00:00:00.000Z"))
            #expect(h.ledger.rawDays == [rawDay])

            // Next UTC day, the server takes buckets again.
            h.api.failure = nil
            h.clock.now = S.iso("2026-11-02T09:00:00.000Z")
            reader.replaceRows([S.row("2026-11-01T08:00:00.000Z"), S.row("2026-11-02T08:30:00.000Z")])
            await h.coordinator.sync()
            #expect(h.api.postedIds.contains(S.bucketId("2026-11-02T08:30:00.000Z")))
            #expect(!h.api.postedIds.contains(S.bucketId("2026-11-01T08:00:00.000Z")), "a raw day got buckets too")
            #expect(h.ledger.bucketDays.contains(rawDay + 1))
            // And the per-sample path drops the new day's readings again.
            #expect(h.rawGateDrops(S.iso("2026-11-02T09:01:00.000Z")))
        }

        @Test("(e) a stuck sweep starves the day into single readings; the next day resumes buckets without a restart")
        func nextDayAfterStuckSweepUsesBuckets() async {
            // mills1975's day: the sweep hangs in the morning and never returns.
            let reader = S.Reader(rows: [], hangCount: 1)
            let h = S.harness(service: reader, cutover: Self.cutover, now: S.iso("2026-11-01T09:45:00.000Z"))
            let stuck = Task { await h.coordinator.sync() }
            #expect(await S.eventually { reader.queries == 1 })

            // Heart rate waits for it; an hour later the day goes raw.
            #expect(h.rawGateDrops(S.iso("2026-11-01T09:46:00.000Z")))
            h.clock.now = S.iso("2026-11-01T11:00:00.000Z")
            #expect(!h.rawGateDrops(S.iso("2026-11-01T10:59:00.000Z")))
            #expect(h.ledger.lastSuppression?.gate == .rawFallbackSweepStarved)

            // The next UTC day, still the same process.
            h.clock.now = S.iso("2026-11-02T06:00:00.000Z")
            reader.replaceRows([S.row("2026-11-01T10:00:00.000Z"), S.row("2026-11-02T05:30:00.000Z")])
            let coordinator = h.coordinator
            _ = await S.completes(within: 5) { await coordinator.sync() }
            #expect(h.api.postedIds == [S.bucketId("2026-11-02T05:30:00.000Z")], "posted \(h.api.postedIds)")
            #expect(h.rawGateDrops(S.iso("2026-11-02T06:01:00.000Z")))

            reader.release()
            _ = await stuck.value
        }
    }
#endif
