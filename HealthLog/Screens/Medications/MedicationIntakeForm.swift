import SwiftUI

/// **The one intake form** (#191, server 1.49.0, web `intake-form.tsx`).
///
/// The free back-log page, the deviating-dose dialog and the post-save "attribute
/// to this slot?" question were three ways to log a dose with three field sets.
/// All of them are this form now, with these fields in this order:
///
///   Medication (a picker when not opened from one), Taken / Skipped (only for
///   a medication with dose times), Time, Dose (pre-filled with the planned
///   dose), and a line saying where the dose counts ("Counts for the 08:00
///   dose"), with a switch for a take one to four hours off a dose time.
///
/// The rule is ``IntakeSlotAttribution``; the write is ``IntakeFormWrite`` on
/// `POST /api/medications/{id}/intake` through
/// `MedicationsStore.logIntakeFree` (idempotency + outbox), so an offline log
/// queues and replays exactly once. No `source` is sent (Issue #64).
struct MedicationIntakeForm: View {
    /// Where the form stands: pushed onto a sheet's stack (the Erfassen
    /// sheet), or as its own sheet (the card's long press on Taken).
    enum Presentation {
        case pushed
        case sheet
    }

    enum Outcome: Hashable {
        case taken
        case skipped
    }

    @Environment(MedicationsStore.self) private var store

    /// A medication the form is opened from. When nil the person picks from
    /// the active list.
    var preselectedMedicationID: String?
    var presentation: Presentation = .pushed
    /// Bubbled outcome so the host can close on `.success` / `.queued`; on
    /// `.failed` the form stays with its inline error.
    let onDone: (MedicationsStore.WriteOutcome) -> Void

    @State private var selectedMedicationID: String = ""
    @State private var outcome: Outcome = .taken
    @State private var takenAt: Date = .now
    /// The typed dose; nil while the field shows the configured dose.
    @State private var doseOverride: String?
    /// "Count it for the 08:00 dose", on by default.
    @State private var countNear = true
    @State private var isSaving = false
    @State private var saveError: HLError?
    @State private var saveTick = 0
    @State private var saveErrorTick = 0
    /// The open slots of the chosen day, as the server lists them (#191);
    /// `nil` while loading or when the ledger could not be read.
    @State private var daySlots: [IntakeSlotAttribution.DaySlot]?

    /// The server caps `doseTaken` at 50 characters.
    static let doseMaxLength = 50

    // MARK: - State read off the fields

    /// Active meds only. v1.39.1: a medication kept as a record offers no
    /// intake, and v1.39.4 neither does one the server calls not actionable today.
    private var candidates: [Medication] {
        store.medications.filter { $0.active && $0.offersIntakeActions }
    }

    private var medication: Medication? {
        candidates.first { $0.id == selectedMedicationID }
    }

    /// The calendar of the account's zone: the dose times are wall-clock
    /// times there, and the time picker writes in it.
    private var calendar: Calendar {
        MedicationDueRule.calendar(timeZone: store.profileTimeZone)
    }

    /// A day without an open slot has no dose to skip; the server says
    /// which slots exist (#191), the app never computes the cadence.
    private var canSkip: Bool {
        !(daySlots ?? []).isEmpty
    }

    /// What the day's ledger is read for: the medication and the day.
    private var daySlotsKey: String {
        "\(selectedMedicationID)|\(calendar.startOfDay(for: takenAt).timeIntervalSince1970)"
    }

    private var isSkipped: Bool {
        canSkip && outcome == .skipped
    }

    private var attribution: IntakeSlotAttribution {
        IntakeSlotAttribution.resolve(
            takenAt: takenAt,
            daySlots: daySlots ?? [],
            skipped: isSkipped,
            countNear: countNear
        )
    }

    private var configuredDose: String {
        guard let medication else { return "" }
        return IntakeSlotAttribution.configuredDose(for: medication, attribution: attribution)
    }

    private var doseBinding: Binding<String> {
        Binding(
            get: { doseOverride ?? configuredDose },
            set: { doseOverride = String($0.prefix(Self.doseMaxLength)) }
        )
    }

    /// The `takenAt` floor mirrors the server plausibility bound (5 years);
    /// the ceiling is now, a dose is not logged ahead.
    private var earliestAllowed: Date {
        Date.now.addingTimeInterval(-MedicationsStore.takenAtMaxAge)
    }

    private var isValid: Bool {
        medication != nil
    }

    private var isDirty: Bool {
        outcome != .taken || doseOverride != nil || !countNear
    }

    /// Non-nil exactly when there is nothing to log against.
    private var emptyState: MedicationLoggingEmptyState? {
        guard candidates.isEmpty else { return nil }
        return MedicationLoggingEmptyState.resolve(
            hasLoadedMedications: store.hasLoadedMedications,
            hasActiveMedications: false
        )
    }

    /// The bar's action, spoken as the verb of the outcome ("Take" / "Skip").
    private var action: HLSheetAction {
        guard emptyState == nil else { return .none }
        let word: LocalizedStringKey = isSkipped ? "med.dose.action.skip" : "med.dose.action.take"
        return .confirm(word, isEnabled: isValid && !isSaving) { await save() }
    }

    // MARK: - Body

    var body: some View {
        switch presentation {
        case .pushed:
            content
                .navigationTitle(Text("med.dose.form.title"))
                .navigationBarTitleDisplayMode(.inline)
                // The page never goes back by itself: on success the host
                // closes the whole flow in `onDone`.
                .hlConfirmBar(action, identifier: "med.intake_form.save")
        case .sheet:
            HLSheetScaffold(
                "med.dose.form.title",
                action: action,
                isDirty: isDirty,
                confirmIdentifier: "med.intake_form.save"
            ) {
                content
            }
        }
    }

    private var content: some View {
        Group {
            if let emptyState {
                MedicationLoggingEmptyStateView(state: emptyState)
            } else {
                form
            }
        }
        .sensoryFeedback(.success, trigger: saveTick)
        .sensoryFeedback(.error, trigger: saveErrorTick)
        .onAppear(perform: seedSelection)
        .onChange(of: selectedMedicationID) { _, _ in
            // A medication switch starts its dose over.
            doseOverride = nil
        }
        .task(id: daySlotsKey) {
            guard !selectedMedicationID.isEmpty else { return }
            daySlots = nil
            daySlots = await store.daySlots(medicationId: selectedMedicationID, day: takenAt)
            if !canSkip { outcome = .taken }
        }
    }

    private var form: some View {
        Form {
            medicationSection
            if canSkip {
                outcomeSection
            }
            timeSection
            if !isSkipped {
                doseSection
                if let near = attribution.nearSlot {
                    countNearSection(near)
                }
            }
            if let saveError {
                Section {
                    HLFormErrorText(saveError.userFacingDescription)
                }
                .hlFormRowSurface()
            }
        }
        .hlPageMargins()
        .hlScrollEdgeSoft()
    }

    private var medicationSection: some View {
        Section {
            if let locked = preselectedMedicationID,
               let med = candidates.first(where: { $0.id == locked })
            {
                LabeledContent {
                    Text(verbatim: med.name).hlText(.rowSubtitle)
                } label: {
                    HLRowTitle("med.intake_form.medication")
                }
            } else {
                Picker(selection: $selectedMedicationID) {
                    ForEach(candidates) { med in
                        Text(verbatim: med.name).tag(med.id)
                    }
                } label: {
                    HLRowTitle("med.intake_form.medication")
                }
                .accessibilityIdentifier("med.intake_form.medication")
            }
            if let note = medication?.note {
                MedicationNoteLine(note: note)
            }
        }
        .hlFormRowSurface()
    }

    private var outcomeSection: some View {
        Section {
            HLAdaptiveSegmentedPicker(
                "med.intake_form.outcome",
                selection: $outcome,
                labels: ["med.dose.state.taken", "med.dose.state.skipped"]
            ) {
                Text("med.dose.state.taken").tag(Outcome.taken)
                Text("med.dose.state.skipped").tag(Outcome.skipped)
            }
            .accessibilityIdentifier("med.intake_form.outcome")
        }
        .hlFormRowSurface()
    }

    private var timeSection: some View {
        Section {
            DatePicker(
                selection: $takenAt,
                in: earliestAllowed ... Date.now,
                displayedComponents: [.date, .hourAndMinute]
            ) {
                HLRowTitle("med.intake_form.time")
            }
            // The dose times are wall-clock times of the account's zone.
            .environment(\.timeZone, store.profileTimeZone)
            .accessibilityIdentifier("med.intake_form.time")
        } footer: {
            // A skip has no dose field, so its line stands here.
            if isSkipped, let line = Self.line(for: attribution) {
                attributionLine(line)
            }
        }
        .hlFormRowSurface()
    }

    private var doseSection: some View {
        Section {
            HLFormField("med.intake_form.dose") {
                TextField(text: doseBinding, prompt: Text(verbatim: configuredDose)) {
                    Text("med.intake_form.dose")
                }
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .accessibilityIdentifier("med.intake_form.dose")
            }
        } footer: {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("med.intake_form.dose_hint")
                    .hlText(.note)
                // Without the switch the line follows the last field.
                if attribution.nearSlot == nil, let line = Self.line(for: attribution) {
                    attributionLine(line)
                }
            }
        }
        .hlFormRowSurface()
    }

    private func countNearSection(_ near: IntakeSlotAttribution.Slot) -> some View {
        Section {
            // The title is already localised and carries the time; as a key
            // it finds no entry and is shown as it is.
            HLSettingsToggleRow(
                title: LocalizedStringKey(Self.countNearTitle(near)),
                description: nil,
                isOn: $countNear,
                accessibilityID: "med.intake_form.count_near"
            )
        } footer: {
            if let line = Self.line(for: attribution) {
                attributionLine(line)
            }
        }
        .hlFormRowSurface()
    }

    private func attributionLine(_ line: String) -> some View {
        Text(verbatim: line)
            .hlText(.note)
            .accessibilityIdentifier("med.intake_form.counts_for")
    }

    // MARK: - Words

    /// A dose time in the person's hour cycle.
    static func clock(_ slot: IntakeSlotAttribution.Slot) -> String {
        HLTimeFormat.clock(minutesAfterMidnight: slot.minutesAfterMidnight)
    }

    static func countNearTitle(_ slot: IntakeSlotAttribution.Slot) -> String {
        String(
            format: String(localized: "med.intake_form.count_near", defaultValue: "Count it for the %@ dose"),
            clock(slot)
        )
    }

    /// The attribution in words, under the fields; nil when there is nothing
    /// to say (a skip without a dose time, which the form never offers).
    static func line(for attribution: IntakeSlotAttribution) -> String? {
        switch attribution {
        case let .slot(slot):
            String(
                format: String(localized: "med.intake_form.counts_for", defaultValue: "Counts for the %@ dose."),
                clock(slot)
            )
        case let .late(slot):
            String(
                format: String(localized: "med.intake_form.counts_for_late", defaultValue: "Counts for the %@ dose, as late."),
                clock(slot)
            )
        case let .skip(slot):
            String(
                format: String(localized: "med.intake_form.skips", defaultValue: "Skips the %@ dose."),
                clock(slot)
            )
        case .extra:
            String(
                localized: "med.intake_form.extra_dose",
                defaultValue: "Recorded as an extra dose, outside the schedule."
            )
        case .noSlot:
            nil
        }
    }

    // MARK: - Actions

    private func seedSelection() {
        if let preselectedMedicationID,
           candidates.contains(where: { $0.id == preselectedMedicationID })
        {
            selectedMedicationID = preselectedMedicationID
        } else if selectedMedicationID.isEmpty {
            selectedMedicationID = candidates.first?.id ?? ""
        }
    }

    /// Pushed, the host decides how the page goes away, so it answers
    /// `false`; as its own sheet it closes on success.
    private func save() async -> Bool {
        guard !isSaving, let medication else { return false }
        isSaving = true
        defer { isSaving = false }
        saveError = nil

        let write = IntakeFormWrite(
            attribution: attribution,
            takenAt: takenAt,
            skipped: isSkipped,
            dose: doseOverride ?? configuredDose,
            configuredDose: configuredDose
        )
        let result = await store.logIntakeFree(
            medicationId: medication.id,
            takenAt: write.takenAt,
            skipped: write.skipped,
            scheduledFor: write.scheduledFor,
            doseTaken: write.doseTaken,
            forceSlotInstant: write.forceSlotInstant
        )
        switch result {
        case .success, .queued:
            saveTick &+= 1
            onDone(result)
            return presentation == .sheet
        case let .failed(err):
            saveError = err
            saveErrorTick &+= 1
            return false
        }
    }
}
