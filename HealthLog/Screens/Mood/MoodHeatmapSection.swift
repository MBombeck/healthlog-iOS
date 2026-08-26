import SwiftUI

/// v0.10.0 W-Mood-A — the mood "GitHub Ding" (DESIGN-B §1).
///
/// Adapts `ComplianceHeatmapSection` verbatim in structure — same fixed 12×7
/// matrix, weekday-label column, honesty gates, accessibility seam — and swaps
/// only the per-cell datum (daily-avg mood bucket) and the fill palette (a
/// single-hue `HLText.primary` opacity ramp, NOT the compliance status colors:
/// mood has no missed/taken valence, DESIGN-A §2.3). A **Year-in-Pixels** mode
/// (DESIGN-B §1.7) expands to a full-year `RectangleMark` grid on toggle.
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
    /// v0.14.4 E1 — when set, the pixel grid is driven by the PAGE's bottom range
    /// control (single source of truth) instead of its own "12 weeks | Year"
    /// toggle. The Insights Mood page passes its `MoodPeriod` here so changing the
    /// floating range re-renders the grid for exactly that window; the internal
    /// toggle is then hidden. `nil` (the More → Stimmung host) keeps the legacy
    /// self-owned toggle.
    var period: MoodPeriod?

    @State private var mode: Mode = .twelveWeeks
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// v0.13 WP — at accessibility text sizes the sub-10pt weekday micro-labels
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

    /// v0.14.4 E1 — the grid mode in effect: page-driven when a `period` is
    /// supplied (year lens → year grid, otherwise the compact week grid), else
    /// the operator's own toggle.
    private var effectiveMode: Mode {
        guard let period else { return mode }
        return period == .year ? .year : .twelveWeeks
    }

    /// v0.14.4 E1 — column count of the compact grid. When page-driven, the
    /// window length sets it (30d → 5 weeks, 90d → 13 weeks); otherwise the
    /// canonical 12.
    private var compactWeeks: Int {
        Self.compactWeeks(forPeriod: period)
    }

    /// Pure period → compact-grid week-count rule (E1). Exposed for the unit test:
    /// a page-driven window sizes the grid to exactly that window (rounded up to
    /// whole weeks); `nil` / `.year` fall back to the canonical 12.
    nonisolated static func compactWeeks(forPeriod period: MoodPeriod?) -> Int {
        guard let period, period != .year else { return weeks }
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
    private static let cellSpacing: CGFloat = HLSpace.xxs

    /// Locale-aware Mon-first weekday labels (ported from compliance).
    private nonisolated static let weekdayLabels: [String] = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        let veryShort: [String] = formatter.veryShortWeekdaySymbols ?? []
        let short: [String] = formatter.shortWeekdaySymbols ?? []
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
        if !hasEnoughHistory {
            // 14-day pre-roll gate — hide only on brand-new devices (B13).
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                if bucketByDay.isEmpty {
                    emptyHint
                } else {
                    Group {
                        switch effectiveMode {
                        case .twelveWeeks: twelveWeekGrid
                        case .year: yearGrid
                        }
                    }
                    legend
                }
            }
            .opacity(appeared || reduceMotion ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { appeared = true
                    return
                }
                withAnimation(.easeInOut(duration: 0.25)) { appeared = true }
            }
        }
    }

    // MARK: - Header (title + Ø caption + mode toggle)

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            // v0.14.7 D — the heatmap heading now uses the canonical Insights
            // section header (`InsightsSectionHeader`, sentence-case headline,
            // `HLText.primary`), IDENTICAL to the sibling "Mood today" / "Trend"
            // headings in `MoodAnalysisContent`. It previously used
            // `HLSectionLabel` (uppercase-tracked, secondary, footnote) — the
            // app-wide label role the doctrine explicitly bars inside Insights —
            // so the pixel section stood out as the wrong size/weight.
            //
            // The redundant range label ("Mood — 30 days / … / last year") was
            // dropped: the bottom period selector is the single source of truth
            // for the window, and the sibling sections carry no such suffix.
            InsightsSectionHeader(headerTitle, flush: true)
            Spacer(minLength: HLSpace.xs)
            if !meanLabel.isEmpty {
                Text(meanLabel)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .monospacedDigit()
            }
            // v0.14.4 E1 — the self-owned toggle is hidden when the page range
            // drives the grid (single source of truth = the floating control).
            if period == nil {
                modeToggle
            }
        }
    }

    /// The pixel-grid heading. Range-free — the active window is owned by the
    /// page's period selector (page-driven) or the inline mode toggle (More host),
    /// so the heading no longer restates it.
    private var headerTitle: LocalizedStringKey {
        "Mood calendar"
    }

    /// Visible "12 weeks | Year" pill pair (B14: the old dim ink glyph was
    /// undiscoverable). Monochrome — selected pill = filled ink, unselected =
    /// outline — so it stays calm but obviously switchable. Each pill keeps a
    /// ≥44 pt tap target while the visible chip stays compact.
    private var modeToggle: some View {
        HStack(spacing: HLSpace.xxs) {
            modePill(Text("12 weeks"), isSelected: mode == .twelveWeeks, target: .twelveWeeks)
            modePill(Text("Year"), isSelected: mode == .year, target: .year)
        }
        .accessibilityElement(children: .contain)
    }

    private func modePill(_ label: Text, isSelected: Bool, target: Mode) -> some View {
        Button {
            guard mode != target else { return }
            withAnimation(reduceMotion ? nil : HLMotion.spring) { mode = target }
        } label: {
            label
                .font(.hlCaption2.weight(.semibold))
                .foregroundStyle(isSelected ? HLSurface.primary : HLText.secondary)
                .padding(.horizontal, HLSpace.xs)
                .padding(.vertical, HLSpace.xxs)
                .background {
                    Capsule()
                        .fill(isSelected ? HLText.primary : Color.clear)
                        .overlay {
                            Capsule().strokeBorder(HLText.primary.opacity(isSelected ? 0 : 0.20), lineWidth: 1)
                        }
                }
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text("No mood data yet")
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            Text("Log your mood on the Capture tab and your 12-week history will appear here.")
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 12-week grid (ported compliance layout)

    private var twelveWeekGrid: some View {
        HStack(alignment: .top, spacing: HLSpace.xs) {
            if dynamicTypeSize < .accessibility1 {
                VStack(alignment: .trailing, spacing: Self.cellSpacing) {
                    ForEach(0 ..< Self.daysPerWeek, id: \.self) { row in
                        Text(Self.weekdayLabels[row])
                            // swiftlint:disable:next dynamic_type_bypass
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(HLText.tertiary)
                            .frame(height: Self.cellSize)
                            .accessibilityHidden(true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Self.cellSpacing) {
                ForEach(0 ..< Self.daysPerWeek, id: \.self) { row in
                    HStack(spacing: Self.cellSpacing) {
                        ForEach(0 ..< compactWeeks, id: \.self) { column in
                            cell(for: day(forRow: row, column: column))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Year-in-Pixels grid (DESIGN-B §1.7)

    /// A 7-row × 53-column "Year in Pixels" grid (GitHub layout) sharing the
    /// §1.2 bucketer + §1.3 ramp. Hand-laid as fixed cells (not `RectangleMark`)
    /// so it reuses the same cell renderer + accessibility seam and never drifts
    /// from the 12-week view.
    private var yearGrid: some View {
        let columns = 53
        return HStack(alignment: .top, spacing: HLSpace.xs) {
            if dynamicTypeSize < .accessibility1 {
                VStack(alignment: .trailing, spacing: 1) {
                    ForEach(0 ..< Self.daysPerWeek, id: \.self) { row in
                        Text(Self.weekdayLabels[row])
                            // swiftlint:disable:next dynamic_type_bypass
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(HLText.tertiary)
                            .frame(height: 6)
                            .accessibilityHidden(true)
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
                .buttonStyle(.plain)
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
        return String(localized: "Ø \(mean.formatted(.number.precision(.fractionLength(1))))")
    }

    private func accessibilityLabel(for date: Date?, bucket: Int?) -> Text {
        guard let date else { return Text(verbatim: "") }
        let dateStr = date.formatted(.dateTime.day().month())
        if let bucket {
            return Text("\(dateStr): \(MoodCopy.scoreLabel(bucket))")
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

    /// Single-hue `HLText.primary` opacity ramp. `nil` → inert empty baseline.
    static func fill(forBucket bucket: Int?) -> Color {
        switch bucket {
        case 1: HLText.primary.opacity(0.22)
        case 2: HLText.primary.opacity(0.40)
        case 3: HLText.primary.opacity(0.58)
        case 4: HLText.primary.opacity(0.78)
        case 5: HLText.primary.opacity(1.0)
        default: HLText.primary.opacity(0.08) // empty
        }
    }
}
