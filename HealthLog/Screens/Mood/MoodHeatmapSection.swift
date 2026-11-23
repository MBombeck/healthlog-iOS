import SwiftUI

/// The mood "GitHub Ding".
///
/// Adapts `ComplianceHeatmapSection` verbatim in structure — same fixed 12×7
/// matrix, weekday-label column, honesty gates, accessibility seam — and swaps
/// only the per-cell datum (daily-avg mood bucket) and the fill palette (a
/// single-hue `HLText.primary` opacity ramp, NOT the compliance status colors:
/// mood has no missed/taken valence, DESIGN-A §2.3). A **Year-in-Pixels** grid
/// takes over for the year and the whole history.
///
/// Honesty gates: a tiny 14-day pre-roll (so a one-dot device doesn't read as
/// broken) + all-empty hint. Color = signal only; the cells are the
/// monochrome intensity ramp, the only accent is the optional tapped-cell ring
/// (ink, not a hue).
struct MoodHeatmapSection: View {
    /// Daily-average spine from `MoodInsights` (ascending by day).
    let dailyAverages: [MoodDailyAverage]
    /// Optional cell-tap callback → host opens that day.
    var onSelectDay: ((Date) -> Void)?
    /// The page's period. The grid follows the page's one period control and
    /// has no switch of its own; `nil` (a host without a period) draws the
    /// canonical twelve weeks.
    var period: MoodPeriod?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// At accessibility text sizes the sub-10pt weekday micro-labels
    /// are illegible and can't scale (the cells are fixed-size). Hide the whole
    /// label column instead of pinning a tiny font; the grid still reads as a
    /// calendar and the cells carry the accessible per-day values.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var appeared = false

    enum Mode: String, CaseIterable {
        case twelveWeeks
        case year
    }

    private nonisolated static let weeks = 12
    private nonisolated static let daysPerWeek = 7

    /// The grid mode in effect.
    private var effectiveMode: Mode {
        Self.mode(forPeriod: period)
    }

    /// Pure period → grid rule: the year and the whole history draw the
    /// year-in-pixels grid, every shorter window the week grid.
    nonisolated static func mode(forPeriod period: MoodPeriod?) -> Mode {
        switch period {
        case .year, .all: .year
        case .day, .week, .month, .sixMonths, .none: .twelveWeeks
        }
    }

    /// Column count of the compact grid: the window length in whole weeks
    /// (M → 5, 6M → 26); without a period the canonical 12.
    private var compactWeeks: Int {
        Self.compactWeeks(forPeriod: period)
    }

    /// Pure period → compact-grid week-count rule. Exposed for the unit test:
    /// a page-driven window sizes the grid to exactly that window (rounded up to
    /// whole weeks); `nil` and the year-grid periods fall back to the canonical 12.
    nonisolated static func compactWeeks(forPeriod period: MoodPeriod?) -> Int {
        guard let period, mode(forPeriod: period) == .twelveWeeks else { return weeks }
        return Int((Double(period.rawValue) / Double(daysPerWeek)).rounded(.up))
    }

    /// Pre-roll gate: render the heatmap as soon as there's a *little* history.
    /// Was 90 (B13: hid the headline feature for almost everyone — nobody has a
    /// full quarter of mood entries on a fresh device). A sparse / partial
    /// GitHub-style graph is fine and wanted; 14 days is enough to read as a
    /// grid rather than a single stray dot. The all-empty hint still covers the
    /// genuine zero-entries case.
    private nonisolated static let minHistoryDays = 14
    private static let cellSize: CGFloat = 10
    /// The widest a week column of the short grid grows: on a wide page the
    /// weeks stay a compact block beside their weekday letters instead of
    /// spreading a few dots across the whole width.
    static let weekColumnMaxWidth: CGFloat = 28
    private static let cellSpacing: CGFloat = HLSpace.xxs

    /// Locale-aware Mon-first weekday labels (ported from compliance).
    private nonisolated static let weekdayLabels: [String] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        let veryShort = calendar.veryShortWeekdaySymbols
        let short = calendar.shortWeekdaySymbols
        let raw: [String] = veryShort.count == 7 ? veryShort : short
        guard raw.count == 7 else { return Array(repeating: "", count: 7) }
        return [raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[0]]
    }()

    /// Fast `startOfDay → bucket` lookup built once per render.
    private var bucketByDay: [Date: Int] {
        var out: [Date: Int] = [:]
        for avg in dailyAverages {
            if let bucket = MoodHeatmapPalette.bucket(forAvg: avg.average) {
                out[avg.day] = bucket
            }
        }
        return out
    }

    var body: some View {
        if !hasEnoughHistory || bucketByDay.isEmpty {
            // 14-day pre-roll gate — hide only on brand-new devices.
            // A window without a single scored day is absent too,
            // rather than a heading over "log your mood on the Capture tab".
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                Group {
                    switch effectiveMode {
                    case .twelveWeeks: twelveWeekGrid
                    case .year: yearGrid
                    }
                }
                legend
            }
            .moodSectionGap(after: HLSpace.sm)
            .opacity(appeared || reduceMotion ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { appeared = true
                    return
                }
                withAnimation(.easeInOut(duration: 0.25)) { appeared = true }
            }
        }
    }

    // MARK: - Header (title + Ø caption)

    private var header: some View {
        // The window is named by the page's period control, not by the
        // heading, and the grid has no switch of its own.
        HLSectionHeader("Mood calendar", rank: .area) {
            if !meanLabel.isEmpty {
                Text(meanLabel)
                    .hlText(.rowSubtitle)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 12-week grid (ported compliance layout)

    private var twelveWeekGrid: some View {
        HStack(alignment: .top, spacing: HLSpace.xs) {
            if dynamicTypeSize < .accessibility1 {
                VStack(alignment: .trailing, spacing: Self.cellSpacing) {
                    ForEach(0 ..< Self.daysPerWeek, id: \.self) { row in
                        weekdayLabel(row, height: Self.cellSize)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Self.cellSpacing) {
                ForEach(0 ..< Self.daysPerWeek, id: \.self) { row in
                    HStack(spacing: Self.cellSpacing) {
                        ForEach(0 ..< compactWeeks, id: \.self) { column in
                            cell(for: day(forRow: row, column: column))
                                .frame(maxWidth: Self.weekColumnMaxWidth)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Year-in-Pixels grid

    /// A 7-row × 53-column "Year in Pixels" grid (GitHub layout) sharing the
    /// §1.2 bucketer + §1.3 ramp. Hand-laid as fixed cells (not `RectangleMark`)
    /// so it reuses the same cell renderer + accessibility seam and never drifts
    /// from the 12-week view.
    private var yearGrid: some View {
        let columns = 53
        return HStack(alignment: .top, spacing: HLSpace.xs) {
            if dynamicTypeSize < .accessibility1 {
                VStack(alignment: .trailing, spacing: 1) {
                    // A 6 pt row cannot hold a legible letter, so the
                    // year grid names every other day (Mo, Mi, Fr, So) and lets
                    // each label use the empty row beside it.
                    ForEach(0 ..< Self.daysPerWeek, id: \.self) { row in
                        weekdayLabel(row, height: 6, visible: Self.showsYearLabel(row: row))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(0 ..< Self.daysPerWeek, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0 ..< columns, id: \.self) { column in
                            yearCell(for: yearDay(forRow: row, column: column, columns: columns))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The weekday letters at the smallest system text style
    /// (caption 2, 11 pt) instead of 9 and 7 pt. The grid cells keep their
    /// size, so the label is held at that size up to the largest standard text
    /// size; from the accessibility sizes on, the column is hidden as before.
    private func weekdayLabel(_ row: Int, height: CGFloat, visible: Bool = true) -> some View {
        Text(visible ? Self.weekdayLabels[row] : "")
            .font(.hlCaption2.weight(.medium))
            .dynamicTypeSize(...DynamicTypeSize.large)
            .foregroundStyle(HLText.tertiary)
            .frame(height: height)
            .accessibilityHidden(true)
    }

    /// Year grid: Monday, Wednesday, Friday and Sunday carry a letter.
    nonisolated static func showsYearLabel(row: Int) -> Bool {
        row.isMultiple(of: 2)
    }

    // MARK: - Legend (2-glyph, NOT a rainbow — DESIGN-B §1.3)

    private var legend: some View {
        HStack(spacing: HLSpace.sm) {
            Text(MoodCopy.scoreLabel(1))
                .font(.hlCaption2)
                .foregroundStyle(HLText.tertiary)
            HStack(spacing: HLSpace.xs) {
                ForEach(1 ... 5, id: \.self) { bucket in
                    Circle()
                        .fill(MoodHeatmapPalette.fill(forBucket: bucket))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityHidden(true)
            Text(MoodCopy.scoreLabel(5))
                .font(.hlCaption2)
                .foregroundStyle(HLText.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.top, HLSpace.xxs)
    }

    // MARK: - Cells

    @ViewBuilder
    private func cell(for date: Date?) -> some View {
        let bucket = date.flatMap { bucketByDay[$0] }
        let circle = Circle()
            .fill(MoodHeatmapPalette.fill(forBucket: bucket))
            .frame(width: Self.cellSize, height: Self.cellSize)
            .overlay {
                if bucket == nil {
                    Circle().strokeBorder(HLText.primary.opacity(0.12), lineWidth: 0.5)
                }
            }
            .accessibilityLabel(accessibilityLabel(for: date, bucket: bucket))
        // Only days WITH an entry are tappable → opening an empty day has
        // nothing to show, and it keeps empty cells out of the VoiceOver
        // action set (84 action stops would be noise; labelled-but-inert is
        // the honest read for a no-entry day).
        if let date, bucket != nil, let onSelectDay {
            Button { onSelectDay(date) } label: { circle }
                .buttonStyle(.hlRow)
                .accessibilityHint(Text("Double-tap to open"))
        } else {
            circle
        }
    }

    @ViewBuilder
    private func yearCell(for date: Date?) -> some View {
        let bucket = date.flatMap { bucketByDay[$0] }
        Circle()
            .fill(MoodHeatmapPalette.fill(forBucket: bucket))
            .frame(width: 6, height: 6)
            .overlay {
                if bucket == nil {
                    Circle().strokeBorder(HLText.primary.opacity(0.12), lineWidth: 0.4)
                }
            }
            .accessibilityLabel(accessibilityLabel(for: date, bucket: bucket))
    }

    // MARK: - Date math (ported from compliance)

    private func day(forRow row: Int, column: Int) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekday = calendar.component(.weekday, from: today)
        let mondayIndex = ((weekday - 2) + 7) % 7
        let weeksBack = compactWeeks - 1 - column
        let dayDelta = mondayIndex - row
        let totalDaysBack = weeksBack * Self.daysPerWeek + dayDelta
        guard totalDaysBack >= 0,
              let cellDate = calendar.date(byAdding: .day, value: -totalDaysBack, to: today) else { return nil }
        return cellDate
    }

    private func yearDay(forRow row: Int, column: Int, columns: Int) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekday = calendar.component(.weekday, from: today)
        let mondayIndex = ((weekday - 2) + 7) % 7
        let weeksBack = columns - 1 - column
        let dayDelta = mondayIndex - row
        let totalDaysBack = weeksBack * Self.daysPerWeek + dayDelta
        guard totalDaysBack >= 0,
              let cellDate = calendar.date(byAdding: .day, value: -totalDaysBack, to: today) else { return nil }
        return cellDate
    }

    // MARK: - Gates + labels

    private var hasEnoughHistory: Bool {
        Self.hasEnoughHistory(in: dailyAverages.map(\.day), now: .now)
    }

    /// Pure gate seam (mirrors `ComplianceHeatmapSection.hasEnoughHistory`).
    nonisolated static func hasEnoughHistory(in days: [Date], now: Date) -> Bool {
        guard let earliest = days.min() else { return false }
        let calendar = Calendar.current
        let elapsed = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: earliest),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        return elapsed >= Self.minHistoryDays
    }

    private var meanLabel: String {
        guard !dailyAverages.isEmpty else { return "" }
        let mean = dailyAverages.map(\.average).reduce(0, +) / Double(dailyAverages.count)
        return String(localized: "Ø \(HLValueFormat.number(mean, fractionDigits: 1 ... 1))")
    }

    private func accessibilityLabel(for date: Date?, bucket: Int?) -> Text {
        guard let date else { return Text(verbatim: "") }
        let dateStr = HLDateFormat.dayMonth(date)
        if let bucket {
            return Text("\(dateStr): \(MoodCopy.levelLabel(bucket))")
        }
        return Text("\(dateStr): no entry")
    }
}

/// Pure single-hue intensity ramp + bucketer for the mood heatmap (DESIGN-B
/// §1.2/§1.3). "Darker = higher mood." Exposed static for unit-testing.
enum MoodHeatmapPalette {
    /// Daily-average → 5-level bucket. `nil` for no-entry days.
    /// `round(avg)` clamped 1…5 (matches MoodLog `SCORE_TO_MOOD`).
    static func bucket(forAvg avg: Double) -> Int? {
        guard avg > 0 else { return nil }
        return max(1, min(5, Int(avg.rounded())))
    }

    /// Opacity of each level on the single-hue `HLText.primary` ramp. The
    /// lowest level starts at 0.5 so even the worst day keeps 3:1 against
    /// the light page; at 0.22 it nearly vanished (1.45:1).
    static let levelOpacities: [Double] = [0.5, 0.62, 0.74, 0.87, 1.0]
    /// The day without an entry: an inert baseline, not a level.
    static let emptyOpacity = 0.08

    /// Single-hue `HLText.primary` opacity ramp. `nil` → inert empty baseline.
    static func opacity(forBucket bucket: Int?) -> Double {
        guard let bucket, (1 ... 5).contains(bucket) else { return emptyOpacity }
        return levelOpacities[bucket - 1]
    }

    static func fill(forBucket bucket: Int?) -> Color {
        HLText.primary.opacity(opacity(forBucket: bucket))
    }
}
