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
/// 1. **Zero actionable intakes** — one quiet line in a short sheet, and
///    the slots still to come today, so the sheet and Home's "1 still open"
///    tell one story. Without any active medication the shared empty state
///    offers the create flow.
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
    /// The height of the form sheet, set by a regular-width host. A form
    /// sheet fitted to this scrolling page found no height to fit to and
    /// stood as its bar alone; `nil` keeps the bottom sheet's detents.
    var formHeight: CGFloat?

    /// The due intake on the confirm page, if one is pushed.
    @State private var pushedOption: IntakeOption?
    /// Whether the one intake form is pushed.
    @State private var showsFreeIntake = false
    /// True while the batch take-all is in flight (disables the button).
    @State private var isBatchConfirming = false
    /// Height of the chooser's content; `0` until it measured itself.
    @State private var chooserHeight: CGFloat = 0
    /// Populated with the batch tally to surface a result alert.
    @State private var batchResult: MedicationsStore.BatchIntakeOutcome?
    /// The as-needed medication whose ad-hoc write is in flight, so the
    /// row can say so and a second tap cannot double-record.
    @State private var recordingAsNeededID: String?

    /// What this sheet offers, resolved at render time so the list refreshes
    /// when the store reloads in the background.
    ///
    /// Reads `derivedTodayIntakes` so synthesised placeholders
    /// surface as due rows even when the server has not yet materialised the
    /// intake event (the reminder worker only pre-creates RED-phase rows; the
    /// operator's pre-RED window previously rendered the "Keine offene
    /// Einnahme" empty state for the entire morning + evening cadence).
    private var options: MedicationQuickIntakeOptions {
        MedicationQuickIntakeOptions.resolve(
            medications: store.medications,
            intakes: store.derivedTodayIntakes,
            now: .now,
            // The account's zone, the one the card's "Jetzt fällig" reads.
            timeZone: store.profileTimeZone
        )
    }

    var body: some View {
        // Close only: logging a dose is the confirm page's own step, not a
        // save of this chooser.
        // The pushed manual log is a form and needs the room to grow.
        HLSheetScaffold(
            "meds.quick.title",
            size: formHeight.map { height in
                Self.size(
                    for: options,
                    showsFreeIntake: showsFreeIntake || pushedOption != nil,
                    formHeight: height,
                    chooserHeight: chooserHeight
                )
            } ?? Self.sheetSize(
                for: options,
                chooserHeight: chooserHeight,
                isPushed: showsFreeIntake || pushedOption != nil
            )
        ) {
            content
                .navigationDestination(item: $pushedOption) { option in
                    MedicationQuickIntakeConfirm(
                        option: option,
                        onCommitOutcome: handleOutcome,
                        onCancel: onDismiss
                    )
                }
                // The one intake form (#191), always reachable so a dose can
                // be logged even when nothing is due right now, back-dated,
                // skipped, or with a deviating dose.
                .navigationDestination(isPresented: $showsFreeIntake) {
                    MedicationIntakeForm(onDone: handleOutcome)
                }
        }
        .task {
            // The empty state distinguishes "no medication exists" from
            // "nothing due right now", so the medication list has to be
            // hydrated before either claim is painted. Cheap: a no-op whenever
            // the tab / dashboard already loaded it.
            if !store.hasLoadedMedications {
                await store.load()
            }
            autoAdvanceIfSingle()
        }
        // Batch take-all result tally.
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
        let emptyKind = MedicationLoggingEmptyState.resolve(
            hasLoadedMedications: store.hasLoadedMedications,
            hasActiveMedications: store.medications.contains(where: \.active)
        )
        if resolved.isEmpty, emptyKind != .nothingDue {
            emptyState
        } else {
            // For the single-option case the `.task` modifier auto-pushes
            // the confirm screen — the chooser stays mounted as a stable
            // fallback if the data refreshes between task-fire and push.
            // With nothing due it says so in one line and names what is
            // still open later today.
            chooserList(options: resolved)
        }
    }

    /// Nothing to log is a short sheet: one line and the manual log fit in
    /// half the screen and it does not grow into an empty page.
    static func size(for options: MedicationQuickIntakeOptions) -> HLSheetSize {
        options.isEmpty ? .compact : .standard
    }

    /// The chooser is as tall as its rows once it measured them; a pushed
    /// page (the confirm step, the manual log) is a form and gets the room
    /// to grow.
    static func sheetSize(
        for options: MedicationQuickIntakeOptions,
        chooserHeight: CGFloat,
        isPushed: Bool
    ) -> HLSheetSize {
        if isPushed { return .standard }
        return .content(measuredHeight: chooserHeight, fallback: size(for: options))
    }

    /// The size with the free log and the host's form height. In a regular
    /// window the chooser is as tall as its measured rows, never taller than
    /// the host's height; a pushed page (the free log, the confirm step)
    /// stands at the host's height, a short form, not at the page height
    /// with half of it empty.
    static func size(
        for options: MedicationQuickIntakeOptions,
        showsFreeIntake: Bool,
        formHeight: CGFloat?,
        chooserHeight: CGFloat = 0
    ) -> HLSheetSize {
        if let formHeight {
            guard !showsFreeIntake, chooserHeight > 0 else { return .fitted(height: formHeight) }
            return .fitted(height: min(formHeight, (chooserHeight + HLSheet.barAllowance).rounded(.up)))
        }
        return showsFreeIntake ? .standard : size(for: options)
    }

    /// The line when nothing is due: "nothing open" only when nothing is,
    /// else that nothing is due yet, above the slots still to come.
    static func emptyNoteKey(for options: MedicationQuickIntakeOptions) -> LocalizedStringKey {
        options.later.isEmpty ? "meds.quick.empty.title" : "meds.quick.empty.notYet"
    }

    /// The empty state now depends on ACCOUNT state, not on
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
            onLogManually: { showsFreeIntake = true }
        )
    }

    private func chooserList(options: MedicationQuickIntakeOptions) -> some View {
        // The page gives every card and button its side margin.
        HLPage {
            // The sheet's title asks the question; no line repeats it.
            Group {
                // A quiet line, not a card: in a card it read like a field.
                if options.isEmpty {
                    HLEmptyNote(Self.emptyNoteKey(for: options), alignment: .center)
                        .padding(.vertical, HLSpace.sm)
                }
                // "take all due" appears only when ≥2 doses are due. Each
                // dose still rides the single-intake path (own idempotency key).
                let due = options.due
                if due.count >= 2 {
                    HLButton(
                        // Already-formatted string carries a runtime
                        // count — paint verbatim, never re-resolve as a key.
                        Text(verbatim: String(
                            format: String(localized: "meds.quick.takeall.cta"),
                            due.count
                        )),
                        systemImage: "checkmark.circle.fill",
                        variant: .secondary,
                        isLoading: isBatchConfirming
                    ) {
                        Task { await confirmAll(due: due) }
                    }
                    .accessibilityIdentifier("meds.quick.takeall")
                }
                if !due.isEmpty {
                    HLCard {
                        VStack(spacing: HLLayout.rowGap) {
                            ForEach(Array(due.enumerated()), id: \.element.id) { _, option in
                                // The note under its row, so "take all" shows it too.
                                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                                    chooserRow(option: option)
                                    if let note = option.medication.note {
                                        MedicationNoteLine(note: note)
                                    }
                                }
                            }
                        }
                    }
                }
                asNeededSection(options.asNeeded)
                laterSection(options.later)
                // The one intake form for a dose that is NOT one of the
                // pending slots above (an off-schedule take, a skip, or a dose
                // taken earlier). Named like the form: "Log intake".
                HLButton(
                    "med.dose.form.title",
                    systemImage: "square.and.pencil",
                    variant: .secondary
                ) {
                    showsFreeIntake = true
                }
                .accessibilityIdentifier("meds.quick.freelog")
            }
        }
        .hlSheetContentHeight($chooserHeight)
    }

    /// A due dose. The row selects what the confirm page shows, so it carries
    /// no chevron.
    private func chooserRow(option: IntakeOption) -> some View {
        HLRowButton {
            pushedOption = option
        } label: {
            HLRow(
                title: Text(verbatim: option.medication.name),
                detail: HLRowDetail.text([option.medication.dose, option.scheduledTimeString])
            ) {
                HLSettingsIconChip(symbol: "pills.fill", tint: HLText.secondary)
            }
        }
        .accessibilityIdentifier("meds.quick.chooser.row.\(option.medication.id)")
        .accessibilityElement(children: .combine)
    }

    /// Today's slots still to come: what Home counts as open, named with
    /// their time. Not loggable before their time, so plain data rows.
    @ViewBuilder
    private func laterSection(_ later: [IntakeOption]) -> some View {
        if !later.isEmpty {
            HLSectionHeader("meds.quick.later.header")
            HLCard(layout: .rows) {
                ForEach(later) { option in
                    HLRow(
                        title: Text(verbatim: option.medication.name),
                        detail: HLRowDetail.text([option.medication.dose]),
                        value: Text(verbatim: option.scheduledTimeString)
                    )
                    .accessibilityIdentifier("meds.quick.later.row.\(option.medication.id)")
                }
            }
        }
    }

    /// As-needed medications, on their own terms. NOT faked as due
    /// slots: each row records an ad-hoc intake at now through the free-intake
    /// path, which is what an as-needed dose is.
    @ViewBuilder
    private func asNeededSection(_ medications: [Medication]) -> some View {
        if !medications.isEmpty {
            HLSectionHeader("meds.quick.asneeded.header")
            HLCard {
                VStack(spacing: HLLayout.rowGap) {
                    ForEach(Array(medications.enumerated()), id: \.element.id) { _, med in
                        asNeededRow(medication: med)
                    }
                }
            }
        }
    }

    /// One as-needed medication. Tapping it records an ad-hoc intake
    /// at now through the free-intake path (no slot, no confirm step: the
    /// operator opened Erfassen and picked the medication, which IS the
    /// confirmation). The dose it records is the medication's own; a deviating
    /// one is two gestures away on the card, or via "Manuell nachtragen" below.
    private func asNeededRow(medication: Medication) -> some View {
        HLRowButton {
            Task { await recordAsNeeded(medication) }
        } label: {
            HLRowLayout(
                title: Text(verbatim: medication.name),
                subtitle: HLRowDetail.text([medication.dose])
            ) {
                if recordingAsNeededID == medication.id {
                    HLInlineProgress()
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.hlIcon(HLIconSize.rowAction))
                        .foregroundStyle(HLText.secondary)
                        .accessibilityHidden(true)
                }
            } leading: {
                HLSettingsIconChip(symbol: "hand.tap", tint: HLText.secondary)
            }
        }
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
        guard due.count == 1, pushedOption == nil, !showsFreeIntake else { return }
        pushedOption = due[0]
    }

    /// Confirm every due dose, then surface the success/failure tally.
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
    /// Picked injection site (only meaningful for an injection med
    /// with tracking on). Optional — the dose records with or without it.
    @State private var selectedSite: InjectionSite?
    /// Recent sites for the rotation hint, newest-first. Loaded lazily.
    @State private var recentSites: [InjectionSite] = []
    /// iOS 17+ haptic triggers. Replaces the
    /// `UIImpactFeedbackGenerator` + `UINotificationFeedbackGenerator`
    /// instantiations the `commit()` method previously called directly.
    /// `tapTrigger` increments on every confirm-tap (regardless of
    /// outcome); `lastSavedAt` / `lastErrorAt` drive the outcome-specific
    /// modifier. SwiftUI handles the haptic engine lifecycle for us.
    @State private var tapTrigger: Int = 0
    @State private var lastSavedAt: Date?
    @State private var lastErrorAt: Date?

    var body: some View {
        HLPage {
            summaryCard
            if option.medication.injectionSiteCaptureEnabled {
                IntakeSitePickerSection(
                    allowed: effectiveAllowedSites,
                    recentSites: recentSites,
                    selected: $selectedSite
                )
            }
            // The step's own decision: log it, or step back. Not a
            // save, so it stays with the content.
            HLButtonPair {
                HLButton("meds.quick.commit", systemImage: "checkmark.circle.fill", isLoading: isSaving) {
                    Task { await commit() }
                }
                .accessibilityIdentifier("meds.quick.commit")
            } secondary: {
                HLButton("meds.quick.cancel", variant: .secondary) {
                    onCancel()
                }
                .accessibilityIdentifier("meds.quick.confirm.cancel")
            }
        }
        // A failed mark stays on the page so it can be tried again; the
        // banner makes room above the summary instead of covering it.
        .hlErrorBannerOverlay(error: failedError)
        .navigationTitle(Text("meds.quick.confirm.title"))
        .navigationBarTitleDisplayMode(.inline)
        // Three haptic-driving modifiers; each owns its own
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
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HStack(spacing: HLSpace.md) {
                    HLSettingsIconChip(symbol: "pills.fill", tint: HLText.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(option.medication.name)
                            .hlText(.objectName)
                        Text(option.medication.dose)
                            .hlText(.factLabel)
                    }
                    Spacer(minLength: 0)
                }
                if let note = option.medication.note {
                    MedicationNoteLine(note: note)
                }
                HLFactGroup {
                    HLFactRow("meds.quick.confirm.scheduled", value: option.scheduledTimeString)
                }
            }
        }
    }

    private func commit() async {
        isSaving = true
        failedError = nil
        defer { isSaving = false }
        // `.sensoryFeedback(.selection, trigger:)` on the body
        // emits the tap-landed haptic; the outcome arms either the
        // `.success` or `.error` modifier via `lastSavedAt` /
        // `lastErrorAt`. UIKit generators removed.
        tapTrigger &+= 1
        // Attach the chosen site only for an injection med with
        // tracking on; the repo also guards (taken-only). The picker is
        // restricted to the effective set so a 422 is an edge case.
        let site = option.medication.injectionSiteCaptureEnabled ? selectedSite : nil
        // Undoable like every in-app take (#188 (7)).
        let outcome = await store.markIntakeQuickUndoable(
            intakeId: option.intake.id,
            status: .taken,
            injectionSite: site
        )
        if case let .failed(err) = outcome {
            // A stale deny-list could yield a 422
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
