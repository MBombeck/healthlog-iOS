import SwiftUI

/// Medication-compliance ring tile for the Dashboard's `.cards` layout.
///
/// **Hide-empty contract**: when
/// the server reports no scheduled intakes today AND no doses taken,
/// the ring renders nothing useful — the previous `"—" / "Heute nichts
/// geplant"` copy still claimed the card slot, leaving a hollow ring
/// painted on the dashboard for users who haven't added any medications
/// yet. We now collapse the card to a discrete empty-state hint pointing
/// the user at the Medikamente tab; the dashboard reclaims the vertical
/// space when nothing's scheduled.
///
/// **`hasSchedule` distinction** (kept for the "no schedule
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
    /// The ring grows with the text (capped), so its count stays inside the
    /// stroke; at the accessibility sizes the numbers move under the ring
    /// instead of wrapping word by word beside it.
    @ScaledMetric(relativeTo: .body) private var scaledRingSide: CGFloat = 92
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: ComplianceSnapshot
    /// Optional tap callback wired by
    /// the dashboard root to present `AnstehendeEinnahmenSheet`. When
    /// `nil`, the card stays non-interactive (previews / snapshot tests).
    /// All three dashboard layouts (cards / hero /
    /// list) now wire the tap to the intake sheet.
    let onTap: (() -> Void)?
    /// #182 A8 (server v1.48) — the day's slot instants
    /// (`medsToday.scheduledTodayAt`); `nil` from an older server, and then
    /// the card says nothing about the next doses.
    let scheduledTodayAt: [Date]?
    /// #191 point 10 — the open doses of today from the resolved `state` on
    /// today's rows (`upcoming`, `due` or `overdue`, ordered by `dueAt`).
    /// `nil` while the server resolves no state; then `scheduledTodayAt`.
    let openDoses: [Date]?
    /// 1.7: the open doses of the confirmed today rows; `nil` while only the
    /// summary is known.
    let openToday: Int?

    init(
        snapshot: ComplianceSnapshot,
        openToday: Int? = nil,
        scheduledTodayAt: [Date]? = nil,
        openDoses: [Date]? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.openToday = openToday
        self.scheduledTodayAt = scheduledTodayAt
        self.openDoses = openDoses
        self.onTap = onTap
    }

    var body: some View {
        // Without any schedule and without any history the card has
        // nothing to say and no action, so it is not there at all (it used to
        // stay as an onboarding sentence for everyone without medications).
        // The loose "Quellen" row under it is gone too: the ring here is
        // monochrome and only counts doses, the method behind the band colours
        // lives on the medication detail where those colours are drawn.
        if !isFullyEmpty {
            contentCard
                .modifier(TappableComplianceModifier(isActive: onTap != nil) { onTap?() })
        }
    }

    private var contentCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // Today's one card heading, the metric tiles' glyph
                // and title, instead of a plain caption beside the ring.
                HLTileHeaderRow(icon: "pills.fill", title: Text(String(localized: "Medication compliance"))) { EmptyView() }
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        ring
                        textColumn
                    }
                } else {
                    HStack(alignment: .center, spacing: HLLayout.cardGap) {
                        ring
                        textColumn
                        Spacer()
                    }
                }
                if !sparklineValues.isEmpty {
                    HLSparkline(values: sparklineValues)
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
        // The ring carries the count only, like the score ring: "today"
        // stands once, beside it.
        HLRing(
            // 1.7: no count of taken doses before they are confirmed.
            progress: unconfirmed ? 0 : snapshot.ratio,
            value: snapshot.hasSchedule && !unconfirmed ? "\(snapshot.takenToday)/\(snapshot.scheduledToday)" : "—",
            tint: HLText.primary,
            // Audit H2 — VoiceOver otherwise reads only the bare
            // value ("4 / 6"); frame it as the compliance ring.
            accessibilityLabel: snapshot.ringAccessibilityLabel
        )
        .frame(width: ringSide, height: ringSide)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            // The card's lead value as a tile value: the percentage in the
            // tile face, "today" in its unit face on the same baseline.
            if snapshot.hasSchedule {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                    Text(verbatim: unconfirmed ? "—" : Self.percentLabel(snapshot.ratio))
                        .font(HLValueSize.tile.numberFont)
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                    Text(String(localized: "today"))
                        .font(HLValueSize.tile.unitFont)
                        .foregroundStyle(HLText.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                HLEmptyNote(Text(String(localized: "Nothing scheduled today")))
            }
            // Subtitle line carries the calm
            // "X noch offen" / "Alles eingenommen" copy; the
            // overdue suffix renders only when an intake
            // crossed its scheduledAt, picking up the red
            // status-bad tint to draw the attention the
            // top-of-Home banner used to own. Nothing
            // scheduled has no subtitle, the title says it.
            if let subtitle {
                subtitleRow(subtitle)
            }
            if let nextDoses = Self.nextDosesLine(
                Self.shownNextDoses(
                    openDoses: openDoses,
                    fallback: Self.upcomingSlots(scheduledTodayAt, snapshot: snapshot, now: .now),
                    unconfirmed: medicationsStore.isDoseStateUnconfirmed,
                    now: .now
                )
            ) {
                Text(verbatim: nextDoses)
                    .hlText(.rowSubtitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dashboard.compliance.nextDoses")
            }
        }
    }

    /// The slots still ahead today, at most `limit`, each instant once. Empty
    /// while nothing is open (all taken) or without the server's slots.
    /// Nothing is scheduled here: the instants are the server's.
    nonisolated static func upcomingSlots(
        _ slots: [Date]?,
        snapshot: ComplianceSnapshot,
        now: Date,
        limit: Int = 3
    ) -> [Date] {
        guard let slots, snapshot.hasSchedule, snapshot.takenToday < snapshot.scheduledToday else { return [] }
        var seen = Set<Date>()
        return Array(slots.filter { $0 > now && seen.insert($0).inserted }.prefix(limit))
    }

    /// **#191 point 10 — which doses are open, as the server resolved them.**
    /// The slots of today's rows whose `state` is `upcoming`, `due` or
    /// `overdue`, ordered by `dueAt`, each instant once. `nil` when no row
    /// carries a state (an older server, or the capability shut): the caller
    /// then falls back to `medsToday.scheduledTodayAt`. Taken, skipped and
    /// missed doses are never "next".
    nonisolated static func openDoseSlots(
        _ todayIntakes: [MedicationIntake],
        enabled: Bool = MedicationServerResolvedSlots.isAvailable()
    ) -> [Date]? {
        guard enabled else { return nil }
        let resolved = todayIntakes.compactMap { intake -> OpenDoseSlot? in
            guard let state = intake.doseState,
                  let phase = MedicationDosePhase(wire: state.state, takenLate: state.takenLate) else { return nil }
            let slot = state.slotInstant ?? intake.scheduledAt
            return OpenDoseSlot(slot: slot, due: state.dueAt ?? slot, phase: phase)
        }
        guard !resolved.isEmpty else { return nil }
        var seen = Set<Date>()
        return resolved
            .filter(\.phase.isUpcomingOrDue)
            .sorted { $0.due == $1.due ? $0.slot < $1.slot : $0.due < $1.due }
            .map(\.slot)
            .filter { seen.insert($0).inserted }
    }

    /// **1.7** — the times the card names. While today's doses are not
    /// confirmed only times still ahead: a past "next dose" would say it is
    /// open.
    nonisolated static func shownNextDoses(openDoses: [Date]?, fallback: [Date], unconfirmed: Bool, now: Date) -> [Date] {
        let slots = openDoses.map { Array($0.prefix(3)) } ?? fallback
        return unconfirmed ? slots.filter { $0 > now } : slots
    }

    /// One today row reduced to what ``openDoseSlots(_:enabled:)`` sorts on.
    struct OpenDoseSlot {
        let slot: Date
        let due: Date
        let phase: MedicationDosePhase
    }

    /// "Next dose 13:00" / "Next doses 13:00, 20:00", in the app's clock.
    static func nextDosesLine(_ slots: [Date], time: (Date) -> String = { HLTimeFormat.time($0) }) -> String? {
        guard !slots.isEmpty else { return nil }
        let times = slots.map(time).joined(separator: ", ")
        return slots.count == 1
            ? String(localized: "dashboard.compliance.nextDose \(times)")
            : String(localized: "dashboard.compliance.nextDoses \(times)")
    }

    /// True when the user has no schedule today AND no
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
        Self.subtitle(snapshot: snapshot, openToday: openToday, unconfirmed: unconfirmed)
    }

    private var unconfirmed: Bool {
        medicationsStore.isDoseStateUnconfirmed
    }

    /// 1.7: the ring's counts, from the confirmed today rows when the store
    /// has them, else the summary.
    nonisolated static func snapshot(summary: ComplianceSnapshot, state: MedicationTodayState) -> ComplianceSnapshot {
        if case let .confirmed(count) = state, count.scheduled > 0 { return count.snapshot }
        return summary
    }

    nonisolated static func openToday(state: MedicationTodayState) -> Int? {
        if case let .confirmed(count) = state, count.scheduled > 0 { return count.open }
        return nil
    }

    /// The line under the percentage. **1.7:** while today's doses are not
    /// confirmed it counts the day's doses and says nothing about which are
    /// open; the line stays, so nothing moves when the answer lands.
    nonisolated static func subtitle(snapshot: ComplianceSnapshot, openToday: Int? = nil, unconfirmed: Bool) -> String? {
        guard snapshot.hasSchedule else { return nil }
        if unconfirmed { return String(localized: "dashboard.compliance.dosesToday \(snapshot.scheduledToday)") }
        if let openToday {
            return openToday == 0 ? String(localized: "All taken — nice.") : String(localized: "\(openToday) still open")
        }
        return snapshot.scheduledToday == snapshot.takenToday
            ? String(localized: "All taken — nice.")
            : String(localized: "\(snapshot.scheduledToday - snapshot.takenToday) still open")
    }

    /// "1 still open", with the red "overdue" suffix when the server flags an
    /// open dose as overdue.
    private func subtitleRow(_ subtitle: String) -> some View {
        HStack(spacing: HLSpace.xs) {
            // A trailing comma joins the overdue suffix, no
            // middle dot.
            Text(verbatim: overdueCount > 0 ? subtitle + "," : subtitle)
                .font(.hlSubhead).foregroundStyle(HLText.secondary)
            if overdueCount > 0 {
                HLBadge(String(localized: "overdue"), tone: .critical, form: .text)
            }
        }
    }

    /// Count of today's intakes the SERVER flags as an open
    /// overdue dose. Drives the inline "überfällig" suffix that replaced the
    /// standalone Home-banner. Shares the
    /// `AnstehendeEinnahmenSheet.overdueCount` predicate so banner-era
    /// behaviour and ring-era behaviour can never drift.
    ///
    /// This used to count intakes whose `scheduledAt` had merely
    /// crossed, a client recompute that could disagree with the medication card
    /// (server-flag-driven since b175) sitting one surface away. Both read the
    /// server now.
    private var overdueCount: Int {
        // 1.7: no overdue mark on a dose state that is not confirmed.
        guard !medicationsStore.isDoseStateUnconfirmed else { return 0 }
        return AnstehendeEinnahmenSheet.overdueCount(
            todayIntakes: medicationsStore.derivedTodayIntakes,
            medications: medicationsStore.medications,
            now: .now
        )
    }

    /// Whether the hero above already names today's medications. Then this
    /// card would say the same a second time, and Home leaves it out; the
    /// hero's fact opens the same intake sheet.
    static func heroNamesMedications(_ digest: DailyDigest?) -> Bool {
        guard let digest, !digest.isEmptyDegrade else { return false }
        return TodayHeroFacts.facts(digest).contains { fact in
            fact.kind == "medication" || fact.kind == "medications" || fact.moduleKey == "medications"
        }
    }

    /// The percentage as a finished *argument*, never a literal
    /// `%` inside the localizable string.
    ///
    /// `"\(pct)% today"` produced the key `%lld% today`, and to Foundation the
    /// stray percent is not a literal: `% to` parses as a second specifier
    /// (space flag, `t` length, `o` conversion). German's `%lld% heute` parsed
    /// as `%lld` plus `% he` — a different signature, so the translation was
    /// dropped and German users read "66% today" on the dashboard.
    /// `CatalogFormatSignatureTests` pins the class.
    ///
    /// Rounded, not truncated: 2 of 3 is "67 %", where
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

/// Wraps the card surface in a Button with the
/// pressable style (press feedback and its selection haptic) when the dashboard root provides an
/// `onTap` callback. Keeps the non-interactive path identical to pre-v056
/// behaviour for the canonical cards callsite.
private struct TappableComplianceModifier: ViewModifier {
    let isActive: Bool
    let onTap: () -> Void

    func body(content: Content) -> some View {
        if isActive {
            Button(action: onTap) {
                content
                    .contentShape(Rectangle())
            }
            .hlPressable(hover: .lift)
            .accessibilityIdentifier("dashboard.complianceRing.tap")
            .accessibilityHint(Text(LocalizedStringKey("dashboard.complianceRing.hint")))
        } else {
            content
        }
    }
}

// MARK: - Previews

// **Public issue #6 — the 11-dose regimen.** The tester's case: eleven daily
// doses, all taken, so the ring carries the five-glyph value "11/11". Before
// the `HLRing` fix this broke as "11/1" + "1" over two lines.
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
        HStack(alignment: .center, spacing: HLLayout.cardGap) {
            HLRing(
                progress: snapshot.ratio,
                value: "\(snapshot.takenToday)/\(snapshot.scheduledToday)",
                tint: HLText.primary,
                accessibilityLabel: snapshot.ringAccessibilityLabel
            )
            .frame(width: 92, height: 92)
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text(String(localized: "Medication compliance"))
                    .font(.hlCaption).foregroundStyle(HLText.secondary)
                Text(verbatim: ComplianceRingCard.percentLabel(snapshot.ratio))
                    .font(HLValueSize.tile.numberFont)
                    .foregroundStyle(HLText.primary)
            }
            Spacer(minLength: 0)
        }
    }
    .padding()
    .background(HLSurface.primary)
}
