import Foundation

// Pure, render-free input models for the Erfassen sheet, split out of
// `MeasureSheetView.swift` under the PROJECT_GUIDE.md file-length discipline. Pure
// move — same contracts, same tests (`MeasureRecentKindsTests`,
// `MeasureSheetSupportedKindsTests`).
//
// The `MeasureRecentKinds` doc comment had drifted onto `PainScoreInput` in
// `MeasureSheetView.swift`; each type now carries its own again.

/// v0158 — pure 0–10 NRS clamp/validation logic for the MeasureSheet pain
/// picker. Extracted from the View so the integer-constraint contract (the
/// server accepts any 0–10 float; the client must pin the integer) is
/// unit-testable without a SwiftUI render context.
enum PainScoreInput {
    /// The closed 0…10 NRS range. Drives the wheel picker rows.
    static let range = 0 ... 10

    /// Clamp an arbitrary integer into the 0…10 NRS band. Defensive — the wheel
    /// picker can only yield an in-range value, but a programmatic seed (e.g. a
    /// future prefill) must never persist an out-of-band score.
    static func clamp(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// True when `value` is a valid 0…10 NRS score.
    static func isValid(_ value: Int) -> Bool {
        range.contains(value)
    }
}

/// H1 (v0.11 W26) — pure parse/serialize/push logic for the MeasureSheet
/// recent-kinds MRU. Extracted from the View so the persistence contract
/// (newest-first ordering, de-dupe, cap, stale-value filtering) is unit-
/// testable without a SwiftUI render context.
enum MeasureRecentKinds {
    /// Parse a comma-joined raw-value MRU into kinds, newest-first, dropping
    /// unparseable + non-allowed entries (a stale raw value never surfaces a
    /// dead chip).
    static func parse(_ raw: String, allowed: [MetricKind]) -> [MetricKind] {
        raw
            .split(separator: ",")
            .compactMap { MetricKind(rawValue: String($0)) }
            .filter { allowed.contains($0) }
    }

    /// Push `picked` to the front of the MRU stored in `raw`, de-duping and
    /// capping at `limit`. Returns the re-serialized comma-joined raw string.
    static func push(_ picked: MetricKind, into raw: String, allowed: [MetricKind], limit: Int) -> String {
        var mru = parse(raw, allowed: allowed).filter { $0 != picked }
        mru.insert(picked, at: 0)
        if mru.count > limit {
            mru = Array(mru.prefix(limit))
        }
        return mru.map(\.rawValue).joined(separator: ",")
    }
}
