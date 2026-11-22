import SwiftUI

/// Add / edit a family-history entry (v1.25 `W-RECORDS`; FHIR
/// `FamilyMemberHistory`). One `Form` for both modes. `relationship` + `condition`
/// are required; `ageAtOnset` (0–120) + `note` are optional and tri-state-clearable
/// on edit.
struct FamilyHistoryEditorSheet: View {
    let store: FamilyHistoryStore
    let record: FamilyHistoryEntryDTO?

    @State private var relationship: FamilyRelationship
    @State private var condition: String
    @State private var hasAgeAtOnset: Bool
    @State private var ageAtOnset: Int
    @State private var note: String
    @State private var isSaving = false
    @State private var saveError: String?
    /// Initial-focus + submit-chain across the text fields.
    @FocusState private var focusedField: Field?

    /// Server bound for `ageAtOnset` (INV-B caveat). The stepper clamps to it.
    private static let ageRange: ClosedRange<Int> = 0 ... 120

    private enum Field: Hashable {
        case condition, note
    }

    init(store: FamilyHistoryStore, record: FamilyHistoryEntryDTO? = nil) {
        self.store = store
        self.record = record
        _relationship = State(initialValue: record?.relationship ?? .mother)
        _condition = State(initialValue: record?.condition ?? "")
        _hasAgeAtOnset = State(initialValue: record?.ageAtOnset != nil)
        _ageAtOnset = State(initialValue: record?.ageAtOnset ?? 50)
        _note = State(initialValue: record?.note ?? "")
    }

    private var isEditing: Bool {
        record != nil
    }

    private var canSave: Bool {
        !condition.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    /// Any field diverges from the initial (create-default or prefilled)
    /// value.
    private var isDirty: Bool {
        relationship != (record?.relationship ?? .mother)
            || condition != (record?.condition ?? "")
            || hasAgeAtOnset != (record?.ageAtOnset != nil)
            || (hasAgeAtOnset && ageAtOnset != (record?.ageAtOnset ?? 50))
            || note != (record?.note ?? "")
    }

    var body: some View {
        HLSheetScaffold(
            isEditing ? "familyHistory.edit.title" : "familyHistory.add.sheetTitle",
            action: isEditing ? .save(isEnabled: canSave) { await save() } : .add(isEnabled: canSave) { await save() },
            isDirty: isDirty
        ) {
            Form {
                Section {
                    Picker(selection: $relationship) {
                        ForEach(FamilyRelationship.allCases) { r in
                            Text(r.localizedLabel).tag(r)
                        }
                    } label: {
                        HLRowTitle("familyHistory.field.relationship")
                    }
                    TextField("familyHistory.field.condition", text: $condition)
                        .focused($focusedField, equals: .condition)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .note }
                } header: {
                    HLSectionHeader("familyHistory.add.section.about")
                }
                .hlFormRowSurface()
                Section {
                    Toggle(isOn: $hasAgeAtOnset.animation()) {
                        HLRowTitle("familyHistory.field.ageAtOnsetToggle")
                    }
                    if hasAgeAtOnset {
                        Stepper(value: $ageAtOnset, in: Self.ageRange) {
                            HStack {
                                HLRowTitle("familyHistory.field.ageAtOnset")
                                Spacer()
                                Text(verbatim: "\(ageAtOnset)")
                                    .foregroundStyle(HLText.secondary)
                            }
                        }
                        .accessibilityIdentifier("familyHistory.field.ageAtOnsetStepper")
                    }
                } header: {
                    HLSectionHeader("familyHistory.add.section.onset")
                }
                .hlFormRowSurface()
                Section {
                    TextField("familyHistory.field.note", text: $note, axis: .vertical)
                        .lineLimit(2 ... 5)
                        .focused($focusedField, equals: .note)
                } header: {
                    HLSectionHeader("familyHistory.add.section.note")
                }
                .hlFormRowSurface()
                if let saveError {
                    Section { HLFormErrorText(saveError) }
                        .hlFormRowSurface()
                }
            }
            .hlPageMargins()
            // Seed focus onto the condition field once the sheet settles.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = .condition
            }
        }
    }

    /// `true` when the record went out and the sheet may close.
    private func save() async -> Bool {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let succeeded = isEditing ? await saveEdit() : await saveCreate()
        if !succeeded {
            saveError = store.lastError ?? String(localized: "familyHistory.save.failed")
        }
        return succeeded
    }

    private func saveCreate() async -> Bool {
        let body = FamilyHistoryCreate(
            relationship: relationship,
            condition: condition.trimmingCharacters(in: .whitespaces),
            ageAtOnset: hasAgeAtOnset ? ageAtOnset : nil,
            note: cleaned(note)
        )
        return await store.create(body) != nil
    }

    private func saveEdit() async -> Bool {
        guard let record else { return false }
        let trimmedCondition = condition.trimmingCharacters(in: .whitespaces)
        let newAge: Int? = hasAgeAtOnset ? ageAtOnset : nil
        let patch = FamilyHistoryPatch(
            relationship: relationship == record.relationship ? .unchanged : .set(relationship),
            condition: trimmedCondition == record.condition ? .unchanged : .set(trimmedCondition),
            ageAtOnset: triState(new: newAge, old: record.ageAtOnset),
            note: triState(new: cleaned(note), old: record.note)
        )
        return await store.update(id: record.id, patch)
    }

    private func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
