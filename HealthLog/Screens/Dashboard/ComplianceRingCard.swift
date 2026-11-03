import SwiftUI

/// Medication-compliance ring tile for the Dashboard's `.cards` layout.
///
/// **v0.5.5.2 — hide-empty contract** (W-DATA-FLOW-AUDIT BLOCKER #3): when
/// the server reports no scheduled intakes today AND no doses taken,
/// the ring renders nothing useful — the previous `"—" / "Heute nichts
/// geplant"` copy still claimed the card slot, leaving a hollow ring
/// painted on the dashboard for users who haven't added any medications
/// yet. We now collapse the card to a discrete empty-state hint pointing
/// the user at the Medikamente tab; the dashboard reclaims the vertical
/// space when nothing's scheduled.
///
/// **v0.5.1-A B3 — `hasSchedule` distinction** (kept for the "no schedule
/// today but compliance history exists" path): when the server reports
/// scheduledToday=0 but the user has prior intakes, the ring still renders
/// with em-dash + "Heute nichts geplant" so the heatmap sparkline below
/// keeps its anchor row.
///
/// **V053-D2 universal sparkline.** Operator feedback ("in den Karten
/// Compliance und Schritte habe ich keinen Graphen drin") asked for a chart
/// in every tile. We surface a 14-day daily-compliance-rate sparkline from
/// `MedicationsStore.compliance` (the same `[ComplianceDay]` already loaded
/// for the Insights → Medication-Compliance-Heatmap surface — no new
/// network request). The chart hides when the schedule is empty or when
/// the store hasn't yet hydrated.
struct ComplianceRingCard: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(MedicationsStore.self) private var medicationsStore
    /// 1.4 B4 — the ring grows with the text (capped), so its "heute" stays
    /// inside the stroke; at the accessibility sizes the numbers move under
    /// the ring instead of wrapping word by word beside it.
    @ScaledMetric(relativeTo: .body) private var scaledRingSide: CGFloat = 92
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: ComplianceSnapshot
    /// **v0.5.6 HOME-COMPLIANCE-SHEET.** Optional tap callback wired by
    /// the dashboard root to present `AnstehendeEinnahmenSheet`. When
    /// `nil`, the card stays non-interactive (previews / snapshot tests).
    /// v0.14.8 AUDIT-HOME H3 — all three dashboard layouts (cards / hero /
    /// list) now wire the tap to the intake sheet.
    let onTap: (() -> Void)?
    /// Trigger value bumped on every tap to drive the haptic via
    /// `.sensoryFeedback(.selection, trigger:)`. Local state so the
    /// parent never has to thread it through.
    @State private var tapTick: Int = 0

    init(snapshot: ComplianceSnapshot, onTap: (() -> Void)? = nil) {
        self.snapshot = snapshot
        self.onTap = onTap
    }

    var body: some View {
        // 1.4 B2 — without any schedule and without any history the card has
        // nothing to say and no action, so it is not there at all (it used to
        // stay as an onboarding sentence for everyone without medications).
        // The loose "Quellen" row under it is gone too: the ring here is
        // monochrome and only counts doses, the method behind the band colours
        // lives on the medication detail where those colours are drawn.
        if !isFullyEmpty {
            contentCard
                .modifier(TappableComplianceModifier(
                    isActive: onTap != nil,
                    tapTick: tapTick,
                    onTap: {
                        tapTick &+= 1
                        onTap?()
                    }
                ))
        }
    }

    private var contentCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // 1.4 B4 — Today's one card heading, the metric tiles' glyph
                // and title, instead of a plain caption beside the ring.
                HLTileHeaderRow(icon: "pills.fill", title: Text(String(localized: "Medication compliance"))) { EmptyView() }
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        ring
                        textColumn
                    }
                } else {
                    HStack(alignment: .center, spacing: HLSpace.lg) {
                        ring
                        textColumn
                        Spacer()
                    }
                }
                if !sparklineValues.isEmpty {
                    HLSparkline(values: sparklineValues, tint: HLText.tertiary)
                        .frame(height: HLChartStyle.heightCompact)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true) // surface conveyed via ring/subtitle copy
                }
            }
        }
    }

    private var ringSide: CGFloat {
        min(scaledRingSide, 160)
    }

    private var ring: some View {
        HLRing(
            progress: snapshot.ratio,
            label: String(localized: "today"),
            value: snapshot.hasSchedule ? "\(snapshot.takenToday)/\(snapshot.scheduledToday)" : "—",
            tint: HLText.primary,
            // Audit H2 — VoiceOver otherwise reads only the bare
            // value ("4 / 6"); frame it as the compliance ring.
            accessibilityLabel: snapshot.ringAccessibilityLabel
        )
        .frame(width: ringSide, height: ringSide)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(snapshot.hasSchedule
                ? String(localized: "\(Self.percentLabel(snapshot.ratio)) today")
                : String(localized: "Nothing scheduled today"))
                .font(.hlTitle2)
                .foregroundStyle(snapshot.hasSchedule ? HLText.primary : HLText.tertiary)
            // v0.6.1.26 — subtitle line carries the calm
            // "X noch offen" / "Alles eingenommen" copy; the
            // overdue suffix renders only when an intake
            // crossed its scheduledAt, picking up the red
            // status-bad tint to draw the attention the
            // top-of-Home banner used to own. 1.4 B2: nothing
            // scheduled has no subtitle, the title says it.
            if let subtitle {
                subtitleRow(subtitle)
            }
        }
    }

    /// **v0.5.5.2** — true when the user has no schedule today AND no
    /// compliance history with non-zero rate. Combines snapshot + store
    /// signals so we don't hide the card for users who have prior intake
    /// history (where the heatmap sparkline below still tells a story).
    private var isFullyEmpty: Bool {
        guard snapshot.scheduledToday == 0, snapshot.takenToday == 0 else { return false }
        // No today-schedule — only hide if compliance history is also flat.
        let hasHistoricalRate = medicationsStore.compliance.contains { $0.rate > 0 }
        return !hasHistoricalRate
    }

    private var subtitle: String? {
        guard snapshot.hasSchedule else { return nil }
        return snapshot.scheduledToday == snapshot.takenToday
            ? String(localized: "All taken — nice.")
            : String(localized: "\(snapshot.scheduledToday - snapshot.takenToday) still open")
    }

    /// "1 still open", with the red "overdue" suffix when the server flags an
    /// open dose as overdue.
    private func subtitleRow(_ subtitle: String) -> some View {
        HStack(spacing: HLSpace.xs) {
            // U5 (1.1.1): a trailing comma joins the overdue suffix, no
            // middle dot.
            Text(verbatim: overdueCount > 0 ? subtitle + "," : subtitle)
                .font(.hlSubhead).foregroundStyle(HLText.secondary)
            if overdueCount > 0 {
                Text(String(localized: "overdue"))
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLColor.statusBad)
            }
        }
    }

    /// v0.6.1.26 — count of today's intakes the SERVER flags as an open
    /// overdue dose. Drives the inline "überfällig" suffix that replaced the
    /// standalone Home-banner. Shares the
    /// `AnstehendeEinnahmenSheet.overdueCount` predicate so banner-era
    /// behaviour and ring-era behaviour can never drift.
    ///
    /// Parity 1.9 — this used to count intakes whose `scheduledAt` had merely
    /// crossed, a client recompute that could disagree with the medication card
    /// (server-flag-driven since b175) sitting one surface away. Both read the
    /// server now.
    private var overdueCount: Int {
        AnstehendeEinnahmenSheet.overdueCount(
            todayIntakes: medicationsStore.derivedTodayIntakes,
            medications: medicationsStore.medications,
            now: .now
        )
    }

    /// Build 273 — the percentage as a finished *argument*, never a literal
    /// `%` inside the localizable string.
    ///
    /// `"\(pct)% today"` produced the key `%lld% today`, and to Foundation the
    /// stray percent is not a literal: `% to` parses as a second specifier
    /// (space flag, `t` length, `o` conversion). German's `%lld% heute` parsed
    /// as `%lld` plus `% he` — a different signature, so the translation was
    /// dropped and German users read "66% today" on the dashboard.
    /// `CatalogFormatSignatureTests` pins the class.
    ///
    /// F1 (1.1.0) — rounded, not truncated: 2 of 3 is "67 %", where
    /// `Int(ratio * 100)` read "66 %". The server sends only the counts for
    /// today (`medsToday.scheduledToday` / `takenToday`), no percentage, so the
    /// ratio of its two counts is the value; `hasSchedule` keeps 0/0 on the
    /// "Nothing scheduled today" copy, never "0 %".
    nonisolated static func percentLabel(_ ratio: Double, locale: Locale = .current) -> String {
        HLNumberFormat.percent(fraction: ratio, locale: locale)
    }

    /// Last-14 daily-compliance-rate as percentages (0-100) sorted ascending
    /// by date. Empty array when the store hasn't loaded or the user has no
    /// schedule history — caller hides the sparkline row in that case so
    /// the card doesn't reserve a blank chart slot.
    private var sparklineValues: [Double] {
        let days = medicationsStore.compliance
        guard !days.isEmpty else { return [] }
        let suffix = days.suffix(14)
        let values = suffix
            .sorted { $0.date < $1.date }
            .map { $0.rate * 100 }
        // All-zeros (no schedule in the whole window) → hide the chart.
        return values.contains(where: { $0 > 0 }) ? values : []
    }
}

/// **v0.5.6 HOME-COMPLIANCE-SHEET.** Wraps the card surface in a Button +
/// pressable style + selection haptic when the dashboard root provides an
/// `onTap` callback. Keeps the non-interactive path identical to pre-v056
/// behaviour for the canonical cards callsite.
private struct TappableComplianceModifier: ViewModifier {
    let isActive: Bool
    let tapTick: Int
    let onTap: () -> Void

    func body(content: Content) -> some View {
        if isActive {
            Button(action: onTap) {
                content
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hlPressable()
            .accessibilityIdentifier("dashboard.complianceRing.tap")
            .accessibilityHint(Text(LocalizedStringKey("dashboard.complianceRing.hint")))
            .sensoryFeedback(.selection, trigger: tapTick)
        } else {
            content
        }
    }
}

// MARK: - Previews

// **Public issue #6 — the 11-dose regimen.** The tester's case: eleven daily
// doses, all taken, so the ring carries the five-glyph value "11/11" over the
// "today" caption. Before the `HLRing` fix this broke as "11/1" + "1" with the
// second line sitting on the caption.
//
// The preview renders the ring in the card's row geometry rather than
// `ComplianceRingCard` itself: the card reads `SettingsStore` and
// `MedicationsStore` out of the environment, and standing those up in a
// preview would mean building the whole repository/API graph. The ring is the
// surface the issue is about, and the layout contract is pinned by
// `HLRingValueLayoutTests`.
#Preview("11/11 regimen (public issue #6)") {
    let snapshot = ComplianceSnapshot(scheduledToday: 11, takenToday: 11)
    return HLCard {
        HStack(alignment: .center, spacing: HLSpace.lg) {
            HLRing(
                progress: snapshot.ratio,
                label: String(localized: "today"),
                value: "\(snapshot.takenToday)/\(snapshot.scheduledToday)",
                tint: HLText.primary,
                accessibilityLabel: snapshot.ringAccessibilityLabel
            )
            .frame(width: 92, height: 92)
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text(String(localized: "Medication compliance"))
                    .font(.hlCaption).foregroundStyle(HLText.secondary)
                Text(String(localized: "\(ComplianceRingCard.percentLabel(snapshot.ratio)) today"))
                    .font(.hlTitle2)
                    .foregroundStyle(HLText.primary)
            }
            Spacer(minLength: 0)
        }
    }
    .padding()
    .background(HLSurface.primary)
}
