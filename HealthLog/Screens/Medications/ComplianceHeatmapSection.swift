import SwiftUI
import UIKit

/// Compliance day-cell grid styled after GitHub's contribution graph.
///
/// **v0.5.5.2 — empty-state path** (W-DATA-FLOW-AUDIT BLOCKER #6). When
/// every cell in the grid would paint at level 0 (no intakes anywhere
/// in the window), we render a discrete empty-state hint pointing
/// at the Medikamente tab instead of a wall of grey circles. The wall
/// reads as "broken chart" on a fresh device with no compliance history;
/// the hint reads as "you haven't started tracking yet."
///
/// **W-UX2 (2026-05-21).** Operator-feedback on v0.5.4.3 walkthrough:
/// "Bei dem Compliance GitHub Chart, da gibt's ja so ganz viele Punkte.
/// Können wir den Compliance-Zeitraum verändern? Ich glaube, da hätte ich
/// einfach kleinere Punkte und acht Wochen, dass das so ein bisschen mehr
/// nach GitHub-Chart aussieht, und ich hätte es gerne in grün, so wie bei
/// GitHub." Translated into a GitHub-green palette, 10 pt circles, and an
/// 8 × 7 footprint.
///
/// **REG-4 (v0.5.5.x, 2026-05-21).** Build-23 TestFlight walkthrough:
/// "Das ist mir zu hoch. Das sind mir zu wenige Punkte für diese Fläche.
/// Das wirkt halt einfach nicht so cool wie es bei GitHub wirkt … erst
/// bei mehr als drei Monaten das Ding überhaupt erst anzeigen und es
/// dann auch für zwölf Wochen anzeigen, damit man auch mehr Sachen hat."
/// Three concrete changes vs. the v0.5.5 8×7 grid:
///
/// 1. **12 weeks × 7 days = 84 cells** in a fixed `12 × 7` matrix.
///    Columns are calendar weeks (oldest leftmost, this week rightmost),
///    rows are weekdays (Mon top, Sun bottom). The store hydrates 84 days
///    (`MedicationsStore.complianceDaysWindow`) so the matrix is fully
///    populated; days outside the data window render at level 0 so the
///    grid keeps its rectangular footprint.
/// 2. **Tighter cell spacing** — `2 pt` instead of `HLSpace.xs` (4 pt) —
///    so 7 rows of 10 pt circles + 6 × 2 pt gaps = **82 pt grid height**,
///    a touch shorter than the prior 8×7 (94 pt) yet visibly denser.
///    Cells stay at `10 pt` (the GitHub web reference size) so each dot
///    remains readable on iPhone Pro at 393 pt content width.
/// 3. **90-day pre-roll gate** — the section renders an `EmptyView()`
///    when the user has fewer than 90 days of compliance history. A
///    sparse 12×7 grid with 80 % level-0 cells reads as "broken chart"
///    on a recently-onboarded user; hiding entirely defers the chart
///    until it has enough density to feel honest. The threshold uses
///    the **oldest** `ComplianceDay.date` in the store-supplied window
///    (cheap O(n) on a 84-element array, no extra store accessor).
///
/// **#13 (2026-06-11).** The window length is no longer hard-coded: the
/// operator picks 4 / 8 / 12 / 26 weeks from Settings → Erscheinungsbild
/// (`SettingsStore.complianceHeatmapWeeks`, 12 = REG-4 default). The section
/// reads the pref live through the `@Observable` environment, so a pick
/// re-lays the grid on the spot. At 26 weeks the cells drop from 10 pt to
/// 8 pt so the half-year footprint still fits the 393 pt content width.
/// The store-side data window is fixed at the 26-week maximum
/// (`MedicationsStore.complianceDaysWindow` = 182) so every pick is fully
/// populated without a refetch.
struct ComplianceHeatmapSection: View {
    let days: [ComplianceDay]
    /// v0.11 (AUDIT-FINAL §H4) — heatmap affordance parity with the mood
    /// twin: a data-bearing cell tap opens that day. `nil` (the default) keeps
    /// the cells inert where no host wires a destination (e.g. the per-medication
    /// detail reuse), so we never present a dead tap target.
    var onSelectDay: ((ComplianceDay) -> Void)?

    init(days: [ComplianceDay], onSelectDay: ((ComplianceDay) -> Void)? = nil) {
        self.days = days
        self.onSelectDay = onSelectDay
    }

    /// v0.13 WP — hide the sub-10pt weekday micro-labels at accessibility text
    /// sizes instead of pinning a tiny font (the cells are fixed-size and can't
    /// scale). Mirrors the Mood heatmap twin.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// **#13 — live window-length pref.** Optional so previews / render
    /// harnesses without the app environment fall back to the 12-week
    /// REG-4 default instead of crashing on a missing observable.
    @Environment(SettingsStore.self) private var settingsStore: SettingsStore?

    /// The operator-picked window (Settings → Erscheinungsbild). Resolved
    /// per body pass so the `@Observable` read re-renders the grid live.
    private var windowOption: ComplianceHeatmapWeeks {
        settingsStore?.complianceHeatmapWeeks ?? .twelve
    }

    /// Number of week-columns currently rendered. Rows = 7 days/week. The
    /// grid renders week-first (columns), so today sits in the rightmost
    /// column on whichever weekday-row matches `Date.now`.
    private var weeks: Int {
        windowOption.rawValue
    }

    // RESOLVED(#13, 2026-06-11): window-length is exposed via Settings →
    // Erscheinungsbild (`SettingsStore.complianceHeatmapWeeks`); 12 remains
    // the default. `defaultWeeks` stays `nonisolated static` because it is
    // consumed by both the MainActor-bound view body and the nonisolated
    // test seam below (`hasEnoughHistory(in:now:)` + the arity accessors).
    private nonisolated static let defaultWeeks = 12
    private nonisolated static let daysPerWeek = 7
    /// Minimum compliance-history span (in days) before the heatmap is
    /// allowed to render. Below this, the grid would be ≥ 60 % empty
    /// cells and read as a broken chart instead of a sparse one —
    /// `EmptyView()` keeps the Meds surface honest until enough density
    /// accumulates. Matches REG-4 spec (2026-05-21).
    private nonisolated static let minHistoryDays = 90
    /// Per-cell pixel size + intra-cell gap. Aim: keep the dots at the
    /// GitHub web reference size (10 pt) while tightening the gap so the
    /// 12 × 7 card height stays slightly shorter than the prior 8 × 7
    /// version (REG-4 operator note "ist jetzt zu hoch"). **#13:** at the
    /// 26-week pick the dots drop to 8 pt — 26 × 10 pt + gaps would
    /// overflow the 393 pt content width inside a card.
    private var cellSize: CGFloat {
        weeks > Self.defaultWeeks ? 8 : 10
    }

    private static let cellSpacing: CGFloat = HLSpace.xxs

    /// QoL 4/7 (v0.5.6) — leading weekday labels (Mon top → Sun bottom)
    /// pulled from the current locale's short weekday symbols so the row
    /// reads "M D M D F S S" in German and "M T W T F S S" in English.
    /// `DateFormatter.veryShortWeekdaySymbols` is Sunday-indexed; we
    /// reorder to Monday-first to match the grid's row convention
    /// (row 0 = Mon). Cached at type init so the column doesn't
    /// allocate per repaint. Both symbol arrays are typed as
    /// implicitly-unwrapped optionals so we coalesce defensively.
    private nonisolated static let weekdayLabels: [String] = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        let veryShort: [String] = formatter.veryShortWeekdaySymbols ?? []
        let short: [String] = formatter.shortWeekdaySymbols ?? []
        let raw: [String] = veryShort.count == 7 ? veryShort : short
        guard raw.count == 7 else { return Array(repeating: "", count: 7) }
        // Reorder Mon=0 … Sun=6 to match the grid's row indexing.
        return [raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[0]]
    }()

    /// **POLISH-MED (v0.5.5.6) / v0.6.1.4 Y4.2.** The section host is no
    /// longer rendered on the main `MedicationsScreen`. In v0.5.5.6 the
    /// screen-level summary moved to a slim 36-pt stripe; in v0.6.1.4
    /// Y4.2 even that stripe was dropped on operator direction — the
    /// per-card 7- and 30-day bars now carry the headline number on
    /// the tab. The section stays alive as a sub-component (the
    /// section header + the heatmap grid, no `HLCard` wrapper) so the
    /// MedicationDetail screen can reuse the 12 × 7 detail
    /// visualisation when the user drills into a specific medication,
    /// and so the existing `hasEnoughHistory(in:now:)` gate-contract
    /// tests in `ComplianceHeatmapSectionTests` keep their production
    /// callsite. The internal `HLCard` wrapper was dropped — the
    /// heatmap renders directly on the host's surface without a
    /// second-level card chrome.
    var body: some View {
        if !hasEnoughHistory {
            // REG-4: hide entirely until the user has ≥ 90 d of compliance
            // history. A 12×7 grid with mostly level-0 cells reads as a
            // broken chart on fresh devices; deferring rendering keeps the
            // Meds surface honest.
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack {
                    // POLISH-MED: Apple grouped-list label style.
                    HLSectionLabel(titleKey)
                    Spacer()
                    Text(rateLabel)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .monospacedDigit()
                }

                Group {
                    if isAllZero {
                        // v0.5.5.2 — discrete hint instead of a wall of 84
                        // grey circles. Reads as "you haven't started yet"
                        // instead of "broken chart" on a fresh device.
                        VStack(alignment: .leading, spacing: HLSpace.xs) {
                            Text(String(localized: "No intakes logged yet"))
                                .font(.hlSubhead.weight(.semibold))
                                .foregroundStyle(HLText.primary)
                            Text(
                                String(
                                    localized: "Once you log medications and acknowledge reminders, your \(weeks)-week compliance history appears here."
                                )
                            )
                            .font(.hlFootnote)
                            .foregroundStyle(HLText.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // QoL 4/7 (v0.5.6): leading weekday-label column.
                        // GitHub's contribution graph leaves rows unlabelled
                        // because the surrounding chrome makes weekday
                        // parsing visual; in HealthLog the heatmap sits
                        // inside a dense detail screen where operators
                        // were left guessing "is the top row Monday or
                        // Sunday?" Locale-respecting Mon-Sun labels (via
                        // `Self.weekdayLabels`) anchor the rows without
                        // breaking the GitHub footprint — the grid still
                        // computes from `Date.now` so today stays in the
                        // rightmost column on its matching row.
                        HStack(alignment: .top, spacing: HLSpace.xs) {
                            if dynamicTypeSize < .accessibility1 {
                                VStack(alignment: .trailing, spacing: Self.cellSpacing) {
                                    ForEach(0 ..< Self.daysPerWeek, id: \.self) { row in
                                        Text(Self.weekdayLabels[row])
                                            // Fixed sub-Dynamic-Type size required to
                                            // keep the weekday label row-height locked
                                            // to the heatmap cell grid (matches the Mood
                                            // heatmap weekday labels). Hidden entirely at
                                            // accessibility sizes (v0.13 WP).
                                            // swiftlint:disable:next dynamic_type_bypass
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(HLText.tertiary)
                                            .frame(height: cellSize)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: Self.cellSpacing) {
                                // 7-row × 12-column grid. We pin the layout with fixed-row
                                // `HStack`s instead of `LazyVGrid(columns:)` so the
                                // GitHub-style "weeks as columns" reads correctly (each
                                // column = one calendar week, each row = one weekday).
                                //
                                // W-CHART-WIDTH (v0.5.5.1): each cell wraps in a
                                // `.frame(maxWidth: .infinity)` so the columns
                                // distribute across the card's full content width
                                // instead of hugging the intrinsic cluster on the
                                // leading edge. Cells stay at `Self.cellSize` (fixed
                                // diameter); only the spacing between columns expands.
                                ForEach(0 ..< Self.daysPerWeek, id: \.self) { row in
                                    HStack(spacing: Self.cellSpacing) {
                                        // #13 — non-constant range: `weeks` follows the
                                        // Settings pick live; `id: \.self` keeps identity
                                        // stable per column index across re-lays.
                                        ForEach(0 ..< weeks, id: \.self) { column in
                                            cell(forRow: row, column: column)
                                                .frame(maxWidth: .infinity)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // A11Y (audit-v0162 §5) — group the day cells as one
                            // navigable container so VoiceOver treats the heatmap as
                            // a coherent grid (mirrors the Mood heatmap twin's
                            // `.contain`) instead of scattering the per-cell labels
                            // across the surrounding rows.
                            .accessibilityElement(children: .contain)
                        }
                    }
                }
            }
        }
    }

    /// **#13** — localized section title for the active window pick. The four
    /// fixed keys (instead of one format key) keep the xcstrings entries
    /// hand-translatable per length and reuse the pre-existing 4/8/12 keys.
    private var titleKey: LocalizedStringKey {
        switch windowOption {
        case .four: "Compliance — 4 weeks"
        case .eight: "Compliance — 8 weeks"
        case .twelve: "Compliance — 12 weeks"
        case .twentySix: "Compliance — 26 weeks"
        }
    }

    /// **REG-4** — true when the user has ≥ 90 days of compliance history.
    /// Derived from the oldest **data-bearing** `ComplianceDay` in the
    /// store-supplied window; sidesteps an extra `MedicationsStore` accessor
    /// for the gate. Empty arrays fail the check (no history → hidden).
    private var hasEnoughHistory: Bool {
        Self.hasEnoughHistory(in: days, now: .now)
    }

    /// Pure variant of the gate, used by both the view-body check above
    /// and the unit-test seam. Surfacing the predicate as a static keeps
    /// the gate testable without exposing internal view state or pulling
    /// in a SwiftUI render harness for what is fundamentally date math.
    /// `nonisolated` because `View` conformance carries an implicit
    /// `@MainActor` — pure date math doesn't need it.
    ///
    /// **#13 tenure fix (2026-06-11).** The gate now anchors on the oldest
    /// day that actually CARRIES data (`scheduled > 0 || taken > 0`), not the
    /// oldest row in the array. Server v1.15.9 emits a zero bucket for EVERY
    /// day of the requested window, so the old `days.map(\.date).min()` read
    /// "window length", not "user tenure": with the 84-day window the gate
    /// could never pass (83 < 90 → heatmap permanently hidden on paired
    /// accounts), and with the new 182-day window it would have passed for
    /// brand-new users (REG-4's broken-chart vector). Anchoring on
    /// data-bearing days restores the documented "user tenure ≥ 90 d"
    /// semantics under both contracts.
    nonisolated static func hasEnoughHistory(in days: [ComplianceDay], now: Date) -> Bool {
        let earliest = days
            .filter { $0.scheduled > 0 || $0.taken > 0 }
            .map(\.date)
            .min()
        guard let earliest else { return false }
        let calendar = Calendar.current
        let elapsed = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: earliest),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        return elapsed >= Self.minHistoryDays
    }

    /// Internal-only column/row arity constants, exposed for the unit-test
    /// seam that asserts the default 12 × 7 = 84 grid arity (REG-4; #13
    /// makes the column count operator-selectable, 12 stays the default).
    /// Mirroring the private constants keeps a single source of truth for
    /// the dimensions while preserving the private surface on the view.
    /// `nonisolated` for the same reason as `hasEnoughHistory(in:now:)`
    /// — `View` carries an implicit `@MainActor` we don't need here.
    nonisolated static var defaultWeeksCount: Int {
        defaultWeeks
    }

    nonisolated static var daysPerWeekCount: Int {
        daysPerWeek
    }

    /// **v0.5.5.2** — true when the user has no compliance history with
    /// any non-zero day. Catches both the "no data at all" path (empty
    /// `days` array) and the "data present but everything is level 0"
    /// path (server reported scheduled rows but every day's rate is 0).
    private var isAllZero: Bool {
        !days.contains { $0.rate > 0 }
    }

    @ViewBuilder
    private func cell(forRow row: Int, column: Int) -> some View {
        let day = day(forRow: row, column: column)
        let circle = Circle()
            .fill(ComplianceStatusPalette.color(for: day))
            .frame(width: cellSize, height: cellSize)
            .accessibilityLabel(accessibilityLabel(for: day))
        // §H4 — only days WITH scheduled doses are tappable (a no-schedule /
        // out-of-window slot has nothing to open), mirroring the mood twin's
        // "entry-bearing cells only" rule so empty cells stay out of the
        // VoiceOver action set.
        if let day, day.scheduled > 0, let onSelectDay {
            Button { onSelectDay(day) } label: { circle }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Double-tap to open"))
        } else {
            circle
        }
    }

    /// Returns the `ComplianceDay` corresponding to the given (row, column)
    /// in the `weeks`×7 grid, or `nil` when the slot falls outside the
    /// available data window. Today is anchored at the rightmost column on
    /// whichever row matches today's weekday; column 0 is `weeks-1` weeks
    /// ago, column `weeks-1` is this week.
    private func day(forRow row: Int, column: Int) -> ComplianceDay? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        // Weekday offset relative to "Monday = row 0". `Calendar.weekday` is
        // 1=Sunday … 7=Saturday; we normalise to 0=Mon … 6=Sun.
        let weekday = calendar.component(.weekday, from: today)
        let mondayIndex = ((weekday - 2) + 7) % 7
        // Total days back from today for cell (row, column):
        //   (weeks-1 - column) full weeks back, plus the difference
        //   between today's weekday-row and the requested row.
        let weeksBack = weeks - 1 - column
        let dayDelta = mondayIndex - row
        let totalDaysBack = weeksBack * Self.daysPerWeek + dayDelta
        guard totalDaysBack >= 0,
              let cellDate = calendar.date(byAdding: .day, value: -totalDaysBack, to: today) else
        {
            return nil
        }
        return days.first { calendar.isDate($0.date, inSameDayAs: cellDate) }
    }

    private func accessibilityLabel(for day: ComplianceDay?) -> Text {
        guard let day else { return Text("") }
        // v0.8.3 W-B — surface the green/yellow/red STATUS word alongside
        // the percentage so VoiceOver + colour-blind users get the same
        // taken / partial / missed read the recoloured fill encodes, not
        // just the hue.
        // audit-v0162 L10N-6 / A11Y-2 — was a raw interpolated string with a
        // hardcoded English "percent" (+ ": "/", " separators) that had no
        // catalog key, so German VoiceOver read "80 percent". Route through a
        // localized key so the whole label translates.
        return Text("med.heatmap.a11y.cell \(formatted(day.date)) \(Int(day.rate * 100)) \(Self.statusWord(for: day))")
    }

    /// Localised status descriptor matching the `ComplianceStatusPalette`
    /// fill: full → "taken", partial → "partially taken", none → "missed".
    /// No-schedule days collapse to the empty descriptor.
    private static func statusWord(for day: ComplianceDay) -> String {
        guard day.scheduled > 0 else { return String(localized: "med.heatmap.status.none") }
        if day.taken >= day.scheduled {
            return String(localized: "med.heatmap.status.taken")
        }
        if day.taken == 0 {
            return String(localized: "med.heatmap.status.missed")
        }
        return String(localized: "med.heatmap.status.partial")
    }

    private var rateLabel: String {
        // M4 — average only over days that actually scheduled a dose;
        // 0-scheduled days carry no adherence and must not dilute the mean.
        let scheduledRates = days.compactMap(\.scheduledRate)
        guard !scheduledRates.isEmpty else { return "" }
        let avg = scheduledRates.reduce(0, +) / Double(scheduledRates.count)
        return "\(Int(avg * 100))% Ø"
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(.dateTime.day().month())
    }
}

/// Status-color palette for the compliance heatmap, scoped to this
/// section. **v0.8.3 W-B status-recolor (supersedes the v0.8.2 W3a
/// monochrome ramp for THIS surface — operator decision):** the GitHub
/// density ramp's monochrome `statusOK`-opacity steps are replaced with
/// the app's green/yellow/red STATUS semantics so the aggregate heatmap
/// reads coherently with the per-medication 90-day `VerlaufGlyphTrack`
/// adherence track (taken / late / missed) the operator now reaches by
/// tapping a card's compliance value.
///
/// **Why status colours over a density ramp:** the aggregate heatmap's
/// per-day `ComplianceDay` carries only `scheduled` + `taken` (the
/// `/api/medications/intake?scope=compliance` endpoint emits no
/// on-time/late split — that granularity lives on the per-medication
/// `/[id]/compliance` `dailyCompliance` bucket the detail screen reads).
/// So this surface derives a **per-day worst-status-wins** read from the
/// taken/scheduled ratio:
///
///   - `scheduled == 0` (or no data)  → neutral/empty (inert no-data day)
///   - `taken >= scheduled` (rate 1)  → green  (`HLColor.statusOK`)  — all due doses taken
///   - `0 < taken < scheduled`        → yellow (`HLColor.statusWarn`) — at least one slot missed
///   - `scheduled > 0 && taken == 0`  → red    (`HLColor.statusBad`)  — every due dose missed
///
/// Worst-status-wins: a single missed slot on a multi-dose day drags the
/// day to yellow; a fully-missed day reads red. This mirrors the detail
/// track's red > yellow > green aggregation so both surfaces tell the
/// same story at their respective granularities.
enum ComplianceStatusPalette {
    /// Per-day worst-status-wins adherence read, derived purely from the
    /// `taken`/`scheduled` ratio so it is unit-testable without a SwiftUI
    /// render harness. Mirrors the detail track's red > yellow > green
    /// aggregation at the coarser aggregate-heatmap granularity.
    enum Status: Equatable {
        /// No scheduled doses that day (or slot outside the data window).
        case none
        /// All due doses taken.
        case taken
        /// At least one — but not all — due doses missed.
        case partial
        /// Every due dose missed.
        case missed
    }

    /// Pure mapping seam. `nil` (slot outside the data window) and
    /// no-schedule days (`scheduled == 0`) collapse to `.none`.
    static func status(for day: ComplianceDay?) -> Status {
        guard let day, day.scheduled > 0 else { return .none }
        if day.taken >= day.scheduled { return .taken }
        if day.taken == 0 { return .missed }
        return .partial
    }

    /// Returns the status fill for a given day. `.none` collapses to the
    /// inert neutral baseline so empty grid slots read as "no data," not
    /// as a false "all good" green.
    static func color(for day: ComplianceDay?) -> Color {
        switch status(for: day) {
        case .none: neutral
        case .taken: HLColor.statusOK
        case .partial: HLColor.statusWarn
        case .missed: HLColor.statusBad
        }
    }

    /// Inert no-data baseline (faint neutral) for slots outside the data
    /// window or days with no scheduled doses. Matches the prior
    /// level-0 monochrome baseline so empty cells stay visually quiet.
    static let neutral = HLText.primary.opacity(0.08)
}
