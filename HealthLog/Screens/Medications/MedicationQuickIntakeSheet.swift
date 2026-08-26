import SwiftUI

/// **v0.5.3-EQ-1.** Direct intake-confirm flow for the Erfassen →
/// Medikamenteneinnahme path.
///
/// **Operator feedback (V0.5.2 walkthrough EQ-1):**
///
/// > "Ich kann es auch nicht mehr bearbeiten, wenn ich es da aus
/// > versehen drauf gedrückt habe oder so. Da fehlt mir auf jeden Fall
/// > Logik."
///
/// Previously the picker row routed to the Meds *list* (`MedicationsScreen`)
/// — the operator had to scroll to find their pending intake, tap the
/// row's leading ✓ which fired immediately with no confirm step. If a
/// user mis-tapped there was no obvious back-out path other than
/// swiping the same row to `.skipped`. From the central Erfassen CTA the
/// operator expected a *committed* intake-mark, not a navigation away.
///
/// New flow:
///
/// 1. **Zero actionable intakes** — render an empty state ("no doses
///    pending right now"). The operator gets clear "nothing to log"
///    feedback rather than an unexplained empty Today list.
/// 2. **Exactly one actionable intake** — open straight on the confirm
///    screen for that intake (skip the picker step). One tap less for
///    the common case (most users have 1-2 pending meds at any moment).
/// 3. **Multiple actionable intakes** — render a chooser list; tapping
///    a row navigates to the confirm screen for that intake.
///
/// The **confirm screen** is the back-out gate: medication name + dose
/// + scheduled time + a single primary "Als genommen markieren" CTA + a
/// `.cancellationAction` button. Taps fire the optimistic mark via
/// `MedicationsStore.markIntakeQuick`; on `.queued` we route the
/// queued-banner state up to the parent (Dashboard / MeasureSheet host)
/// via `onSavedOutcome`, on `.failed` we surface the error inline. On
/// `.success` we dismiss back to the underlying tab.
///
/// "Actionable" mirrors `MedicationQuickMarkState.actionable(intakeId:)`
/// resolution: pending today-intake with `scheduledAt <= now`, earliest
/// first. Upcoming (`scheduledAt > now`) intakes are not surfaced in
/// the picker — the operator's mental model for the central CTA is "log
/// the dose I already took", not "schedule something for later".
struct MedicationQuickIntakeSheet: View {
    @Environment(MedicationsStore.self) private var store
    let onDismiss: () -> Void
    /// Bubbled up so the host can surface the `.queued` banner consistent
    /// with `MedicationsScreen.QuickMarkQueuedBanner`. Optional —
    /// `MedicationsStore.markIntakeQuick` already populates `store.error`
    /// for `.failed`, so the host doesn't strictly need this hook for
    /// hard errors.
    var onQueued: () -> Void = {}

    @State private var path: NavigationPath = .init()
    /// H4 — true while the batch take-all is in flight (disables the button).
    @State private var isBatchConfirming = false
    /// H4 — populated with the batch tally to surface a result alert.
    @State private var batchResult: MedicationsStore.BatchIntakeOutcome?
    /// B6 — the as-needed medication whose ad-hoc write is in flight, so the
    /// row can say so and a second tap cannot double-record.
    @State private var recordingAsNeededID: String?

    /// What this sheet offers, resolved at render time so the list refreshes
    /// when the store reloads in the background.
    ///
    /// **W-MED2:** reads `derivedTodayIntakes` so synthesised placeholders
    /// surface as due rows even when the server has not yet materialised the
    /// intake event (the reminder worker only pre-creates RED-phase rows; the
    /// operator's pre-RED window previously rendered the "Keine offene
    /// Einnahme" empty state for the entire morning + evening cadence).
    private var options: MedicationQuickIntakeOptions {
        MedicationQuickIntakeOptions.resolve(
            medications: store.medications,
            intakes: store.derivedTodayIntakes,
            now: .now
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(Text("meds.quick.title"))
                .navigationBarTitleDisplayMode(.inline)
                // v0.6.1 Y2 — Home-Compliance pattern: drop the
                // 'Abbrechen' cancellationAction toolbar. Drag-down
                // dismisses the chooser; the confirm-screen still keeps
                // its own explicit cancel/confirm pair because that's a
                // destructive commit, not the sheet chrome.
                .navigationDestination(for: IntakeOption.self) { option in
                    MedicationQuickIntakeConfirm(
                        option: option,
                        onCommitOutcome: handleOutcome,
                        onCancel: onDismiss
                    )
                }
                // Build 6.1 — free / back-dated logging, always reachable so the
                // operator can log a dose even when nothing is due right now.
                .navigationDestination(for: FreeIntakeRoute.self) { _ in
                    MedicationFreeIntakeSheet(
                        preselectedMedicationID: nil,
                        onDone: handleOutcome
                    )
                }
        }
        .task {
            // CU-24 — the empty state distinguishes "no medication exists" from
            // "nothing due right now", so the medication list has to be
            // hydrated before either claim is painted. Cheap: a no-op whenever
            // the tab / dashboard already loaded it.
            if !store.hasLoadedMedications {
                await store.load()
            }
            autoAdvanceIfSingle()
        }
        // v0.5.5.1 — HIG Befund 4: half-sheet for the quick-intake
        // confirm flow. The summary card + primary commit button fit
        // comfortably in `.medium`; the operator keeps the dashboard
        // context visible behind. `.large` stays available so longer
        // chooser lists (multiple actionable intakes) can expand
        // without scroll-cramping.
        .hlSheetPresentation(.standard)
        .presentationBackground(HLColor.surface)
        // H4 — batch take-all result tally.
        .alert(
            Text("meds.quick.takeall.result.title"),
            isPresented: Binding(
                get: { batchResult != nil },
                set: { if !$0 { batchResult = nil } }
            )
        ) {
            Button(String(localized: "meds.quick.takeall.result.ok")) {
                let allConfirmed = batchResult?.allConfirmed ?? false
                batchResult = nil
                if allConfirmed { onDismiss() }
            }
        } message: {
            if let batchResult {
                Text(String(
                    format: String(localized: "meds.quick.takeall.result.message"),
                    batchResult.confirmed,
                    batchResult.total
                ))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let resolved = options
        if resolved.isEmpty {
            emptyState
        } else {
            // For the single-option case the `.task` modifier auto-pushes
            // the confirm screen — the chooser stays mounted as a stable
            // fallback if the data refreshes between task-fire and push.
            chooserList(options: resolved)
        }
    }

    /// CU-24 (GH #73) — the empty state now depends on ACCOUNT state, not on
    /// which sheet the operator opened. With no active medication the sheet no
    /// longer says "schau später wieder rein" (nothing would ever become due)
    /// and no longer offers "manuell nachtragen" (a second dead end) — it offers
    /// the create flow. With active medications the pre-existing "gerade nichts
    /// fällig" copy is correct and stays, manual back-logging included.
    private var emptyState: some View {
        MedicationLoggingEmptyStateView(
            state: MedicationLoggingEmptyState.resolve(
                hasLoadedMedications: store.hasLoadedMedications,
                hasActiveMedications: store.medications.contains(where: \.active)
            ),
            // Build 6.1 — nothing is due, but the operator may still have taken
            // (or want to back-date) an intake.
            onLogManually: { path.append(FreeIntakeRoute()) },
            onClose: onDismiss
        )
    }

    private func chooserList(options: MedicationQuickIntakeOptions) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Text("meds.quick.chooser.header")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .padding(.horizontal, HLSpace.lg)
                // H4 — "take all due" appears only when ≥2 doses are due. Each
                // dose still rides the single-intake path (own idempotency key).
                let due = options.due
                if due.count >= 2 {
                    HLButton(
                        // W-I18N: already-formatted string carries a runtime
                        // count — paint verbatim, never re-resolve as a key.
                        verbatim: String(
                            format: String(localized: "meds.quick.takeall.cta"),
                            due.count
                        ),
                        icon: "checkmark.circle.fill",
                        variant: .restrained,
                        isLoading: isBatchConfirming
                    ) {
                        Task { await confirmAll(due: due) }
                    }
                    .padding(.horizontal, HLSpace.lg)
                    .accessibilityIdentifier("meds.quick.takeall")
                }
                if !due.isEmpty {
                    HLCard(style: .standard) {
                        VStack(spacing: 0) {
                            ForEach(Array(due.enumerated()), id: \.element.id) { idx, option in
                                chooserRow(option: option)
                                if idx < due.count - 1 {
                                    Divider().background(HLColor.separator)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, HLSpace.lg)
                }
                asNeededSection(options.asNeeded)
                // Build 6.1 — free / back-dated logging for a dose that is NOT
                // one of the pending slots above (an off-schedule take, or a
                // dose taken earlier the operator wants to back-date).
                HLButton(
                    String(localized: "med.freelog.open"),
                    icon: "square.and.pencil",
                    variant: .secondary,
                    size: .regular
                ) {
                    path.append(FreeIntakeRoute())
                }
                .padding(.horizontal, HLSpace.lg)
                .accessibilityIdentifier("meds.quick.freelog")
            }
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.lg)
        }
        .background(HLColor.background)
    }

    private func chooserRow(option: IntakeOption) -> some View {
        Button {
            path.append(option)
        } label: {
            HStack(spacing: HLSpace.md) {
                Image(systemName: "pills.fill")
                    .font(.hlIcon(HLIconSize.lg))
                    .foregroundStyle(HLText.secondary)
                    .frame(width: 36, height: 36)
                    .background(HLSurface.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(option.medication.name)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    HStack(spacing: HLSpace.sm) {
                        Text(option.medication.dose)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                        Text(option.scheduledTimeString)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                HLDisclosureChevron()
                    .accessibilityHidden(true)
            }
            .padding(.vertical, HLSpace.sm)
            .padding(.horizontal, HLSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("meds.quick.chooser.row.\(option.medication.id)")
        .accessibilityElement(children: .combine)
    }

    /// **B6** — as-needed medications, on their own terms. NOT faked as due
    /// slots: each row records an ad-hoc intake at now through the free-intake
    /// path, which is what an as-needed dose is.
    @ViewBuilder
    private func asNeededSection(_ medications: [Medication]) -> some View {
        if !medications.isEmpty {
            Text("meds.quick.asneeded.header")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .padding(.horizontal, HLSpace.lg)
            HLCard(style: .standard) {
                VStack(spacing: 0) {
                    ForEach(Array(medications.enumerated()), id: \.element.id) { idx, med in
                        asNeededRow(medication: med)
                        if idx < medications.count - 1 {
                            Divider().background(HLColor.separator)
                        }
                    }
                }
            }
            .padding(.horizontal, HLSpace.lg)
        }
    }

    /// **B6** — one as-needed medication. Tapping it records an ad-hoc intake
    /// at now through the free-intake path (no slot, no confirm step: the
    /// operator opened Erfassen and picked the medication, which IS the
    /// confirmation). The dose it records is the medication's own; a deviating
    /// one is two gestures away on the card, or via "Manuell nachtragen" below.
    private func asNeededRow(medication: Medication) -> some View {
        Button {
            Task { await recordAsNeeded(medication) }
        } label: {
            HStack(spacing: HLSpace.md) {
                Image(systemName: "hand.tap")
                    .font(.hlIcon(HLIconSize.lg))
                    .foregroundStyle(HLText.secondary)
                    .frame(width: 36, height: 36)
                    .background(HLSurface.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(medication.name)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Text(medication.dose)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
                Spacer(minLength: 0)
                if recordingAsNeededID == medication.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.hlIcon(HLIconSize.rowAction))
                        .foregroundStyle(HLText.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, HLSpace.sm)
            .padding(.horizontal, HLSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(recordingAsNeededID != nil)
        .accessibilityIdentifier("meds.quick.asneeded.row.\(medication.id)")
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("meds.quick.asneeded.hint"))
    }

    /// Records the ad-hoc dose. Same outcome handling as every other row: the
    /// sheet closes on success/queued and stays open on a failure the store has
    /// already surfaced.
    private func recordAsNeeded(_ medication: Medication) async {
        guard recordingAsNeededID == nil else { return }
        recordingAsNeededID = medication.id
        defer { recordingAsNeededID = nil }
        let outcome = await store.logIntakeFree(
            medicationId: medication.id,
            takenAt: .now,
            skipped: false
        )
        handleOutcome(outcome)
    }

    /// When the user lands on the sheet with exactly one actionable
    /// intake, push the confirm view automatically. Run inside `.task`
    /// so we don't mutate state during the first body evaluation. The
    /// chooserList stays as a visible fallback in the unlikely case the
    /// store re-emits a different shape before the push lands.
    private func autoAdvanceIfSingle() {
        let due = options.due
        guard due.count == 1, path.isEmpty else { return }
        path.append(due[0])
    }

    /// H4 — confirm every due dose, then surface the success/failure tally.
    private func confirmAll(due: [IntakeOption]) async {
        guard !isBatchConfirming else { return }
        isBatchConfirming = true
        defer { isBatchConfirming = false }
        let ids = due.map(\.intake.id)
        batchResult = await store.markAllDueQuick(intakeIds: ids)
        onQueued()
    }

    private func handleOutcome(_ outcome: MedicationsStore.WriteOutcome) {
        switch outcome {
        case .success:
            onDismiss()
        case .queued:
            onQueued()
            onDismiss()
        case .failed:
            // Confirm view surfaces the inline error; user can retry or
            // cancel from there. The parent sheet stays open so the
            // error bubble remains visible alongside the retry CTA.
            break
        }
    }
}

/// Confirm screen — the back-out gate the operator's "accidentally
/// tapped" feedback called for. Shows the medication name, dose, and
/// scheduled time; a primary "Als genommen markieren" commits the mark
/// via `MedicationsStore.markIntakeQuick`. Cancel via the toolbar (or
/// the navigation back-affordance) dismisses without writing.
///
/// `.failed` outcomes surface inline so the operator can retry without
/// losing the confirm context. `.queued` + `.success` bubble up via
/// `onCommitOutcome` so the parent sheet can dismiss.
struct MedicationQuickIntakeConfirm: View {
    @Environment(MedicationsStore.self) private var store
    @Environment(InjectionSitePrefsStore.self) private var injectionPrefs
    let option: IntakeOption
    let onCommitOutcome: (MedicationsStore.WriteOutcome) -> Void
    let onCancel: () -> Void

    @State private var isSaving = false
    @State private var failedError: HLError?
    /// v0.11 — picked injection site (only meaningful for an injection med
    /// with tracking on). Optional — the dose records with or without it.
    @State private var selectedSite: InjectionSite?
    /// Recent sites for the rotation hint, newest-first. Loaded lazily.
    @State private var recentSites: [InjectionSite] = []
    /// v0.5.5.1 — iOS 17+ haptic triggers. Replaces the
    /// `UIImpactFeedbackGenerator` + `UINotificationFeedbackGenerator`
    /// instantiations the `commit()` method previously called directly.
    /// `tapTrigger` increments on every confirm-tap (regardless of
    /// outcome); `lastSavedAt` / `lastErrorAt` drive the outcome-specific
    /// modifier. SwiftUI handles the haptic engine lifecycle for us.
    @State private var tapTrigger: Int = 0
    @State private var lastSavedAt: Date?
    @State private var lastErrorAt: Date?

    var body: some View {
        ScrollView {
            VStack(spacing: HLSpace.lg) {
                summaryCard
                if option.medication.injectionSiteCaptureEnabled {
                    IntakeSitePickerSection(
                        allowed: effectiveAllowedSites,
                        recentSites: recentSites,
                        selected: $selectedSite
                    )
                }
                if let failedError {
                    inlineError(failedError)
                }
                HLButton(
                    String(localized: "meds.quick.commit"),
                    icon: "checkmark.circle.fill",
                    variant: .restrained,
                    isLoading: isSaving
                ) {
                    Task { await commit() }
                }
                .accessibilityIdentifier("meds.quick.commit")
                HLButton(
                    String(localized: "meds.quick.cancel"),
                    variant: .secondary,
                    size: .regular
                ) {
                    onCancel()
                }
                .accessibilityIdentifier("meds.quick.confirm.cancel")
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xl)
        }
        .background(HLColor.background)
        .navigationTitle(Text("meds.quick.confirm.title"))
        .navigationBarTitleDisplayMode(.inline)
        // v0.5.5.1 — three haptic-driving modifiers; each owns its own
        // trigger so the engine fires exactly once per state-flip.
        .sensoryFeedback(.selection, trigger: tapTrigger)
        .sensoryFeedback(.success, trigger: lastSavedAt)
        .sensoryFeedback(.error, trigger: lastErrorAt)
        .task {
            guard option.medication.injectionSiteCaptureEnabled else { return }
            await injectionPrefs.refresh()
            recentSites = await store.recentInjectionSites(medicationID: option.medication.id)
        }
    }

    /// Effective allowed set = the medication's per-med allow-list minus the
    /// user-level global deny-list (deny always wins). Restricting the picker
    /// to this keeps the server's 422 `injection_site.disallowed` an edge case.
    private var effectiveAllowedSites: [InjectionSite] {
        injectionPrefs.effectiveAllowed(for: option.medication.allowedInjectionSites)
    }

    private var summaryCard: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HStack(spacing: HLSpace.md) {
                    Image(systemName: "pills.fill")
                        .font(.hlIcon(HLIconSize.hero))
                        .foregroundStyle(HLText.secondary)
                        .frame(width: 48, height: 48)
                        .background(HLSurface.tertiary)
                        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(option.medication.name)
                            .font(.hlTitle3)
                            .foregroundStyle(HLText.primary)
                        Text(option.medication.dose)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                HStack {
                    Text("meds.quick.confirm.scheduled")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                    Spacer()
                    Text(option.scheduledTimeString)
                        .font(.hlMetric(.body))
                        .foregroundStyle(HLText.primary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func inlineError(_ error: HLError) -> some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HLColor.statusBad)
            // HLError surfaces operator-friendly copy via
            // `userFacingDescription`; the generic fallback covers cases
            // where the user-facing description collapses to an empty
            // string (e.g. `.canceled`).
            Text(displayMessage(for: error))
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer()
        }
        .padding(HLSpace.md)
        .background(
            RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                .fill(HLColor.statusBad.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
    }

    private func displayMessage(for error: HLError) -> String {
        let copy = error.userFacingDescription
        return copy.isEmpty ? String(localized: "meds.quick.error.generic") : copy
    }

    private func commit() async {
        isSaving = true
        failedError = nil
        defer { isSaving = false }
        // v0.5.5.1 — `.sensoryFeedback(.selection, trigger:)` on the body
        // emits the tap-landed haptic; the outcome arms either the
        // `.success` or `.error` modifier via `lastSavedAt` /
        // `lastErrorAt`. UIKit generators removed.
        tapTrigger &+= 1
        // v0.11 — attach the chosen site only for an injection med with
        // tracking on; the repo also guards (taken-only). The picker is
        // restricted to the effective set so a 422 is an edge case.
        let site = option.medication.injectionSiteCaptureEnabled ? selectedSite : nil
        let outcome = await store.markIntakeQuick(
            intakeId: option.intake.id,
            status: .taken,
            injectionSite: site
        )
        if case let .failed(err) = outcome {
            // v0.11 — a stale deny-list could yield a 422
            // `injection_site.disallowed`; re-fetch the effective set + clear
            // the selection so the operator re-picks from the fresh set.
            if case let .server(status, code, _) = err,
               status == 422, code == "medications.intake.injection_site.disallowed"
            {
                selectedSite = nil
                await injectionPrefs.refresh(force: true)
                recentSites = await store.recentInjectionSites(medicationID: option.medication.id)
            }
            failedError = err
            lastErrorAt = .now
            return
        }
        if outcome == .success {
            lastSavedAt = .now
        }
        onCommitOutcome(outcome)
    }
}
