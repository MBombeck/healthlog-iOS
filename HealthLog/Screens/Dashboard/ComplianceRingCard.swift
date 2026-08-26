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
        Group {
            if isFullyEmpty {
                emptyStateCard
            } else {
                contentCard
            }
        }
        .modifier(TappableComplianceModifier(
            isActive: onTap != nil && !isFullyEmpty,
            tapTick: tapTick,
            onTap: {
                tapTick &+= 1
                onTap?()
            }
        ))
    }

    private var emptyStateCard: some View {
        // v0.5.5.2 — discrete empty-state hint instead of a hollow
        // ring with em-dash. Keeps the card surface but stops
        // pretending there's data to read.
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text(String(localized: "Medication compliance"))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                Text(String(localized: "No reminders scheduled yet"))
                    .font(.hlTitle3)
                    .foregroundStyle(HLText.primary)
                Text(String(localized: "Add an entry in the Medications tab to see reminders + compliance here."))
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var contentCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HStack(alignment: .center, spacing: HLSpace.lg) {
                    HLRing(
                        progress: snapshot.ratio,
                        label: String(localized: "today"),
                        value: snapshot.hasSchedule ? "\(snapshot.takenToday)/\(snapshot.scheduledToday)" : "—",
                        tint: HLText.primary,
                        // Audit H2 — VoiceOver otherwise reads only the bare
                        // value ("4 / 6"); frame it as the compliance ring.
                        accessibilityLabel: snapshot.ringAccessibilityLabel
                    )
                    .frame(width: 92, height: 92)
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        Text(String(localized: "Medication compliance"))
                            .font(.hlCaption).foregroundStyle(HLText.secondary)
                        Text(snapshot.hasSchedule
                            ? String(localized: "\(Int(snapshot.ratio * 100))% today")
                            : String(localized: "Nothing scheduled today"))
                            .font(.hlTitle2)
                            .foregroundStyle(snapshot.hasSchedule ? HLText.primary : HLText.tertiary)
                        // v0.6.1.26 — subtitle line carries the calm
                        // "X noch offen" / "Alles eingenommen" copy; the
                        // overdue suffix renders only when an intake
                        // crossed its scheduledAt, picking up the red
                        // status-bad tint to draw the attention the
                        // top-of-Home banner used to own.
                        HStack(spacing: HLSpace.xs) {
                            Text(subtitle).font(.hlSubhead).foregroundStyle(HLText.secondary)
                            if overdueCount > 0 {
                                Text("·")
                                    .font(.hlSubhead)
                                    .foregroundStyle(HLText.tertiary)
                                    .accessibilityHidden(true) // decorative separator
                                Text(String(localized: "overdue"))
                                    .font(.hlSubhead.weight(.semibold))
                                    .foregroundStyle(HLColor.statusBad)
                            }
                        }
                    }
                    Spacer()
                    // v0.6.1.3 Y4.1 — Operator-direction: drop the
                    // decorative trailing chevron from the Home
                    // Medikamente row. Tap-affordance stays via the
                    // surrounding TappableComplianceModifier; the
                    // chevron added visual noise without communicating
                    // anything the press-feedback haptic + sheet-on-tap
                    // doesn't already convey.
                }
                if !sparklineValues.isEmpty {
                    HLSparkline(values: sparklineValues, tint: HLText.tertiary)
                        .frame(height: 36)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true) // surface conveyed via ring/subtitle copy
                }
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

    private var subtitle: String {
        guard snapshot.hasSchedule else { return String(localized: "No intakes scheduled for today.") }
        return snapshot.scheduledToday == snapshot.takenToday
            ? String(localized: "All taken — nice.")
            : String(localized: "\(snapshot.scheduledToday - snapshot.takenToday) still open")
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
