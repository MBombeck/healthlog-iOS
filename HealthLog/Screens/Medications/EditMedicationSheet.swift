import SwiftUI

/// Presented from `MedicationsScreen` row swipe-action "Bearbeiten" or from
/// `MedicationDetailScreen`'s edit-toolbar. Pre-fills the same fields the
/// add-sheet exposes; save sends `PUT /api/medications/[id]` via
/// `MedicationsStore.update`.
///
/// **v0.10 R1 §3.7 — cadence edit + RMW safety.** The cadence picker is
/// pre-selected from the decoded `ScheduleEntry` (`MedicationCadenceLogic.infer`,
/// mirroring the web `inferCadenceFromLegacy`). On save, `schedules` is only
/// rebuilt when the user actually touched the schedule (cadence / times /
/// course / grace) — otherwise it stays `nil` so the server-side replace never
/// drops an unchanged `rrule` / `rolling` / `asNeeded` / cyclic triple (R1
/// risk 5). A delivery-only edit therefore sends `schedules == nil`.
struct EditMedicationSheet: View {
    let medication: Medication
    let onSaved: () -> Void
    let onDismiss: () -> Void

    // Non-private so the Build 6.2 lifecycle extension (`+Lifecycle.swift`,
    // split out for file_length) can read the store.
    @Environment(MedicationsStore.self) var store
    @Environment(DeliveryPreferencesStore.self) private var deliveryPreferences

    // Editable state, pre-filled in onAppear.
    @State private var name: String = ""
    @State private var dose: String = ""
    @State private var times: [ScheduleTimeRow] = []
    /// `nil` = a stored category this build has no row for (shown as itself, never rewritten).
    @State private var category: MedicationCategoryOption? = .other
    @State private var treatmentClass: MedicationTreatmentClassOption = .generic
    @State private var dosesPerUnitText: String = ""
    /// **H1/H2** — units one dose consumes (whole / curated fraction / any other server value, kept as is).
    @State private var unitsPerDose: MedicationUnitsPerDose = .whole(1)
    /// **#219 — the RAW per-slot overrides the server sent**, keyed by `HH:mm`.
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
    // v0.11 — injection-site tracking (only meaningful for INJECTION route).
    @State private var trackInjectionSites: Bool = false
    @State private var allowedInjectionSites: Set<InjectionSite> = []

    // v0.10 — cadence + course window
    @State private var cadenceKind: CadenceKind = .daily
    @State private var cadenceSub: CadenceSubControls = .makeDefault()
    @State private var startsOn: Date?
    @State private var endsOn: Date?
    @State private var isOneShot: Bool = false
    /// v1.39.1 (#1033) — the intake-tracking switch and the server's own value.
    @State private var intake = MedicationTrackIntakeFormValue()
    @State private var graceEnabled: Bool = false
    @State private var graceMinutes: Int = 60
    /// The form as it opened — the baseline every RMW decision of the PUT is
    /// taken against (``MedicationEditDraft``).
    @State private var prefill: EditMedicationFormState?

    /// v0.9.0 RA3 — per-medication Live-Activity opt-in + scope.
    @State private var liveActivityEnabled = DeliveryChannel.liveActivity.hardcodedDefault
    @State private var liveActivityScope: DeliveryScope = .allDevices
    /// v0.9.0 — per-medication AlarmKit critical-alarm opt-in + scope
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
    /// QoL-1 (A360-4) — Save haptic drivers (see `AddMedicationSheet`). `saveTick`
    /// bumps on a successful/queued PUT, `saveErrorTick` on a failure.
    @State var saveTick: Int = 0
    @State var saveErrorTick: Int = 0
    /// FORM-2 initial focus + name→dose chain; 15-02 (B3) — the single copy of
    /// the truth, with ``MedicationEditorFocus`` deciding where it belongs.
    @FocusState private var focusedField: MedicationEditorFocus.Field?
    /// True once a save actually degraded an "Alle Geräte" delivery pref to a
    /// device-local override (the server roaming field isn't live yet). Drives
    /// the non-blocking "Server-Sync folgt" hint so it reflects the real write
    /// outcome, not just the picker selection (FIX 1 / AUDIT-G A1).
    @State private var deliveryDidDegrade: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name & dose") {
                    TextField("med.form.name.label", text: $name)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = MedicationEditorFocus.resolve(.submitted(.name), from: focusedField) }
                    TextField("med.form.dose.label", text: $dose)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .focused($focusedField, equals: .dose)
                        .submitLabel(.done)
                }

                if intake.server != nil { MedicationTrackIntakeSection(isOn: $intake.tracked) }

                Section {
                    CadencePicker(kind: $cadenceKind, sub: $cadenceSub)
                        .onChange(of: cadenceKind) { _, newKind in
                            enforceTimeConstraints(for: newKind)
                        }
                        .simultaneousGesture(scheduleEngagement, including: .all)
                    if let nextDue = medication.nextDueAt {
                        // Read-only display of the server-computed next reminder
                        // instant (SB-SCHED-3). NEVER sent on PUT — it is purely
                        // informational and already drives the local reminders.
                        LabeledContent("med.schedule.nextDose.label") {
                            Text(nextDue, style: .relative)
                                .foregroundStyle(HLText.secondary)
                        }
                    }
                } header: {
                    Text("med.schedule.cadence.section")
                }

                if cadenceKind != .asNeeded {
                    timesSection.simultaneousGesture(scheduleEngagement, including: .all)
                }

                Section {
                    CourseWindowRow(startsOn: $startsOn, endsOn: $endsOn, isOneShot: $isOneShot)
                        .onChange(of: isOneShot) { _, oneShot in
                            if oneShot { enforceTimeConstraints(for: cadenceKind) }
                        }
                } header: {
                    Text("med.schedule.course.section")
                }

                Section("Properties") {
                    Picker("Category", selection: $category) {
                        if let label = prefill?.unknownCategoryLabel { Text(label).tag(MedicationCategoryOption?.none) }
                        ForEach(MedicationCategoryOption.allCases) { option in
                            Text(option.displayName).tag(Optional(option))
                        }
                    }
                    Picker("Class", selection: $treatmentClass) {
                        ForEach(MedicationTreatmentClassOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    Picker("med.schedule.advanced.deliveryForm.label", selection: $deliveryForm) {
                        ForEach(MedicationDeliveryFormOption.allCases) { option in
                            Text(option.labelKey).tag(option)
                        }
                    }
                    InjectionSiteTrackingSection(
                        isInjection: .constant(deliveryForm == .injection),
                        trackInjectionSites: $trackInjectionSites,
                        allowedInjectionSites: $allowedInjectionSites
                    )
                    TextField("med.form.dosesPerUnit.label", text: $dosesPerUnitText)
                        .keyboardType(.numberPad)
                    UnitsPerDosePicker(selection: $unitsPerDose)
                    Toggle("Notifications", isOn: $notificationsEnabled)
                    if cadenceKind != .asNeeded {
                        Toggle("med.schedule.advanced.grace.toggle", isOn: $graceEnabled)
                        if graceEnabled {
                            HLIntStepperRow(
                                titleKey: "med.schedule.advanced.grace.label",
                                value: $graceMinutes,
                                range: 1 ... 1440,
                                unitKey: nil
                            )
                        }
                    }
                }

                deliverySection

                lifecycleSection

                if let saveError {
                    Section {
                        HLFormErrorText(saveError.userFacingDescription)
                            .font(.hlSubhead)
                    }
                }
            }
            .hlScrollEdgeSoft()
            // 15-02 (B3) — a drag puts the keyboard away as it goes.
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !isValid || isRequestingAlarmAuth)
                }
            }
            .onAppear(perform: prefillOnce)
            // QoL-1 — Save success/error haptic, mirroring the intake path.
            .sensoryFeedback(.success, trigger: saveTick)
            .sensoryFeedback(.error, trigger: saveErrorTick)
            // FORM-2 — seed focus onto the name field once the sheet settles.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = MedicationEditorFocus.resolve(.sheetSettled, from: focusedField)
            }
        }
        .interactiveDismissDisabled(isSaving)
        .hlSheetPresentation(.form)
    }

    /// 15-02 (B3) — the Zeitplan row became the interaction target, reported on
    /// the way DOWN so the picker's own tap handling stays untouched.
    private var scheduleEngagement: some Gesture {
        TapGesture().onEnded { focusedField = MedicationEditorFocus.resolve(.scheduleEditorEngaged, from: focusedField) }
    }

    private var timesSection: some View {
        Section {
            ForEach(Array(times.enumerated()), id: \.element.id) { idx, row in
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    HStack {
                        DatePicker(
                            String(localized: "med.form.time.label \(idx + 1)"),
                            selection: bindingForTime(rowID: row.id),
                            displayedComponents: [.hourAndMinute]
                        )
                        .labelsHidden()
                        Spacer()
                        if times.count > 1 {
                            Button {
                                times.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(HLColor.statusBad)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Remove time"))
                        }
                        Text(MedicationFormLogic.formatTime(row.time))
                            .font(.hlMetric(.subheadline))
                            .foregroundStyle(HLText.secondary)
                            .monospacedDigit()
                    }
                    slotDoseRow(for: row.time, index: idx)
                }
            }
            if times.count < MedicationCadenceLogic.maxTimes(for: cadenceKind) {
                Button {
                    times.append(ScheduleTimeRow(time: TimeOfDay(hour: 12, minute: 0)))
                } label: {
                    Label("med.schedule.times.add", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("med.schedule.times.header")
        } footer: {
            Text(timesFooterKey)
                .font(.hlCaption)
        }
    }

    // MARK: - Per-slot inventory dose (#219 / v1.37.19)

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

    /// v0.9.0 RA3 — unified per-medication delivery preferences: Live
    /// Activity + AlarmKit critical alarm, each with a "Dieses Gerät / Alle
    /// Geräte" scope picker (progressive disclosure). Critical-alarm row is
    /// iOS 26-gated.
    private var deliverySection: some View {
        Section {
            Toggle("med.edit.live_activity", isOn: $liveActivityEnabled)
            if liveActivityEnabled {
                scopePicker(selection: $liveActivityScope)
            }
            if #available(iOS 26.0, *) {
                Toggle("med.edit.critical_alarm", isOn: $criticalAlarmEnabled)
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
            }
        } header: {
            Text("med.edit.delivery.section")
        } footer: {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("med.edit.live_activity.footer")
                if #available(iOS 26.0, *) {
                    Text("med.edit.critical_alarm.footer")
                    if criticalAlarmDenied {
                        Text("med.edit.critical_alarm.denied")
                            .foregroundStyle(HLColor.statusWarn)
                    }
                }
                if deliveryDidDegrade
                    || liveActivityScope == .allDevices
                    || criticalAlarmScope == .allDevices
                {
                    Text("med.edit.scope.sync_pending")
                        .foregroundStyle(HLText.tertiary)
                }
            }
            .font(.hlCaption)
        }
    }

    private func scopePicker(selection: Binding<DeliveryScope>) -> some View {
        Picker("med.edit.scope.label", selection: selection) {
            Text("med.edit.scope.this_device").tag(DeliveryScope.thisDevice)
            Text("med.edit.scope.all_devices").tag(DeliveryScope.allDevices)
        }
        .pickerStyle(.segmented)
    }

    /// Request AlarmKit authorization the first time the user opts a med into
    /// the critical alarm. On denial, flip the toggle back off + surface the
    /// footer hint.
    private func requestAlarmAuthorizationIfNeeded() async {
        #if canImport(AlarmKit)
            if #available(iOS 26.0, *) {
                isRequestingAlarmAuth = true
                defer { isRequestingAlarmAuth = false }
                let granted = await CriticalMedAlarmService.shared.requestAuthorizationIfNeeded()
                if !granted {
                    criticalAlarmEnabled = false
                    criticalAlarmDenied = true
                }
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
        times = ScheduleTimeRow.rows(state.times)
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
        graceEnabled = state.graceMinutes != nil
        graceMinutes = state.graceMinutes ?? 60
        prefill = state
        let la = deliveryPreferences.effective(medicationId: medication.id, channel: .liveActivity)
        liveActivityEnabled = la.enabled
        liveActivityScope = la.scope
        let alarm = deliveryPreferences.effective(medicationId: medication.id, channel: .criticalAlarm)
        criticalAlarmEnabled = alarm.enabled
        criticalAlarmScope = alarm.scope
    }
}

// MARK: - Time constraints / validation / save

extension EditMedicationSheet {
    func enforceTimeConstraints(for kind: CadenceKind) {
        let maxTimes = MedicationCadenceLogic.maxTimes(for: kind)
        if times.count > maxTimes {
            times = Array(times.prefix(max(maxTimes, 0)))
        }
        if kind == .asNeeded {
            graceEnabled = false
        }
    }

    private var timesFooterKey: LocalizedStringKey {
        switch cadenceKind {
        case .rolling: "med.schedule.times.footer.rolling"
        case .asNeeded: "med.schedule.times.footer.asNeeded"
        default: "med.schedule.times.footer.standard"
        }
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
        // The medication-level booleans ARE the user-level roaming default:
        // sent only for "Alle Geräte"; "Dieses Gerät" stays a local override.
        draft.liveActivityEnabled = liveActivityScope == .allDevices ? liveActivityEnabled : nil
        draft.criticalAlarmEnabled = criticalAlarmScope == .allDevices ? criticalAlarmEnabled : nil
        return draft
    }

    // MARK: - Save

    /// v0.9.0 RA3 — persist both delivery prefs at the chosen scope, independent
    /// of the PUT, and report whether either write degraded to a device-local
    /// override (the non-blocking "Server-Sync folgt" hint; FIX 1 / AUDIT-G A1).
    private func persistDeliveryPreferences() async -> Bool {
        let liveStored = await deliveryPreferences.set(
            enabled: liveActivityEnabled,
            scope: liveActivityScope,
            medicationId: medication.id,
            channel: .liveActivity
        )
        let alarmStored = await deliveryPreferences.set(
            enabled: criticalAlarmEnabled,
            scope: criticalAlarmScope,
            medicationId: medication.id,
            channel: .criticalAlarm
        )
        return !liveStored || !alarmStored
    }

    private func save() async {
        guard !isSaving, isValid else { return }
        isSaving = true
        defer { isSaving = false }
        saveError = nil

        deliveryDidDegrade = await persistDeliveryPreferences()

        // RMW rules (schedules, unitsPerDose, category, treatmentClass,
        // trackIntake) live in `MedicationEditDraft.patch(for:)`.
        guard let patch = draft?.patch(for: medication) else { return }

        let outcome = await store.update(id: medication.id, patch: patch)
        switch outcome {
        case .success, .queued:
            saveTick &+= 1 // QoL-1 — success haptic before dismiss.
            onSaved()
        case let .failed(err):
            saveError = err
            saveErrorTick &+= 1 // QoL-1 — error haptic, sheet stays open.
        }
    }

    /// Binds a `DatePicker` to the time-row identified by `rowID` (A360-5 H-3).
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
