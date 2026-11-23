import SwiftUI

/// Presented from `MedicationsScreen` row swipe-action "Bearbeiten" or from
/// `MedicationDetailScreen`'s edit-toolbar. Pre-fills the same fields the
/// add-sheet exposes; save sends `PUT /api/medications/[id]` via
/// `MedicationsStore.update`.
///
/// **Cadence edit + RMW safety.** The cadence picker is
/// pre-selected from the decoded `ScheduleEntry` (`MedicationCadenceLogic.infer`,
/// mirroring the web `inferCadenceFromLegacy`). On save, `schedules` is only
/// rebuilt when the user actually touched the schedule (cadence / times /
/// course / grace) — otherwise it stays `nil` so the server-side replace never
/// drops an unchanged `rrule` / `rolling` / `asNeeded` / cyclic triple (R1
/// risk 5). A delivery-only edit therefore sends `schedules == nil`.
struct EditMedicationSheet: View {
    let medication: Medication
    let onSaved: () -> Void

    // Non-private so the Build 6.2 lifecycle extension (`+Lifecycle.swift`,
    // split out for file_length) can read the store.
    @Environment(MedicationsStore.self) var store
    @Environment(DeliveryPreferencesStore.self) private var deliveryPreferences

    // Editable state, pre-filled in onAppear.
    @State private var name: String = ""
    @State private var dose: String = ""
    /// #174 — the medication's note.
    @State private var note: String = ""
    @State private var times: [ScheduleTimeRow] = []
    /// `nil` = a stored category this build has no row for (shown as itself, never rewritten).
    @State private var category: MedicationCategoryOption? = .other
    @State private var treatmentClass: MedicationTreatmentClassOption = .generic
    @State private var dosesPerUnitText: String = ""
    /// **H1/H2** — units one dose consumes (whole / curated fraction / any other server value, kept as is).
    @State private var unitsPerDose: MedicationUnitsPerDose = .whole(1)
    /// **The RAW per-slot overrides the server sent**, keyed by `HH:mm`.
    /// The rebuild echoes these for every slot the user did not touch; without
    /// the echo a `schedules` REPLACE recreates each row with `unitsPerDose`
    /// NULL and every explicit ½-tablet slot silently falls back to inheritance.
    @State private var slotDoseBaseline: [String: Double] = [:]
    /// Per-slot edit intent since prefill: absent = untouched, `.clear` = "inherit", `.set` = an override.
    @State private var slotDoseIntents: MedicationCadenceLogic.SlotDoseIntents = [:]
    /// **v1.37.19 — the server-EFFECTIVE per-slot dose**, displayed verbatim, never written or re-derived.
    @State private var serverEffectiveDose: [String: Double] = [:]
    @State private var notificationsEnabled: Bool = true
    @State private var deliveryForm: MedicationDeliveryFormOption = .unspecified
    // Injection-site tracking (only meaningful for INJECTION route).
    @State private var trackInjectionSites: Bool = false
    @State private var allowedInjectionSites: Set<InjectionSite> = []

    // Cadence + course window
    @State private var cadenceKind: CadenceKind = .daily
    @State private var cadenceSub: CadenceSubControls = .makeDefault()
    @State private var startsOn: Date?
    @State private var endsOn: Date?
    @State private var isOneShot: Bool = false
    /// v1.39.1 — the intake-tracking switch and the server's own value.
    @State private var intake = MedicationTrackIntakeFormValue()
    @State private var graceEnabled: Bool = false
    @State private var graceMinutes: Int = 60
    /// The form as it opened — the baseline every RMW decision of the PUT is
    /// taken against (``MedicationEditDraft``).
    @State private var prefill: EditMedicationFormState?

    /// Per-medication Live-Activity opt-in + scope.
    @State private var liveActivityEnabled = DeliveryChannel.liveActivity.hardcodedDefault
    @State private var liveActivityScope: DeliveryScope = .allDevices
    /// Per-medication AlarmKit critical-alarm opt-in + scope
    /// (iOS 26-gated; default OFF).
    @State private var criticalAlarmEnabled = DeliveryChannel.criticalAlarm.hardcodedDefault
    @State private var criticalAlarmScope: DeliveryScope = .thisDevice
    @State private var criticalAlarmDenied = false
    @State private var isRequestingAlarmAuth = false

    // Non-private so the Build 6.2 lifecycle extension can disable its controls
    // while a save is in flight.
    @State var isSaving: Bool = false
    @State private var saveError: HLError?
    @State private var hasPrefilled: Bool = false
    // Build 6.2 — lifecycle (pause / reactivate / end) state. Non-private so the
    // `+Lifecycle.swift` extension (split for file_length) can drive them.
    @State var isProcessingLifecycle = false
    @State var lifecycleError: HLError?
    @State var showEndConfirm = false
    // Non-private so the Build 6.2 lifecycle extension can drive the save haptic.
    /// Save haptic drivers (see `AddMedicationSheet`). `saveTick`
    /// bumps on a successful/queued PUT, `saveErrorTick` on a failure.
    @State var saveTick: Int = 0
    @State var saveErrorTick: Int = 0
    /// The form right after the prefill, for the discard guard.
    @State private var baseline: [AnyHashable]?
    /// FORM-2 initial focus + name→dose chain; 15-02 — the single copy of
    /// the truth, with ``MedicationEditorFocus`` deciding where it belongs.
    @FocusState private var focusedField: MedicationEditorFocus.Field?

    var body: some View {
        HLSheetScaffold(
            "Edit",
            action: .save(isEnabled: isValid) { await save() },
            isDirty: isDirty
        ) {
            Form {
                Section {
                    HLFormField("med.form.name.label") {
                        TextField("med.form.name.placeholder", text: $name)
                            .textInputAutocapitalization(.words)
                            .disableAutocorrection(true)
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focusedField = MedicationEditorFocus.resolve(.submitted(.name), from: focusedField) }
                    }
                    HLFormField("med.form.dose.label") {
                        TextField("med.form.dose.placeholder", text: $dose)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .focused($focusedField, equals: .dose)
                            .submitLabel(.done)
                    }
                    HLFormField("med.form.note.label") {
                        TextField("med.form.note.placeholder", text: $note, axis: .vertical)
                            .lineLimit(2 ... 6)
                            .onChange(of: note) { _, newValue in
                                let capped = MedicationNoteWrite.capped(newValue)
                                if capped != newValue { note = capped }
                            }
                            .accessibilityIdentifier("EditMedication.note")
                    }
                }
                .hlFormRowSurface()

                if intake.server != nil { MedicationTrackIntakeSection(isOn: $intake.tracked) }

                Section {
                    CadencePicker(kind: $cadenceKind, sub: $cadenceSub)
                        .onChange(of: cadenceKind) { _, newKind in
                            enforceTimeConstraints(for: newKind)
                        }
                        .simultaneousGesture(scheduleEngagement, including: .all)
                    if let nextDue = medication.nextDueAt {
                        // Read-only display of the server-computed next reminder
                        // instant. NEVER sent on PUT — it is purely
                        // informational and already drives the local reminders.
                        LabeledContent {
                            Text(nextDue, style: .relative)
                                .foregroundStyle(HLText.secondary)
                        } label: {
                            HLRowTitle("med.schedule.nextDose.label")
                        }
                    }
                } header: {
                    HLSectionHeader("med.schedule.cadence.section")
                }
                .hlFormRowSurface()

                if cadenceKind != .asNeeded {
                    timesSection.simultaneousGesture(scheduleEngagement, including: .all)
                }

                Section {
                    CourseWindowRow(startsOn: $startsOn, endsOn: $endsOn, isOneShot: $isOneShot)
                        .onChange(of: isOneShot) { _, oneShot in
                            if oneShot { enforceTimeConstraints(for: cadenceKind) }
                        }
                } header: {
                    HLSectionHeader("med.schedule.course.section")
                }
                .hlFormRowSurface()

                Section {
                    // Form rows that stack at the accessibility sizes instead
                    // of cutting their value in the middle ("Allge…dheit").
                    HLFormPicker("Category", selection: $category, options: categoryOptions) { option in
                        Text(verbatim: option?.displayName ?? prefill?.unknownCategoryLabel ?? "")
                    }
                    HLFormPicker("Class", selection: $treatmentClass, options: MedicationTreatmentClassOption.allCases) { option in
                        Text(verbatim: option.displayName)
                    }
                    HLFormPicker(
                        "med.schedule.advanced.deliveryForm.label",
                        selection: $deliveryForm,
                        options: MedicationDeliveryFormOption.allCases
                    ) { option in
                        Text(option.labelKey)
                    }
                    InjectionSiteTrackingSection(
                        isInjection: .constant(deliveryForm == .injection),
                        trackInjectionSites: $trackInjectionSites,
                        allowedInjectionSites: $allowedInjectionSites
                    )
                    MedicationDosesPerUnitField(text: $dosesPerUnitText)
                    UnitsPerDosePicker(selection: $unitsPerDose)
                    Toggle(isOn: $notificationsEnabled) {
                        HLRowTitle("Notifications")
                    }
                    if cadenceKind != .asNeeded {
                        Toggle(isOn: $graceEnabled) {
                            HLRowTitle("med.schedule.advanced.grace.toggle")
                        }
                        if graceEnabled {
                            HLIntStepperRow(
                                titleKey: "med.schedule.advanced.grace.label",
                                value: $graceMinutes,
                                range: 1 ... 1440,
                                unitKey: nil
                            )
                        }
                    }
                } header: {
                    HLSectionHeader("Properties")
                }
                .hlFormRowSurface()

                deliverySection

                if medication.offersAutoMarkTakenSwitch(canManage: canManageMedications) {
                    MedicationAutoMarkTakenSection(value: $autoMarkTaken, since: medication.autoMarkTakenSince)
                }

                lifecycleSection

                if let saveError {
                    Section {
                        HLFormErrorText(saveError.userFacingDescription)
                            .font(.hlSubhead)
                    }
                    .hlFormRowSurface()
                }
            }
            .hlPageMargins()
            .hlScrollEdgeSoft()
            // A drag puts the keyboard away as it goes.
            .scrollDismissesKeyboard(.interactively)
            .onAppear(perform: prefillOnce)
            // Save success/error haptic, mirroring the intake path.
            .sensoryFeedback(.success, trigger: saveTick)
            .sensoryFeedback(.error, trigger: saveErrorTick)
            // Seed focus onto the name field once the sheet settles.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = MedicationEditorFocus.resolve(.sheetSettled, from: focusedField)
            }
        }
    }

    /// Every field the person can change, in one comparable value.
    private var formFingerprint: [AnyHashable] {
        [
            name, dose, note, ScheduleTimeRow.times(times), category, treatmentClass, dosesPerUnitText, unitsPerDose,
            !slotDoseIntents.isEmpty, notificationsEnabled, deliveryForm, trackInjectionSites, allowedInjectionSites,
            cadenceKind, cadenceSub, startsOn, endsOn, isOneShot, intake.tracked, autoMarkTaken.isOn,
            graceEnabled, graceMinutes, liveActivityEnabled, liveActivityScope, criticalAlarmEnabled,
            criticalAlarmScope
        ]
    }

    private var isDirty: Bool {
        guard let baseline else { return false }
        return baseline != formFingerprint
    }

    /// MED-PLUS (v1.42.2) — "record doses automatically"; see `+AutoMarkTaken.swift`.
    @State private var autoMarkTaken = MedicationAutoMarkTakenFormValue()
    @Environment(AuthStore.self) private var authStore: AuthStore?

    /// The Zeitplan row became the interaction target, reported on
    /// the way DOWN so the picker's own tap handling stays untouched.
    private var scheduleEngagement: some Gesture {
        TapGesture().onEnded { focusedField = MedicationEditorFocus.resolve(.scheduleEditorEngaged, from: focusedField) }
    }

    /// The categories, led by the server's own label when it sent one this
    /// app does not know (kept as `nil`, so a save does not overwrite it).
    private var categoryOptions: [MedicationCategoryOption?] {
        let known = MedicationCategoryOption.allCases.map { Optional($0) }
        return prefill?.unknownCategoryLabel == nil ? known : [nil] + known
    }

    private var timesSection: some View {
        Section {
            ForEach(Array(times.enumerated()), id: \.element.id) { idx, row in
                // The dose row keeps the form's row gap below the time chip.
                VStack(alignment: .leading, spacing: HLLayout.rowSpacing) {
                    HStack {
                        // The red minus stands first, as in the system's edit mode.
                        if times.count > 1 {
                            HLDeleteButton("Remove time", form: .remove, action: .undoable {
                                times.removeAll { $0.id == row.id }
                            })
                        }
                        DatePicker(
                            selection: bindingForTime(rowID: row.id),
                            displayedComponents: [.hourAndMinute]
                        ) {
                            HLRowTitle("med.form.time.label \(idx + 1)")
                        }
                        .labelsHidden()
                        Spacer()
                    }
                    // Under the time stands its dose, not the time a
                    // second time in wire form ("08:00").
                    slotDoseRow(for: row.time, index: idx)
                }
            }
            if times.count < MedicationCadenceLogic.maxTimes(for: cadenceKind) {
                HLSettingsActionRow(title: "med.schedule.times.add", presents: .create) {
                    times.append(ScheduleTimeRow(time: TimeOfDay(hour: 12, minute: 0)))
                }
            }
        } header: {
            HLSectionHeader("med.schedule.times.header")
        }
        .hlFormRowSurface()
    }

    // MARK: - Per-slot inventory dose

    /// The per-slot units-per-dose control for one dose time. See
    /// ``SlotDosePicker`` for why the server's own figure is shown beside it and
    /// when it is withheld.
    private func slotDoseRow(for time: TimeOfDay, index: Int) -> some View {
        SlotDosePicker(
            timeKey: MedicationFormLogic.formatTime(time),
            index: index,
            intents: $slotDoseIntents,
            baseline: slotDoseBaseline,
            serverEffective: serverEffectiveDose,
            medicationDoseChanged: unitsPerDose != (prefill?.unitsPerDose ?? unitsPerDose)
        )
    }

    /// The raw per-slot doses a rebuild must carry: the server's values with
    /// the user's explicit sets and clears applied.
    private var resolvedSlotDoses: [String: Double] {
        MedicationCadenceLogic.resolveSlotUnitsPerDose(
            existing: slotDoseBaseline,
            intents: slotDoseIntents
        )
    }

    // MARK: - Delivery section

    /// Unified per-medication delivery preferences: Live
    /// Activity + AlarmKit critical alarm, each with a "Dieses Gerät / Alle
    /// Geräte" scope picker (progressive disclosure).
    ///
    /// Each switch says what it does in one line under its title, and
    /// the footer speaks only when alarms are not allowed. The operator sentence
    /// under "Alle Geräte" is gone: the medication row carries the roaming
    /// booleans since server v1.7.0 (`ingestServerDefaults`), so it was wrong as
    /// well as technical.
    private var deliverySection: some View {
        Section {
            HLSettingsToggleRow(
                title: "med.edit.live_activity",
                description: "med.edit.live_activity.footer",
                isOn: $liveActivityEnabled,
                accessibilityID: "med.edit.liveActivity"
            )
            if liveActivityEnabled {
                scopePicker(selection: $liveActivityScope)
            }
            HLSettingsToggleRow(
                title: "med.edit.critical_alarm",
                description: "med.edit.critical_alarm.footer",
                isOn: $criticalAlarmEnabled,
                accessibilityID: "med.edit.criticalAlarm"
            )
            .onChange(of: criticalAlarmEnabled) { _, isOn in
                if isOn {
                    Task { await requestAlarmAuthorizationIfNeeded() }
                } else {
                    criticalAlarmDenied = false
                }
            }
            if criticalAlarmEnabled {
                scopePicker(selection: $criticalAlarmScope)
            }
        } header: {
            HLSectionHeader("med.edit.delivery.section")
        } footer: {
            if criticalAlarmDenied {
                Text("med.edit.critical_alarm.denied")
                    .foregroundStyle(HLColor.statusWarn)
                    .font(.hlCaption)
            }
        }
        .hlFormRowSurface()
    }

    private func scopePicker(selection: Binding<DeliveryScope>) -> some View {
        HLAdaptiveSegmentedPicker(
            "med.edit.scope.label",
            selection: selection,
            labels: ["med.edit.scope.this_device", "med.edit.scope.all_devices"]
        ) {
            Text("med.edit.scope.this_device").tag(DeliveryScope.thisDevice)
            Text("med.edit.scope.all_devices").tag(DeliveryScope.allDevices)
        }
    }

    /// Request AlarmKit authorization the first time the user opts a med into
    /// the critical alarm. On denial, flip the toggle back off + surface the
    /// footer hint.
    private func requestAlarmAuthorizationIfNeeded() async {
        #if canImport(AlarmKit)
            isRequestingAlarmAuth = true
            defer { isRequestingAlarmAuth = false }
            let granted = await CriticalMedAlarmService.shared.requestAuthorizationIfNeeded()
            if !granted {
                criticalAlarmEnabled = false
                criticalAlarmDenied = true
            }
        #endif
    }

    // MARK: - Prefill

    private func prefillOnce() {
        guard !hasPrefilled else { return }
        hasPrefilled = true
        let state = EditMedicationFormState(from: medication)
        name = state.name
        dose = state.dose
        note = state.note
        times = ScheduleTimeRow.rows(state.editorTimes)
        category = state.category
        treatmentClass = state.treatmentClass
        dosesPerUnitText = state.dosesPerUnitText
        unitsPerDose = state.unitsPerDose
        slotDoseBaseline = state.slotUnitsPerDose
        slotDoseIntents = [:]
        serverEffectiveDose = state.serverEffectiveUnitsPerDose
        notificationsEnabled = state.notificationsEnabled
        deliveryForm = state.deliveryForm
        trackInjectionSites = state.trackInjectionSites
        allowedInjectionSites = state.allowedInjectionSites
        cadenceKind = state.cadenceKind
        cadenceSub = state.cadenceSub
        startsOn = state.startsOn
        endsOn = state.endsOn
        isOneShot = state.isOneShot
        intake = MedicationTrackIntakeFormValue(tracked: state.trackIntake, server: state.serverTrackIntake)
        autoMarkTaken = state.autoMarkTaken
        graceEnabled = state.editorGraceEnabled
        graceMinutes = state.graceMinutes ?? 60
        prefill = state
        let la = deliveryPreferences.effective(medicationId: medication.id, channel: .liveActivity)
        liveActivityEnabled = la.enabled
        liveActivityScope = la.scope
        let alarm = deliveryPreferences.effective(medicationId: medication.id, channel: .criticalAlarm)
        criticalAlarmEnabled = alarm.enabled
        criticalAlarmScope = alarm.scope
        baseline = formFingerprint
    }
}

// MARK: - Time constraints / validation / save

extension EditMedicationSheet {
    func enforceTimeConstraints(for kind: CadenceKind) {
        let allowed = EditMedicationFormState.constrainedTimes(ScheduleTimeRow.times(times), kind: kind)
        if allowed.count < times.count {
            times = Array(times.prefix(allowed.count))
        }
        if kind == .asNeeded {
            graceEnabled = false
        }
    }

    /// The record in use lets the caller change medications (a signed-out or
    /// unknown phase reads as the own record; the server refuses otherwise).
    private var canManageMedications: Bool {
        guard let authStore, case let .authenticated(user) = authStore.phase else { return true }
        return user.accountAccess.canManageMedications
    }

    // MARK: - Validation

    private var isValid: Bool {
        guard MedicationFormLogic.isValidCore(name: name, dose: dose) else { return false }
        let value = MedicationCadenceLogic.encode(cadenceKind, cadenceSub)
        return MedicationCadenceLogic.isCadenceValid(
            value: value,
            times: cadenceKind == .asNeeded ? [] : ScheduleTimeRow.times(times),
            startsOn: startsOn,
            endsOn: endsOn,
            graceMinutes: graceEnabled ? graceMinutes : nil
        )
    }

    /// The editor's current state as a ``MedicationEditDraft`` over the prefill
    /// baseline; `nil` before prefill.
    private var draft: MedicationEditDraft? {
        guard let prefill else { return nil }
        var draft = MedicationEditDraft(prefill: prefill)
        draft.name = name
        draft.dose = dose
        draft.note = note
        draft.times = ScheduleTimeRow.times(times)
        draft.category = category
        draft.treatmentClass = treatmentClass
        draft.dosesPerUnitText = dosesPerUnitText
        draft.unitsPerDose = unitsPerDose
        draft.notificationsEnabled = notificationsEnabled
        draft.deliveryForm = deliveryForm
        draft.trackInjectionSites = trackInjectionSites
        draft.allowedInjectionSites = allowedInjectionSites
        draft.cadenceKind = cadenceKind
        draft.cadenceSub = cadenceSub
        draft.startsOn = startsOn
        draft.endsOn = endsOn
        draft.isOneShot = isOneShot
        draft.graceMinutes = graceEnabled ? graceMinutes : nil
        draft.slotUnitsPerDose = resolvedSlotDoses
        draft.intake = intake
        draft.autoMarkTaken = autoMarkTaken
        // The medication-level booleans ARE the user-level roaming default:
        // sent only for "Alle Geräte"; "Dieses Gerät" stays a local override.
        draft.liveActivityEnabled = liveActivityScope == .allDevices ? liveActivityEnabled : nil
        draft.criticalAlarmEnabled = criticalAlarmScope == .allDevices ? criticalAlarmEnabled : nil
        return draft
    }

    // MARK: - Save

    /// Persist both delivery prefs at the chosen scope, independent
    /// of the PUT. An "Alle Geräte" write that the delivery-defaults seam does
    /// not take falls back to a device-local override inside the store; the
    /// medication row carries the roaming value (``draft``).
    private func persistDeliveryPreferences() async {
        await deliveryPreferences.set(
            enabled: liveActivityEnabled,
            scope: liveActivityScope,
            medicationId: medication.id,
            channel: .liveActivity
        )
        await deliveryPreferences.set(
            enabled: criticalAlarmEnabled,
            scope: criticalAlarmScope,
            medicationId: medication.id,
            channel: .criticalAlarm
        )
    }

    private func save() async -> Bool {
        guard !isSaving, isValid else { return false }
        isSaving = true
        defer { isSaving = false }
        saveError = nil

        await persistDeliveryPreferences()

        // RMW rules (schedules, unitsPerDose, category, treatmentClass,
        // trackIntake) live in `MedicationEditDraft.patch(for:)`.
        guard let patch = draft?.patch(for: medication) else { return false }

        let outcome = await store.update(id: medication.id, patch: patch)
        switch outcome {
        case .success, .queued:
            saveTick &+= 1 // Success haptic before dismiss.
            onSaved()
            return true
        case let .failed(err):
            saveError = err
            saveErrorTick &+= 1 // Error haptic, sheet stays open.
        }
        return false
    }

    /// Binds a `DatePicker` to the time-row identified by `rowID`.
    /// Resolving by stable id — not array offset — means a remove that shifts
    /// indices can never re-point an open picker at a different row.
    private func bindingForTime(rowID: UUID) -> Binding<Date> {
        Binding(
            get: {
                let time = times.first(where: { $0.id == rowID })?.time ?? TimeOfDay(hour: 12, minute: 0)
                let calendar = Calendar.current
                let now = Date()
                return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now) ?? now
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                guard let idx = times.firstIndex(where: { $0.id == rowID }) else { return }
                times[idx].time = TimeOfDay(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
            }
        )
    }
}
