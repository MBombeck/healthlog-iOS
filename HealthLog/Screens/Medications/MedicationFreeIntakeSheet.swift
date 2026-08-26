import SwiftUI

/// **Build 6.1 — free, back-datable intake logging.**
///
/// The "ich habe eine Dosis genommen (oder ausgelassen), trage sie nach"-flow
/// that does not need a pending slot row. Reached from
/// ``MedicationQuickIntakeSheet`` (its empty state + chooser header) so the
/// operator always has a way to log a dose even when nothing is due right now,
/// and to back-date a dose they took earlier.
///
/// Fields map 1:1 onto the server `MedicationIntakeRequest`
/// (`POST /api/medications/{id}/intake`): the picked medication (path), a
/// back-datable `takenAt`, a `skipped` flag, and an optional `doseTaken`
/// deviation. **No `source`** is ever sent (Issue #64 — the server derives
/// provenance from the request context). The write rides
/// `MedicationsStore.logIntakeFree` (idempotency + outbox), so an offline
/// back-log queues and replays exactly-once.
struct MedicationFreeIntakeSheet: View {
    @Environment(MedicationsStore.self) private var store

    /// Optional preselected medication (e.g. opened from a specific card). When
    /// nil the operator picks from the active list.
    var preselectedMedicationID: String?
    /// Bubbled outcome so the host can dismiss on `.success` / `.queued` or keep
    /// the sheet open on `.failed` (the inline error stays visible).
    let onDone: (MedicationsStore.WriteOutcome) -> Void

    private enum Status: Hashable {
        case taken
        case skipped
    }

    @State private var selectedMedicationID: String = ""
    @State private var status: Status = .taken
    @State private var takenAt: Date = .now
    @State private var doseTaken: String = ""
    @State private var isSaving = false
    @State private var saveError: HLError?
    @State private var saveTick = 0
    @State private var saveErrorTick = 0

    /// Active meds are the only valid targets — an archived / paused med should
    /// be reactivated before logging against it.
    private var candidates: [Medication] {
        store.medications.filter(\.active)
    }

    /// The `takenAt` picker floor mirrors the server plausibility bound
    /// (`TAKEN_AT_MAX_AGE_MS`, 5 years) so a back-date can never round-trip into
    /// the 422; the ceiling is `now` (no future doses).
    private var earliestAllowed: Date {
        Date.now.addingTimeInterval(-MedicationsStore.takenAtMaxAge)
    }

    private var isValid: Bool {
        !selectedMedicationID.isEmpty && candidates.contains { $0.id == selectedMedicationID }
    }

    /// CU-24 (GH #73) — non-nil exactly when there is nothing to log against, so
    /// the sheet renders the shared honest empty state instead of an empty form
    /// with a permanently disabled save button. `candidates` is the active
    /// medication list, so an empty form can only ever mean "no active
    /// medication exists" (or "not loaded yet") — never "nothing due", which is
    /// a schedule state this sheet does not depend on.
    private var emptyState: MedicationLoggingEmptyState? {
        guard candidates.isEmpty else { return nil }
        return MedicationLoggingEmptyState.resolve(
            hasLoadedMedications: store.hasLoadedMedications,
            hasActiveMedications: false
        )
    }

    var body: some View {
        Group {
            if let emptyState {
                // No toolbar save action here: a disabled primary button is the
                // dead end the reporter ran into. The create CTA is the way out.
                MedicationLoggingEmptyStateView(state: emptyState)
            } else {
                form
            }
        }
        .navigationTitle(Text("med.freelog.title"))
        .navigationBarTitleDisplayMode(.inline)
        // GH #80 — KEIN eigener "Abbrechen"-Knopf mehr. Dieses Blatt wird
        // ausschliesslich aus `MedicationQuickIntakeSheet` heraus GESCHOBEN
        // (die einzige Aufrufstelle), trägt also ohnehin den Zurück-Pfeil des
        // NavigationStacks. Der zweite Ausgang daneben war keine zweite
        // Möglichkeit, sondern eine zweite Frage — welcher ist der richtige? —
        // auf die es keine Antwort gab, weil beide dasselbe taten.
        //
        // Der `onCancel`-Rückkanal ist mit dem Knopf entfallen: er hatte
        // keinen anderen Aufrufer. Ein künftiger Aufruf als Wurzel eines
        // eigenen Stacks führt ihn wieder ein — dann mit einem echten Grund.
        .toolbar {
            if emptyState == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("med.freelog.save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !isValid)
                }
            }
        }
        .sensoryFeedback(.success, trigger: saveTick)
        .sensoryFeedback(.error, trigger: saveErrorTick)
        .onAppear(perform: seedSelection)
    }

    private var form: some View {
        Form {
            medicationSection
            statusSection
            whenSection
            if status == .taken {
                doseSection
            }
            if let saveError {
                Section {
                    HLFormErrorText(saveError.userFacingDescription)
                        .font(.hlSubhead)
                }
            }
        }
        .hlScrollEdgeSoft()
    }

    private var medicationSection: some View {
        Section {
            if let locked = preselectedMedicationID,
               let med = candidates.first(where: { $0.id == locked })
            {
                LabeledContent("med.freelog.medication.label") {
                    Text(med.name).foregroundStyle(HLText.secondary)
                }
            } else {
                Picker("med.freelog.medication.label", selection: $selectedMedicationID) {
                    ForEach(candidates) { med in
                        Text(med.name).tag(med.id)
                    }
                }
            }
        } header: {
            Text("med.freelog.medication.header")
        }
    }

    private var statusSection: some View {
        Section {
            Picker("med.freelog.status.label", selection: $status) {
                Text("med.freelog.status.taken").tag(Status.taken)
                Text("med.freelog.status.skipped").tag(Status.skipped)
            }
            .pickerStyle(.segmented)
        }
    }

    private var whenSection: some View {
        Section {
            DatePicker(
                "med.freelog.when.label",
                selection: $takenAt,
                in: earliestAllowed ... Date.now,
                displayedComponents: [.date, .hourAndMinute]
            )
        } header: {
            Text("med.freelog.when.header")
        } footer: {
            Text("med.freelog.when.footer")
                .font(.hlCaption)
        }
    }

    private var doseSection: some View {
        Section {
            TextField("med.freelog.dose.placeholder", text: $doseTaken)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
        } header: {
            Text("med.freelog.dose.header")
        } footer: {
            Text("med.freelog.dose.footer")
                .font(.hlCaption)
        }
    }

    private func seedSelection() {
        if let preselectedMedicationID,
           candidates.contains(where: { $0.id == preselectedMedicationID })
        {
            selectedMedicationID = preselectedMedicationID
        } else if selectedMedicationID.isEmpty {
            selectedMedicationID = candidates.first?.id ?? ""
        }
    }

    private func save() async {
        guard !isSaving, isValid else { return }
        isSaving = true
        defer { isSaving = false }
        saveError = nil

        let skipped = status == .skipped
        let outcome = await store.logIntakeFree(
            medicationId: selectedMedicationID,
            takenAt: takenAt,
            skipped: skipped,
            // Bind a skip to the picked day's slot; a take lets the server
            // default `scheduledFor` to `takenAt`.
            scheduledFor: skipped ? takenAt : nil,
            doseTaken: skipped ? nil : doseTaken
        )
        switch outcome {
        case .success, .queued:
            saveTick &+= 1
            onDone(outcome)
        case let .failed(err):
            saveError = err
            saveErrorTick &+= 1
        }
    }
}
