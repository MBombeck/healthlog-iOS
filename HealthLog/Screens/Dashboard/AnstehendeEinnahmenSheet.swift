import Pow
import SwiftUI

/// **v0.5.6 HOME-COMPLIANCE-SHEET.** Bottom-sheet presenting today's
/// medication intakes — the operator taps the Compliance ring card on
/// Home, sheet slides up from the bottom with the same data the
/// standalone "Anstehende Einnahmen" card used to surface (now removed).
///
/// **Operator brief (2026-05-22):** "Compliance Kreis Karte finde ich
/// richtig gut. Wenn ich da drauf drücke, möchte ich dass sich von unten
/// sowas öffnet und da drin die anstehenden Einnahmen sind. Auch dass ich
/// sie da drin nehmen kann durch Tap. Auf der Home-Seite müssen die
/// Anstehenden Einnahmen dann nicht mehr sein — oder nur wenn sie
/// überfällig sind."
///
/// **v0.6.1.7 Y7 — Compliance-Haken-Logik (handbook §5.5 / AP-014).**
/// Operator complaint 2026-05-23: "Da haben wir jetzt für Sachen, die man
/// noch nicht genommen hat, einen Haken, und für genommen. Ich hätte
/// gerne einfach einen leeren Kreis: Wenn ich da reinklicke, ist da ein
/// Haken." The prior layout rendered a `checkmark`-glyph pill on the
/// pending row + a `checkmark.circle.fill` on the taken row — both
/// states wore a Haken, which read as "already done" the moment the
/// sheet opened. Y7 drops the pill, surfaces an empty `circle` glyph as
/// the default tap target, and flips it to `checkmark.circle.fill` in
/// `HLColor.statusOK` on the optimistic mark. The Pow `.spray` + success
/// haptic mirrors the Y4.1 MedicationCard's Genommen micro-interaction
/// language so the felt-quality stays consistent across surfaces.
///
/// **Rules:**
///
/// - Detents: `.medium` + `.large` with drag indicator, so the operator
///   can grow the sheet to the full screen when the day has many doses.
/// - Title bar: "Anstehende Einnahmen" plus a "Heute, X von Y noch offen"
///   subtitle counted live from the snapshot.
/// - Rows: pill SF Symbol + name/dose + scheduled-time chip, trailing
///   empty-circle tap target. Tap flips to a green checkmark with a
///   Pow `.spray` flourish + `.success` haptic; already-marked rows
///   render disabled with the status icon (checkmark/skipped) on the
///   right.
/// - Empty state: SF Symbol + copy when the day carries no intakes.
/// - Action calls `MedicationsStore.markIntakeQuick(intakeId:status:.taken)`
///   — the store handles optimistic patch + outbox + writeThrough.
struct AnstehendeEinnahmenSheet: View {
    @Environment(MedicationsStore.self) private var store
    /// Trigger value bumped each time the operator marks an intake — wired
    /// to `.sensoryFeedback(.success, trigger:)` so the taptic plays
    /// exactly once per successful tap, never on initial appear or sheet
    /// dismissal.
    @State private var markedTick: Int = 0
    /// **v0.11 #60** — pending injection-site capture for the Dashboard quick
    /// take path. Set when the operator taps the take-circle on an
    /// `injectionSiteCaptureEnabled` row; the capture sheet supplies the site
    /// and only then is the dose recorded WITH it (web parity). Oral rows
    /// record immediately with no popup.
    @State private var siteCaptureTarget: QuickSiteCapture?
    /// Optional clock-injection seam for previews / tests. Captured on
    /// every body evaluation so the "X von Y noch offen" subtitle stays
    /// live as the day progresses (the user can leave the sheet open).
    private let now: () -> Date

    init(now: @escaping () -> Date = { .now }) {
        self.now = now
    }

    var body: some View {
        let snapshot = Self.makeSnapshot(
            todayIntakes: store.derivedTodayIntakes,
            medications: store.medications,
            now: now()
        )
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    subtitle(for: snapshot)
                    if snapshot.rows.isEmpty {
                        emptyState
                    } else {
                        rows(for: snapshot)
                    }
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.sm)
                .padding(.bottom, HLSpace.xl)
            }
            .hlScreenBackground()
            .navigationTitle(Text(LocalizedStringKey("dashboard.intakesSheet.title")))
            .navigationBarTitleDisplayMode(.inline)
            // v0.6.1 Y2 — Home-Compliance pattern: drop the topBarTrailing
            // X-button (`docs/design-handbook-v1.md §2.6 / D-001`). The
            // drag-indicator + swipe-down is the only dismiss path.
        }
        .hlSheetPresentation(.standard)
        .presentationBackground(HLColor.surface)
        .sensoryFeedback(.success, trigger: markedTick)
        // v0.11 #60 — injection-site capture interstitial for the Dashboard
        // quick take. Presented only for `injectionSiteCaptureEnabled` rows;
        // the chosen site rides into the same `markIntakeQuick` path so the
        // optimistic-write + Outbox semantics are preserved.
        .sheet(item: $siteCaptureTarget) { target in
            IntakeSiteCaptureSheet(
                medication: target.medication,
                onConfirm: { site in
                    let captured = target
                    siteCaptureTarget = nil
                    Task { await markTaken(intakeId: captured.intakeId, injectionSite: site) }
                },
                onCancel: { siteCaptureTarget = nil }
            )
        }
    }

    // MARK: - Subtitle

    private func subtitle(for snapshot: Snapshot) -> some View {
        Text(snapshot.subtitleKey)
            .font(.hlSubhead)
            .foregroundStyle(HLText.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("dashboard.intakesSheet.subtitle")
    }

    // MARK: - Empty

    /// Canonical `HLEmptyState` lockup (audit-01 C1). The existing localized
    /// keys stay so the copy is unchanged.
    private var emptyState: some View {
        HLEmptyState(
            icon: "pills.fill",
            title: "dashboard.intakesSheet.empty.title",
            message: "dashboard.intakesSheet.empty.subtitle"
        )
        .accessibilityIdentifier("dashboard.intakesSheet.empty")
    }

    // MARK: - Rows

    private func rows(for snapshot: Snapshot) -> some View {
        VStack(spacing: HLSpace.sm) {
            ForEach(snapshot.rows) { row in
                IntakeRow(row: row) {
                    handleMarkTaken(row: row)
                }
            }
        }
    }

    /// **v0.11 #60** — for an injection-tracked med, capture a site before
    /// recording (web parity); for an oral med record immediately as before.
    private func handleMarkTaken(row: SheetRow) {
        if row.medication.injectionSiteCaptureEnabled {
            siteCaptureTarget = QuickSiteCapture(intakeId: row.intake.id, medication: row.medication)
            return
        }
        Task { await markTaken(intakeId: row.intake.id, injectionSite: nil) }
    }

    private func markTaken(intakeId: String, injectionSite: InjectionSite?) async {
        let outcome = await store.markIntakeQuick(
            intakeId: intakeId,
            status: .taken,
            injectionSite: injectionSite
        )
        if case .failed = outcome { return }
        markedTick &+= 1
    }
}

// MARK: - Row

private struct IntakeRow: View {
    let row: AnstehendeEinnahmenSheet.SheetRow
    let onMark: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// **Y7.** Per-row pulse driver — bumped exactly when the operator
    /// taps the empty-circle tap-target. Wired to a Pow `.spray` change-
    /// effect on the trailing glyph + a `.sensoryFeedback(.success)` so
    /// the felt-quality matches the Y4.1 MedicationCard's Genommen
    /// micro-interaction (`HealthLog/Screens/Medications/ActiveMedicationRow.swift`,
    /// `actionButtons`). The sheet-level `markedTick` already drives a
    /// global success haptic on every successful mark — the per-row
    /// trigger here is dedicated to the visual spray so the particles
    /// fire at the row's centre, not at the sheet root.
    @State private var pulseTick: Int = 0

    var body: some View {
        HLCard(style: .standard) {
            HStack(spacing: HLSpace.md) {
                // Y8: drop the per-row Circle().fill(surfaceElevated)
                // backplate (handbook §2.6 wants flat row chrome) + swap
                // the .tint reading to an explicit HLText.primary so the
                // glyph doctrine stays mono regardless of any future
                // nested .tint(...) modifier.
                Image(systemName: "pills.fill")
                    .font(.hlIcon(HLIconSize.lg))
                    .foregroundStyle(HLText.primary)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(row.medication.name)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    HStack(spacing: HLSpace.sm) {
                        Text(row.medication.dose)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                        Text(row.scheduledLabel)
                            .font(.hlSubhead)
                            .foregroundStyle(row.isOverdue ? HLColor.statusBad : HLText.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: HLSpace.sm)
                trailing
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("dashboard.intakesSheet.row.\(row.intake.id)")
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(LocalizedStringKey("dashboard.intakesSheet.row.hint")))
    }

    /// **Y7.** Trailing glyph derived from a pure presentation descriptor
    /// so the contract is unit-testable without spinning up SwiftUI. The
    /// `.pending` case is the only branch that wires a tap — every other
    /// branch is a static read-only status indicator.
    @ViewBuilder
    private var trailing: some View {
        let presentation = AnstehendeEinnahmenSheet.TrailingPresentation
            .resolve(status: row.intake.status, isFutureScheduled: row.isFutureTaken)
        switch row.intake.status {
        case .pending:
            Button(action: handleMark) {
                Image(systemName: presentation.symbolName)
                    .font(.hlIcon(HLIconSize.hero, weight: .regular))
                    .foregroundStyle(presentation.tintColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hlPressable()
            .changeEffect(
                .spray(origin: UnitPoint.center) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(HLColor.statusOK)
                },
                value: pulseTick,
                isEnabled: !reduceMotion
            )
            .sensoryFeedback(.success, trigger: pulseTick)
            .accessibilityIdentifier("dashboard.intakesSheet.action.\(row.intake.id)")
            .accessibilityLabel(Text(LocalizedStringKey(presentation.accessibilityLabelKey)))
        default:
            Image(systemName: presentation.symbolName)
                .font(.hlIcon(HLIconSize.hero, weight: .regular))
                .foregroundStyle(presentation.tintColor)
                .frame(width: 44, height: 44)
                .accessibilityLabel(Text(LocalizedStringKey(presentation.accessibilityLabelKey)))
        }
    }

    private func handleMark() {
        pulseTick &+= 1
        onMark()
    }
}

// MARK: - Trailing presentation contract

extension AnstehendeEinnahmenSheet {
    /// **Y7.** Pure descriptor of the trailing glyph rendered for a given
    /// `IntakeStatus`. Hoisted out of the row view so the symbol-name +
    /// tint + accessibility key contract can be locked in a unit test
    /// without a SwiftUI host. The view body reads from this exact
    /// descriptor, so a key rename here surfaces in the test diff.
    ///
    /// - `.pending` — empty `circle` (operator wants no Haken until the
    ///   dose is actually taken). Tap target lives on the row, the glyph
    ///   sits in `HLText.tertiary`.
    /// - `.taken` — `checkmark.circle.fill` in `HLColor.statusOK` (the
    ///   canonical signal-green per handbook §1.2).
    /// - `.skipped` — outlined `xmark.circle` in `HLText.secondary` so
    ///   skipped reads as "explicitly not taken" (distinct from a missed
    ///   dose which the Verlauf track renders as `circle`).
    /// - `.snoozed` — `moon.zzz` outlined in `HLText.tertiary` so the
    ///   sleep semantic stays distinct from the destructive skip.
    struct TrailingPresentation: Equatable {
        let symbolName: String
        let tint: HLTrailingTint
        let accessibilityLabelKey: String

        /// - Parameter isFutureScheduled: **v0.14.1 DOSE-SAFETY.** When `true`
        ///   the intake is `.taken` but its `scheduledAt` is still in the
        ///   future relative to `now`. Such a dose has not actually been taken
        ///   yet (the server can stamp a not-yet-due slot `taken` via its ±6h
        ///   explicit-write snap, or a clock-skew edge), so it must render the
        ///   neutral empty-circle "upcoming" glyph — NEVER the green checkmark.
        ///   Defaults to `false` so the status-only contract is unchanged. See
        ///   `.planning/v0148-cycle-marathon/INV-med-phantom-taken.md`.
        nonisolated static func resolve(
            status: IntakeStatus,
            isFutureScheduled: Bool = false
        ) -> TrailingPresentation {
            // A future-scheduled `.taken` dose cannot have been taken yet —
            // present it as an upcoming dose (empty circle), never as done.
            if status == .taken, isFutureScheduled {
                return TrailingPresentation(
                    symbolName: "circle",
                    tint: .tertiary,
                    accessibilityLabelKey: "dashboard.intakesSheet.status.upcoming"
                )
            }
            switch status {
            case .pending:
                return TrailingPresentation(
                    symbolName: "circle",
                    tint: .tertiary,
                    accessibilityLabelKey: "dashboard.intakesSheet.action.markTaken"
                )
            case .taken:
                return TrailingPresentation(
                    symbolName: "checkmark.circle.fill",
                    tint: .statusOK,
                    accessibilityLabelKey: "dashboard.intakesSheet.status.taken"
                )
            case .skipped:
                return TrailingPresentation(
                    symbolName: "xmark.circle",
                    tint: .secondary,
                    accessibilityLabelKey: "dashboard.intakesSheet.status.skipped"
                )
            case .snoozed:
                return TrailingPresentation(
                    symbolName: "moon.zzz",
                    tint: .tertiary,
                    accessibilityLabelKey: "dashboard.intakesSheet.status.snoozed"
                )
            case .missed:
                // Server-terminal and deliberately non-interactive: a missed
                // slot remains visible as missed but can never masquerade as a
                // pending dose or expose the mark-taken button.
                return TrailingPresentation(
                    symbolName: "xmark.circle.fill",
                    tint: .statusBad,
                    accessibilityLabelKey: "med.heatmap.status.missed"
                )
            }
        }
    }

    /// Token-typed tint so the descriptor stays `Sendable` and tests can
    /// assert against the design-token name instead of an opaque
    /// `ShapeStyle`. The view layer maps this back to the live colour at
    /// render time.
    enum HLTrailingTint: Equatable {
        case statusOK
        case statusBad
        case secondary
        case tertiary

        var color: Color {
            switch self {
            case .statusOK: HLColor.statusOK
            case .statusBad: HLColor.statusBad
            case .secondary: HLText.secondary
            case .tertiary: HLText.tertiary
            }
        }
    }
}

extension AnstehendeEinnahmenSheet.TrailingPresentation {
    /// Convenience so the view body reads `presentation.tintColor` as a
    /// `Color` without each call-site spelling `presentation.tint.color`.
    var tintColor: Color {
        tint.color
    }
}

// MARK: - Snapshot + pure helpers

extension AnstehendeEinnahmenSheet {
    struct SheetRow: Identifiable, Hashable {
        let intake: MedicationIntake
        let medication: Medication
        let scheduledLabel: String
        let isOverdue: Bool
        /// **v0.14.1 DOSE-SAFETY.** `true` when this row is `.taken` but its
        /// `scheduledAt` is still in the FUTURE relative to `now`. Such a row
        /// must NOT paint the taken checkmark — a dose due later cannot have
        /// been taken (the server's ±6h afternoon→19:00 snap, or a clock-skew
        /// edge, can stamp a not-yet-due slot `taken`). It renders + sorts as
        /// an upcoming-pending dose instead so the evening dose is never masked
        /// as done. See
        /// `.planning/v0148-cycle-marathon/INV-med-phantom-taken.md`.
        let isFutureTaken: Bool

        var id: String {
            intake.id
        }
    }

    struct Snapshot: Equatable {
        let rows: [SheetRow]
        let pendingCount: Int
        let totalCount: Int

        /// "Heute, X von Y noch offen" / "Heute keine Einnahmen geplant".
        /// Returned as a `LocalizedStringKey`-compatible String so the
        /// view can render it directly via `LocalizedStringKey(_:)` —
        /// the dynamic interpolation goes through `Localizable.xcstrings`
        /// via the `String(format:)` bridge.
        var subtitleKey: String {
            if totalCount == 0 {
                return String(localized: "dashboard.intakesSheet.subtitle.empty")
            }
            let fmt = NSLocalizedString("dashboard.intakesSheet.subtitle.count", comment: "")
            return String(format: fmt, pendingCount, totalCount)
        }
    }

    /// Pure snapshot builder — joins today's intakes against the
    /// medication catalog, sorts overdue/pending first, then by scheduled
    /// time. Mirrors the same calendar-day window the standalone card
    /// used. `nonisolated` so test contexts can call without
    /// `@MainActor` inheritance.
    nonisolated static func makeSnapshot(
        todayIntakes: [MedicationIntake],
        medications: [Medication],
        now: Date,
        calendar: Calendar = .current
    ) -> Snapshot {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let medsById = Dictionary(uniqueKeysWithValues: medications.map { ($0.id, $0) })
        let todayRows: [SheetRow] = todayIntakes
            .filter { $0.scheduledAt >= startOfToday && $0.scheduledAt < endOfToday }
            .compactMap { intake -> SheetRow? in
                guard let med = medsById[intake.medicationId], med.active else { return nil }
                return SheetRow(
                    intake: intake,
                    medication: med,
                    scheduledLabel: intake.scheduledAt.formatted(.dateTime.hour().minute()),
                    // Parity 1.9 — overdue is the SERVER's verdict, not ours.
                    // This used to read `intake.scheduledAt < now`, a pure
                    // client recompute of a value the server already computes
                    // and ships (`nextDueOverdue`, `verdict.ts:157-163`) —
                    // against the project's own server-ledger doctrine, and
                    // able to disagree with the medication card sitting one
                    // surface away (which has honoured the flag since b175).
                    // A wall-clock comparison also cannot see a catch-up band:
                    // it called every passed slot overdue, including ones the
                    // server has already closed.
                    isOverdue: intake.status == .pending
                        && med.isServerFlaggedOverdueSlot(intake.scheduledAt),
                    // DOSE-SAFETY: a `.taken` row scheduled later than `now` is
                    // not actually taken yet — flag it so the trailing glyph +
                    // sort treat it as an upcoming dose, never a done one.
                    isFutureTaken: intake.status == .taken && intake.scheduledAt > now
                )
            }
            .sorted { lhs, rhs in
                /// Overdue-pending first (earliest leading), then pending
                /// upcoming (chronological), then taken/skipped collapsed
                /// to the bottom in chronological order.
                func rank(_ row: SheetRow) -> Int {
                    if row.intake.status == .pending, row.isOverdue { return 0 }
                    // DOSE-SAFETY: a future-taken row is shown as an upcoming
                    // dose (not yet done), so it sorts with pending-upcoming.
                    if row.intake.status == .pending || row.isFutureTaken { return 1 }
                    return 2
                }
                let lr = rank(lhs)
                let rr = rank(rhs)
                if lr != rr { return lr < rr }
                return lhs.intake.scheduledAt < rhs.intake.scheduledAt
            }
        let pending = todayRows.filter { $0.intake.status == .pending }.count
        return Snapshot(
            rows: todayRows,
            pendingCount: pending,
            totalCount: todayRows.count
        )
    }

    /// Overdue convenience used by `ComplianceRingCard` so the tile +
    /// sheet share the same predicate.
    nonisolated static func overdueCount(
        todayIntakes: [MedicationIntake],
        medications: [Medication],
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        let snapshot = makeSnapshot(
            todayIntakes: todayIntakes,
            medications: medications,
            now: now,
            calendar: calendar
        )
        return snapshot.rows.filter(\.isOverdue).count
    }
}
