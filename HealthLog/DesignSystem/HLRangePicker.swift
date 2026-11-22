import SwiftUI

/// The ONE canonical period / time-range control for every chart.
///
/// **Why this exists (AUDIT-FINAL §H2):** before v0.11 there were FOUR bespoke
/// period controls — `ChartDetailScreen.RangePicker`, `FullscreenRangePicker`,
/// the Trends overlay's picker, and the mood `MoodPeriodControl` — each with its
/// own styling, a11y label, and placement. The operator wanted "one period
/// control, same options, same look, same behaviour everywhere."
///
/// `HLRangePicker` collapses all four onto one type: a native
/// `Picker(.segmented).tint(HLText.primary)` (the Apple-Health segmented look —
/// full VoiceOver rotor, Dynamic-Type-safe, monochrome chrome per the
/// single-accent doctrine) over any enum conforming to `HLRangeOption`. Every
/// chart with a range now renders the identical control.
protocol HLRangeOption: CaseIterable, Identifiable, Hashable {
    /// Short Apple-Health-style segment label ("W", "M", "6M", "J", …).
    var label: String { get }
    /// Full VoiceOver label for the segment ("Week", "Month", …).
    var rangeAccessibilityLabel: String { get }
}

/// Canonical segmented range control: the bare segments. A detail page
/// hosts them in the floating glass capsule (``HLFloatingPeriodControl``);
/// the material bar this type used to draw itself is gone, a page has one
/// period control and it floats.
struct HLRangePicker<Option: HLRangeOption>: View where Option.AllCases: RandomAccessCollection {
    enum Style {
        /// Bare control, the only form left. Kept as a name so a call that
        /// spells it out still reads as before.
        case inline
    }

    @Binding var selection: Option
    var style: Style = .inline

    var body: some View {
        picker
    }

    private var picker: some View {
        Picker(String(localized: "Time range"), selection: $selection) {
            ForEach(Array(Option.allCases)) { option in
                Text(option.label)
                    .accessibilityLabel(Text(option.rangeAccessibilityLabel))
                    .tag(option)
            }
        }
        // Y6 — AP-005: lock the selected segment to the chart-chrome
        // monochrome key (handbook §2.8), independent of the scene-root accent.
        .pickerStyle(.segmented)
        .tint(HLText.primary)
        .accessibilityLabel(Text("Select time range"))
        // Honour reduce-motion at the call-site's chart `.hlAnimation`; the
        // segment-slide here is the system default (already reduce-motion-aware).
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// **The one period set of the app: T, W, M, 6M, J, Alle.**
///
/// Every detail page with a time series offers exactly these, in this order,
/// in the floating period control (Ruhepuls, Blutdruck, a lab marker, an own
/// metric, mood). `rawValue` is the window in days; `all` asks the server for
/// its whole span (3650 days, its cap).
enum HLTimeRange: Int, CaseIterable, Identifiable, Sendable, HLRangeOption {
    case day = 1
    case week = 7
    case month = 30
    case sixMonths = 180
    case year = 365
    case all = 3650

    /// What a page opens on.
    static let standard: HLTimeRange = .month

    var id: Int {
        rawValue
    }

    /// The window in days.
    var days: Int {
        rawValue
    }

    var label: String {
        switch self {
        case .day: String(localized: "range.label.day", defaultValue: "T")
        case .week: String(localized: "range.label.week", defaultValue: "W")
        case .month: "M"
        case .sixMonths: "6M"
        case .year: String(localized: "range.label.year", defaultValue: "Y")
        case .all: String(localized: "range.label.all", defaultValue: "All")
        }
    }

    var rangeAccessibilityLabel: String {
        switch self {
        case .day: String(localized: "Day")
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        case .sixMonths: String(localized: "6 months")
        case .year: String(localized: "Year")
        case .all: String(localized: "All data")
        }
    }

    /// The first instant of the window that ends at `now`. `nil` for `all`,
    /// which has no lower edge.
    func start(endingAt now: Date, calendar: Calendar = .current) -> Date? {
        guard self != .all else { return nil }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today)
    }

    /// The set entry for a window in days, so a page that stores days can
    /// map onto the set. `nil` for a window the set does not offer.
    init?(days: Int) {
        self.init(rawValue: days)
    }
}
