import SwiftUI

// Per-medication detail sections introduced by v0.6.1.2 Y4.
//
// Two sections born here:
//
//   - `ComplianceKPISection` — top-of-detail KPI tile that surfaces
//     the in-time compliance ratio over the trailing 30 days. The
//     metric counts every past-due scheduled intake; an event is
//     "in-time" when the recorded `takenAt` lands within ±30 min of
//     `scheduledFor`. Signal-colour thresholds route through the single
//     `ComplianceBand` source of truth (v0.12 W4-1): ≥70% graphite,
//     40-69% warn, <40% bad — the monochrome doctrine shared verbatim
//     with the Medikamente-tab card + the Insights medications page.
//
//   - `VerlaufGlyphTrack` — 14-day per-day glyph track that replaces
//     the X-salat compliance read in the intake history. Each day
//     compresses to a filled / dashed / outlined circle for on-time /
//     late / missed.
//
// The take/skip action lives on `MedicationCard` (Medikamente tab
// card stack) per operator brief 2026-05-23 — the detail screen
// stays a read-and-context surface; quick-mark sits inline on the
// card so the operator can mark from the list in one tap.
//
// Hosted as peers to `MedicationDetailScreen` so the host file stays
// under the SwiftLint file-length budget. The sections do not know
// anything about the screen layout — they take their inputs by
// parameter and emit pure presentation. The screen owns the data fetch
// + the store wiring.

// MARK: - Compliance KPI

struct ComplianceKPISection: View {
    /// **W-COMPLIANCE-INV** — the tile renders a paint STATE, not a bare
    /// summary: `.pending` paints an em-dash placeholder until the server
    /// round-trip settles (kills the 100→60→50 value-jump), `.server` paints
    /// the canonical number, `.localFallback` paints the local estimate with
    /// an explicit offline marker line.
    let state: MedicationDetailStore.ComplianceKPIState

    /// v0.8.5 WFIX-COMPLIANCE fix 1 — when non-nil the tile becomes a
    /// disclosure that reveals the `VerlaufGlyphTrack` history below it,
    /// and a leading chevron signals the affordance. `nil` keeps the tile
    /// a passive read (e.g. surfaces that don't host a history track).
    var isHistoryExpanded: Bool?
    var onToggleHistory: (() -> Void)?

    private var isTappable: Bool {
        onToggleHistory != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel("med.compliance.section.header")
            if isTappable {
                Button {
                    onToggleHistory?()
                } label: {
                    card
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(String(localized: "med.compliance.history_hint")))
            } else {
                card
            }
        }
    }

    /// The KPI card body. Hosts the percentage + caption and, when the
    /// section is acting as a history disclosure, a trailing chevron that
    /// flips with the expanded state.
    private var card: some View {
        HLCard {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.md) {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(percentageLabel)
                        .font(.hlMetric(.title))
                        .foregroundStyle(bandColor)
                        .monospacedDigit()
                        .accessibilityLabel(Text(accessibilityLabel))
                    Text(captionLabel)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .monospacedDigit()
                    if isLocalFallback {
                        // W-COMPLIANCE-INV — clearly-marked offline fallback:
                        // the number is a local estimate, not the server's
                        // dose-history-ledger compliance.
                        Text(String(localized: "med.compliance.local_estimate"))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }
                }
                Spacer(minLength: HLSpace.sm)
                Text(String(localized: "med.compliance.window"))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .multilineTextAlignment(.trailing)
                if let expanded = isHistoryExpanded {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.hlIcon(HLIconSize.sm))
                        .foregroundStyle(HLText.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
    }

    /// The summary backing the painted number — `nil` while `.pending`.
    private var summary: MedicationDetailStore.ComplianceSummary? {
        switch state {
        case .pending: nil
        case let .server(summary), let .localFallback(summary): summary
        }
    }

    private var isLocalFallback: Bool {
        if case .localFallback = state { return true }
        return false
    }

    private var percentageLabel: String {
        guard let summary else { return "—" }
        return HLNumberFormat.percent(summary.percentage)
    }

    private var captionLabel: String {
        guard let summary else {
            return String(localized: "med.compliance.loading")
        }
        return String(
            format: String(localized: "med.compliance.caption"),
            summary.inTime,
            summary.total
        )
    }

    /// v0.12 W4-1 — routed through the single `ComplianceBand` source of truth
    /// so the detail KPI agrees with the card + Insights bars at every boundary.
    /// The prior green-topped ramp (≥0.9 `statusOK` …) is retired: a med at 75 %
    /// no longer reads warn here while reading graphite elsewhere.
    /// W-COMPLIANCE-INV — the pending placeholder paints tertiary (no band).
    /// W-B187 coherence — the band derives from the SAME displayed integer
    /// (`summary.percentage`), not a re-rounded ratio. The text rounds half-away
    /// (`.rounded()`) while `band(forRatio:)` truncated (`.towardZero`), so at an
    /// x.5 ratio on a band boundary (e.g. 66.5 % → text "67 %", band on 66) the
    /// number and its colour could disagree by one band. Feeding the band the
    /// displayed integer makes that impossible — one rounded source of truth.
    private var bandColor: Color {
        guard let summary else { return HLText.tertiary }
        return ComplianceBand.band(forPercent: summary.percentage).color
    }

    private var accessibilityLabel: String {
        guard let summary else {
            return String(localized: "med.compliance.loading")
        }
        return String(
            format: String(localized: "med.compliance.a11y"),
            summary.percentage,
            summary.inTime,
            summary.total
        )
    }
}

// MARK: - Verlauf glyph track

struct VerlaufGlyphTrack: View {
    /// Full glyph window the caller hydrates (oldest-first). The track
    /// shows only the trailing `collapsedDays` until the operator expands
    /// it — see the collapse note below.
    let glyphs: [MedicationDetailStore.VerlaufGlyph]

    /// v0.10 R5 — non-daily cadence (interval-weekly / weekday-set meds).
    /// When `true`, the off-day `.noSchedule` glyphs are dropped and the
    /// remaining due-day dots render as a single tight row regardless of
    /// count, so a weekly med shows ~13 dose-days instead of a 90-cell grid
    /// drowned in muted dashes. Shared `isWeeklyCadence` predicate
    /// (`MedicationSchedule`) keeps card + detail consistent.
    var isWeeklyCadence: Bool = false

    /// v0.7.0 W-API-RENDER — above this many days a single row of dots
    /// becomes an unreadable hairline at iPhone width, so we switch to a
    /// 7-column weekday calendar grid. Short tracks (≤ this) keep the
    /// original single-row strip the operator already knows.
    private static let calendarThreshold = 21
    /// Calendar column count — one per weekday.
    private static let calendarColumns = 7

    /// v0.8.5 WFIX-COMPLIANCE fix 3 — default collapsed window.
    ///
    /// Operator on-device read: "der Verlauf ist mir viel zu lang" — the
    /// 90-day calendar grid dominated the detail screen the moment it
    /// opened. We now default to the **last 7 days** (a single tidy row of
    /// dots) and gate the full window behind a "Mehr"/"More" affordance.
    /// `glyphs` arrive oldest-first, so the trailing 7 = the suffix.
    /// `nonisolated` so the pure collapse seam below stays test-reachable
    /// without a SwiftUI render harness.
    nonisolated static let collapsedDays = 7

    /// v0.8.5 WFIX-COMPLIANCE fix 3 — `false` = trailing 7 days, `true` =
    /// the full hydrated window (≤ 90). Local-only, resets on every fresh
    /// open of the detail screen so the screen lands tidy each time.
    @State private var isExpanded = false
    /// QoL-A2 (Felt-craft #5) — gate the Mehr/Weniger expand on reduce-motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// v0.10 R5 — the glyph sequence the collapse/expand operates on. For a
    /// weekly cadence the off-day `.noSchedule` glyphs are dropped first so the
    /// trailing-N window counts *dose-days*, not calendar-days. Daily meds keep
    /// the full window (off-days don't occur for them anyway).
    private var sourceGlyphs: [MedicationDetailStore.VerlaufGlyph] {
        isWeeklyCadence ? glyphs.filter { $0 != .noSchedule } : glyphs
    }

    /// The slice currently rendered: trailing `collapsedDays` when
    /// collapsed, the full window when expanded. Oldest-first order is
    /// preserved either way so the calendar grid still fills correctly.
    private var visibleGlyphs: [MedicationDetailStore.VerlaufGlyph] {
        Self.visibleGlyphs(sourceGlyphs, isExpanded: isExpanded)
    }

    /// Pure collapse seam — used by the view body + the unit-test suite.
    /// `nonisolated` because `View` carries an implicit `@MainActor` the
    /// pure suffix math doesn't need.
    nonisolated static func visibleGlyphs(
        _ glyphs: [MedicationDetailStore.VerlaufGlyph],
        isExpanded: Bool
    ) -> [MedicationDetailStore.VerlaufGlyph] {
        if isExpanded || glyphs.count <= collapsedDays {
            return glyphs
        }
        return Array(glyphs.suffix(collapsedDays))
    }

    /// Whether the "Mehr"/"More" toggle should render at all — only when
    /// there is more history behind the collapsed window.
    private var canExpand: Bool {
        Self.canExpand(sourceGlyphs)
    }

    /// Pure toggle-visibility seam, exposed for the unit-test suite.
    nonisolated static func canExpand(_ glyphs: [MedicationDetailStore.VerlaufGlyph]) -> Bool {
        glyphs.count > collapsedDays
    }

    var body: some View {
        let shown = visibleGlyphs
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel("med.verlauf.section.header")
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    if isWeeklyCadence {
                        // Due-days-only single row — the weekday calendar grid
                        // can't map columns to weekdays once off-days are
                        // dropped, so weekly meds always render the strip.
                        Text(String(
                            format: String(localized: "med.verlauf.due_count"),
                            shown.count
                        ))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        singleRow(shown)
                    } else if shown.count > Self.calendarThreshold {
                        calendarGrid(shown)
                    } else {
                        singleRow(shown)
                    }

                    legend

                    if canExpand {
                        expandToggle
                    }
                }
                .accessibilityLabel(Text(String(
                    format: String(localized: "med.verlauf.a11y"),
                    shown.count
                )))
            }
        }
    }

    /// Original at-a-glance strip — one dot per day, evenly stretched.
    /// Kept for the short (≤ `calendarThreshold`) window.
    private func singleRow(_ glyphs: [MedicationDetailStore.VerlaufGlyph]) -> some View {
        HStack(spacing: HLSpace.xs) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                GlyphDot(glyph: glyph)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// v0.7.0 W-API-RENDER — 7-column weekday calendar for the full
    /// 90-day window. `glyphs` arrive oldest-first, so the grid fills
    /// left-to-right, top-to-bottom: each row is a week, the last row is
    /// the most recent days. Dots use a fixed compact size so a quarter
    /// of adherence fits without horizontal scrolling.
    private func calendarGrid(_ glyphs: [MedicationDetailStore.VerlaufGlyph]) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: HLSpace.xs),
            count: Self.calendarColumns
        )
        return LazyVGrid(columns: columns, alignment: .leading, spacing: HLSpace.xs) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                GlyphDot(glyph: glyph)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// v0.8.5 WFIX-COMPLIANCE fix 3 — the "Mehr"/"More" ⇄ "Weniger"/"Less"
    /// toggle. Mono `HLText.primary` link styling matches the
    /// IntakeHistorySection "Load more" affordance (D-026) so the two
    /// surfaces read as the same primitive.
    private var expandToggle: some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: HLSpace.xxs) {
                Text(isExpanded
                    ? String(localized: "med.verlauf.show_less")
                    : String(localized: "med.verlauf.show_more"))
                    .font(.hlSubhead)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    // Quiet disclosure caret beside the link label —
                    // matches the IntakeHistorySection affordance.
                    .font(.hlIcon(HLIconSize.sm))
            }
            .foregroundStyle(HLText.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isExpanded
                ? String(localized: "med.verlauf.show_less")
                : String(localized: "med.verlauf.show_more")))
    }

    private var legend: some View {
        HStack(spacing: HLSpace.md) {
            // v0.8.5 WFIX-COMPLIANCE fix 2 — the legend swatches inherit the
            // same green/yellow/red status tokens as the per-day circles so
            // the key reads in the same hue the operator now sees on the
            // dots, not the prior monochrome graphite.
            LegendEntry(systemName: "circle.fill", color: HLColor.statusOK, label: String(localized: "med.verlauf.legend.on_time"))
            LegendEntry(systemName: "circle.fill", color: HLColor.statusWarn, label: String(localized: "med.verlauf.legend.late"))
            LegendEntry(systemName: "circle.fill", color: HLColor.statusBad, label: String(localized: "med.verlauf.legend.missed"))
            Spacer()
        }
        .accessibilityHidden(true)
    }

    /// v0.8.5 WFIX-COMPLIANCE fix 2 — pure glyph → status-colour seam.
    /// Green = on-time, yellow = late, red = missed; no-schedule off-days
    /// stay a muted neutral so they read as inert, not false-green. Exposed
    /// for the unit-test suite so the green/yellow/red mapping is asserted
    /// without a render harness. `nonisolated` because `View` carries an
    /// implicit `@MainActor` the pure switch doesn't need. Mirrors
    /// `ComplianceStatusPalette.color` (heatmap squares) so both compliance
    /// surfaces share one palette.
    nonisolated static func statusColor(for glyph: MedicationDetailStore.VerlaufGlyph) -> Color {
        switch glyph {
        case .onTime: HLColor.statusOK
        case .late: HLColor.statusWarn
        case .missed: HLColor.statusBad
        case .noSchedule: HLText.tertiary.opacity(0.4)
        }
    }
}

/// Per-day circle in the Verlauf track.
///
/// **v0.8.5 WFIX-COMPLIANCE fix 2 — status-colour recolor.** The operator's
/// on-device read: "die Kreise sind immer noch monochrom, dachte du hättest
/// das schon implementiert." The dots previously encoded on-time / late /
/// missed purely through SF Symbol *style* (filled / dashed / outlined) on a
/// monochrome `HLText` ramp — that drift left them looking grey next to the
/// W-B recoloured heatmap squares. They now fill with the app's status
/// tokens (green = on-time, yellow = late, red = missed), matching
/// `ComplianceStatusPalette` on `ComplianceHeatmapSection` so every
/// compliance surface tells the same green/yellow/red story. The glyph
/// *shape* stays differentiated too (filled vs. dashed vs. hollow) so the
/// read survives colour-blindness + the legend.
private struct GlyphDot: View {
    let glyph: MedicationDetailStore.VerlaufGlyph

    var body: some View {
        Image(systemName: symbolName)
            .font(.hlIcon(HLIconSize.sm, weight: .regular))
            .foregroundStyle(tint)
            .frame(height: 18)
    }

    private var symbolName: String {
        switch glyph {
        case .onTime: "circle.fill"
        case .late: "circle.dashed"
        case .missed: "circle"
        case .noSchedule: "minus"
        }
    }

    /// Status-semantic fill (green / yellow / red). No-schedule days stay a
    /// muted neutral so an off-day reads as inert "nothing due," not as a
    /// false-green "all good". Delegates to the test-reachable seam on
    /// `VerlaufGlyphTrack` so the mapping has a single source of truth.
    private var tint: Color {
        VerlaufGlyphTrack.statusColor(for: glyph)
    }
}

private struct LegendEntry: View {
    let systemName: String
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: systemName)
                .font(.hlIcon(HLIconSize.xs, weight: .regular))
                .foregroundStyle(color)
            Text(label)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
        }
    }
}
