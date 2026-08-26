import Foundation
@testable import HealthLog
import Testing

/// H1 (v0.11 W26) — MeasureSheet last-used + recent-kinds MRU contract.
///
/// Pure parse/serialize/push logic (no network, no SwiftUI), so a plain
/// unit suite is the right shape. Locks: newest-first ordering, de-dupe on
/// re-pick, cap at the limit, and stale-raw-value filtering (a kind not in
/// the allowed picker set never surfaces).
@Suite("MeasureRecentKinds — MRU persistence")
struct MeasureRecentKindsTests {
    private let allowed: [MetricKind] = [.bloodPressure, .weight, .glucose, .pulse, .spo2, .bmi]

    @Test("push prepends newest, de-dupes, and caps at the limit")
    func pushOrdersDedupesCaps() {
        var raw = ""
        raw = MeasureRecentKinds.push(.weight, into: raw, allowed: allowed, limit: 3)
        raw = MeasureRecentKinds.push(.bloodPressure, into: raw, allowed: allowed, limit: 3)
        raw = MeasureRecentKinds.push(.glucose, into: raw, allowed: allowed, limit: 3)
        // Newest-first.
        #expect(MeasureRecentKinds.parse(raw, allowed: allowed) == [.glucose, .bloodPressure, .weight])

        // Re-pick weight → it moves to front, no duplicate.
        raw = MeasureRecentKinds.push(.weight, into: raw, allowed: allowed, limit: 3)
        #expect(MeasureRecentKinds.parse(raw, allowed: allowed) == [.weight, .glucose, .bloodPressure])

        // A 4th distinct kind evicts the oldest (cap = 3).
        raw = MeasureRecentKinds.push(.pulse, into: raw, allowed: allowed, limit: 3)
        let parsed = MeasureRecentKinds.parse(raw, allowed: allowed)
        #expect(parsed == [.pulse, .weight, .glucose])
        #expect(parsed.count == 3)
    }

    @Test("parse drops unparseable and non-allowed raw values")
    func parseFiltersStale() {
        // `sleep` is a valid MetricKind but excluded from `allowed`; `garbage`
        // is unparseable. Both must be filtered out.
        let raw = "weight,garbage,sleep,glucose"
        #expect(MeasureRecentKinds.parse(raw, allowed: allowed) == [.weight, .glucose])
    }

    @Test("parse of empty string is empty (chip row hides on first run)")
    func parseEmpty() {
        #expect(MeasureRecentKinds.parse("", allowed: allowed).isEmpty)
    }
}
