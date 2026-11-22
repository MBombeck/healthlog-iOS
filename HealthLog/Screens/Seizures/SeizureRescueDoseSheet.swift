import SwiftUI

/// Add a rescue dose to a recorded seizure. Opens with the drug, dose and
/// route of the type's plan; a dose of the plan's medication also records an
/// intake on it (server-side). A different drug, typed here, is recorded by
/// name only (a dose given by paramedics, for example).
struct SeizureRescueDoseSheet: View {
    let store: SeizuresStore
    let event: SeizureEventDTO

    @State private var draft: SeizureRescueDoseDraft
    @State private var saveError: String?
    @State private var idempotencyKey = IdempotencyKey()

    init(store: SeizuresStore, event: SeizureEventDTO) {
        self.store = store
        self.event = event
        _draft = State(initialValue: SeizureRescueDoseDraft(
            plan: store.diary?.type(id: event.typeProfileId),
            givenAt: event.onsetDate ?? .now
        ))
    }

    var body: some View {
        HLSheetScaffold(
            "seizures.rescue.add",
            action: .add(isEnabled: draft.isValid) { await save() },
            isDirty: true
        ) {
            Form {
                Group {
                    Section {
                        TextField("seizures.rescue.medicationPlaceholder", text: $draft.medicationName)
                            .accessibilityIdentifier("seizures.rescue.medicationName")
                        HStack(spacing: HLSpace.md) {
                            TextField("seizures.rescue.dose", text: $draft.amount)
                                .keyboardType(.decimalPad)
                            TextField("seizures.rescue.unit", text: $draft.unit)
                        }
                        Picker(selection: $draft.route) {
                            Text("seizures.notRecorded").tag(nil as SeizureRescueRoute?)
                            ForEach(SeizureRescueRoute.choices, id: \.self) { Text($0.label).tag(Optional($0)) }
                        } label: {
                            HLRowTitle("seizures.rescue.route")
                        }
                    } header: {
                        Text("seizures.rescue.medication")
                    } footer: {
                        if draft.usesPlan { Text("seizures.rescue.fromPlan") }
                    }
                    Section {
                        DatePicker(
                            selection: $draft.givenAt,
                            in: ...Date.now.addingTimeInterval(300),
                            displayedComponents: [.date, .hourAndMinute]
                        ) {
                            HLRowTitle("seizures.rescue.givenAt")
                        }
                        Picker(selection: $draft.effect) {
                            ForEach(SeizureRescueEffect.choices, id: \.self) { Text($0.label).tag($0) }
                        } label: {
                            HLRowTitle("seizures.rescue.effect")
                        }
                    } footer: {
                        Text("seizures.rescue.intakeHint")
                    }
                    if let saveError {
                        Section { HLFormErrorText(saveError) }
                    }
                }
                .hlFormRowSurface()
            }
            .hlPageMargins()
        }
    }

    private func save() async -> Bool {
        saveError = nil
        if await store.addRescueDose(eventId: event.id, draft.body, idempotencyKey: idempotencyKey) != nil { return true }
        saveError = store.lastError ?? String(localized: "seizures.saveError")
        return false
    }
}

/// The rescue dose form's state. Pure.
struct SeizureRescueDoseDraft: Equatable {
    let planMedicationId: String?
    let planMedicationName: String
    var medicationName: String
    var amount: String
    var unit: String
    var route: SeizureRescueRoute?
    var givenAt: Date
    var effect: SeizureRescueEffect

    init(plan: SeizureTypeDTO?, givenAt: Date) {
        planMedicationId = plan?.rescueMedicationId
        planMedicationName = plan?.rescueMedicationName ?? ""
        medicationName = plan?.rescueMedicationName ?? ""
        amount = plan?.rescueDoseAmount.map { HLNumberFormat.decimal($0, maximumFractionDigits: 2) } ?? ""
        unit = plan?.rescueDoseUnit ?? ""
        route = plan?.rescueRoute
        self.givenAt = givenAt
        effect = .unknown
    }

    /// Still the plan's drug: the dose goes onto that medication.
    var usesPlan: Bool {
        planMedicationId != nil && medicationName.trimmingCharacters(in: .whitespaces) == planMedicationName
    }

    var parsedAmount: Double? {
        LocaleDecimalParser.parse(amount)
    }

    var isValid: Bool {
        let named = !medicationName.trimmingCharacters(in: .whitespaces).isEmpty
        let amountOK = amount.trimmingCharacters(in: .whitespaces).isEmpty || (parsedAmount ?? 0) > 0
        return (named || usesPlan) && amountOK
    }

    var body: SeizureRescueDoseCreate {
        let name = medicationName.trimmingCharacters(in: .whitespaces)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespaces)
        return SeizureRescueDoseCreate(
            medicationId: usesPlan ? planMedicationId : nil,
            medicationName: usesPlan ? nil : name,
            doseAmount: parsedAmount,
            doseUnit: trimmedUnit.isEmpty ? nil : trimmedUnit,
            route: route,
            givenAt: SeizureDateFormat.wire(givenAt),
            effect: effect
        )
    }
}
