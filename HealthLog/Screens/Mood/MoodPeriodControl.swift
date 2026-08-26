import SwiftUI

/// v0.10.0 W-Mood-A — the analysis screen's period window.
///
/// **W6-5 documented deviation (STANDARDS §8):** the chart `HLRangeOption`
/// conformers use the single-letter Apple-Health vocabulary (T/W/M/6M/Y).
/// Mood deliberately keeps the wider 30d/90d/1y set: mood is a low-frequency,
/// diary-style metric where a 90-day window is the meaningful "season" lens,
/// and 90d has no single-letter Apple-Health equivalent (it is neither 6M nor
/// M). Collapsing onto the chart set would drop the 90d window users rely on,
/// so the spelled-out duration labels are intentional here.
enum MoodPeriod: Int, CaseIterable, Identifiable {
    case days30 = 30
    case days90 = 90
    case year = 365

    var id: Int {
        rawValue
    }

    var label: String {
        switch self {
        case .days30: String(localized: "30d")
        case .days90: String(localized: "90d")
        case .year: String(localized: "1y")
        }
    }

    var rangeAccessibilityLabel: String {
        switch self {
        case .days30: String(localized: "30 days")
        case .days90: String(localized: "90 days")
        case .year: String(localized: "1 year")
        }
    }

    /// Keeps only entries within the trailing window from `now`.
    func filter(_ entries: [MoodEntry], now: Date = .now, calendar: Calendar = .current) -> [MoodEntry] {
        guard let cutoff = calendar.date(byAdding: .day, value: -rawValue, to: calendar.startOfDay(for: now)) else {
            return entries
        }
        return entries.filter { $0.recordedAt >= cutoff }
    }
}

/// v0.11 — `MoodPeriod` adopts the canonical `HLRangeOption` contract so the
/// mood analysis screen's period control IS the same segmented primitive
/// (`HLRangePicker`) every chart uses, just hosted inside a floating glass
/// capsule (the screen's single Liquid-Glass control).
extension MoodPeriod: HLRangeOption {}

// v0.14 FINAL-QA DRIFT-4 — the `MoodPeriodControl` thin wrapper was RETIRED.
// `MoodPeriod` conforms to `HLRangeOption` (above), so the Mood analysis screen
// and the Insights Mood page now host the canonical generic
// `HLFloatingPeriodControl(selection:)` directly — the SAME bottom-floating
// control every Insights metric page uses — instead of a mood-typed wrapper.
// One period control, identical capsule chrome, across the whole Insights pager.
