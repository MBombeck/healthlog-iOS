import SwiftUI

/// Add / edit an allergy record (v1.25 `W-RECORDS`). One `Form` sheet for both
/// modes: a `nil` ``record`` is an add (POST), a non-nil one is an edit (tri-state
/// PATCH — only changed fields, with an explicit clear for a field emptied back
/// to nothing). `substance` is required.
struct AllergyEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: AllergiesStore
    /// `nil` → add mode; non-nil → edit mode (prefilled).
    let record: AllergyDTO?

    @State private var substance: String
    @State private var category: AllergyCategory
    @State private var type: AllergyType
    /// `nil` = "no severity recorded" (the `allergy.field.severity.none` option).
    @State private var severity: AllergySeverity?
    @State private var status: AllergyStatus
    @State private var hasOnset: Bool
    @State private var onsetAt: Date
    @State private var reaction: String
    @State private var note: String
    @State private var isSaving = false
    @State private var saveError: String?
    /// FORM-1 (Audit v0162) — drives the discard-confirmation dialog.
    @State private var showDiscardConfirm = false
    /// FORM-2 (Audit v0162) — initial-focus + submit-chain across the text fields.
    @FocusState private var focusedField: Field?

    /// FORM-1 — onset baseline captured at init (the `@State` defaults are also
    /// seeded from these, so an untouched onset never reads as dirty).
    private let initialHasOnset: Bool
    private let initialOnsetAt: Date

    private enum Field: Hashable {
        case substance, reaction, note
    }

    init(store: AllergiesStore, record: AllergyDTO? = nil) {
        self.store = store
        self.record = record
        _substance = State(initialValue: record?.substance ?? "")
        _category = State(initialValue: record?.category ?? .other)
        _type = State(initialValue: record?.type ?? .allergy)
        _severity = State(initialValue: record?.severity)
        _status = State(initialValue: record?.status ?? .active)
        let parsedOnset = record?.onsetAt
            .flatMap { ISO8601DateFormatter.fractional.date(from: $0) ?? ISO8601DateFormatter.plain.date(from: $0) }
        _hasOnset = State(initialValue: parsedOnset != nil)
        _onsetAt = State(initialValue: parsedOnset ?? Date.now)
        initialHasOnset = parsedOnset != nil
        initialOnsetAt = parsedOnset ?? Date.now
        _reaction = State(initialValue: record?.reaction ?? "")
        _note = State(initialValue: record?.note ?? "")
    }

    private var isEditing: Bool {
        record != nil
    }

    private var canSave: Bool {
        !substance.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    /// FORM-1 — any field diverges from the initial (create-default or prefilled)
    /// value.
    private var isDirty: Bool {
        substance != (record?.substance ?? "")
            || category != (record?.category ?? .other)
            || type != (record?.type ?? .allergy)
            || severity != record?.severity
            || status != (record?.status ?? .active)
            || hasOnset != initialHasOnset
            || (hasOnset && onsetAt != initialOnsetAt)
            || reaction != (record?.reaction ?? "")
            || note != (record?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("allergies.add.section.about") {
                    TextField("allergies.field.substance", text: $substance)
                        .focused($focusedField, equals: .substance)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .reaction }
                    Picker("allergies.field.category", selection: $category) {
                        ForEach(AllergyCategory.allCases) { c in
                            Text(c.localizedLabel).tag(c)
                        }
                    }
                    Picker("allergies.field.type", selection: $type) {
                        ForEach(AllergyType.allCases) { t in
                            Text(t.localizedLabel).tag(t)
                        }
                    }
                    Picker("allergies.field.severity", selection: $severity) {
                        Text("allergies.field.severity.none").tag(AllergySeverity?.none)
                        ForEach(AllergySeverity.allCases) { s in
                            Text(s.localizedLabel).tag(AllergySeverity?.some(s))
                        }
                    }
                    Picker("allergies.field.status", selection: $status) {
                        ForEach(AllergyStatus.allCases) { s in
                            Text(s.localizedLabel).tag(s)
                        }
                    }
                }
                Section("allergies.add.section.onset") {
                    Toggle("allergies.field.onsetToggle", isOn: $hasOnset.animation())
                    if hasOnset {
                        DatePicker(
                            "allergies.field.onset",
                            selection: $onsetAt,
                            in: RecordsDateFormat.onsetRange,
                            displayedComponents: [.date]
                        )
                    }
                }
                Section("allergies.add.section.reaction") {
                    TextField("allergies.field.reaction", text: $reaction, axis: .vertical)
                        .lineLimit(1 ... 4)
                        .focused($focusedField, equals: .reaction)
                }
                Section("allergies.add.section.note") {
                    TextField("allergies.field.note", text: $note, axis: .vertical)
                        .lineLimit(2 ... 5)
                        .focused($focusedField, equals: .note)
                }
                if let saveError {
                    Section { HLFormErrorText(saveError) }
                }
            }
            .navigationTitle(Text(isEditing ? "allergies.edit.title" : "allergies.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("records.action.cancel") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("records.action.save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            // FORM-2 — seed focus onto the substance field once the sheet settles.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = .substance
            }
        }
        // FORM-1 — guard against a swipe-down discarding unsaved edits.
        .hlDiscardGuard(isDirty: isDirty, isSaving: isSaving, isPresented: $showDiscardConfirm) {
            dismiss()
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let succeeded = isEditing ? await saveEdit() : await saveCreate()
        if succeeded {
            dismiss()
        } else {
            saveError = store.lastError ?? String(localized: "allergies.save.failed")
        }
    }

    private func saveCreate() async -> Bool {
        let body = AllergyCreate(
            substance: substance.trimmingCharacters(in: .whitespaces),
            category: category,
            type: type,
            severity: severity,
            status: status,
            onsetAt: hasOnset ? RecordsDateFormat.onsetInstant(forDay: onsetAt) : nil,
            reaction: cleaned(reaction),
            note: cleaned(note)
        )
        return await store.create(body) != nil
    }

    private func saveEdit() async -> Bool {
        guard let record else { return false }
        let trimmedSubstance = substance.trimmingCharacters(in: .whitespaces)
        let patch = AllergyPatch(
            substance: trimmedSubstance == record.substance ? .unchanged : .set(trimmedSubstance),
            category: category == record.category ? .unchanged : .set(category),
            type: type == record.type ? .unchanged : .set(type),
            severity: triState(new: severity, old: record.severity),
            status: status == record.status ? .unchanged : .set(status),
            onsetAt: onsetTriState(record: record),
            reaction: triState(new: cleaned(reaction), old: record.reaction),
            note: triState(new: cleaned(note), old: record.note)
        )
        return await store.update(id: record.id, patch)
    }

    /// Resolve the onset field into a tri-state PATCH value: omit when unchanged,
    /// clear when the toggle is now off (and was set), set the (clamped) instant
    /// otherwise.
    private func onsetTriState(record: AllergyDTO) -> RecordPatchField<String> {
        if !hasOnset {
            return record.onsetAt == nil ? .unchanged : .clear
        }
        // M1 — only emit `.set` when the picked day actually differs from the
        // stored one (avoids re-writing an untouched onset on every edit), and
        // encode it day-anchored (noon UTC) so the stored date can't smear.
        if let existing = record.onsetAt,
           RecordsDateFormat.isSameOnsetDay(storedInstant: existing, asPickedDay: onsetAt)
        {
            return .unchanged
        }
        return .set(RecordsDateFormat.onsetInstant(forDay: onsetAt))
    }

    /// Trim free-text; an empty result becomes `nil` (no value).
    private func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Build a tri-state PATCH value for a nullable field: omit when unchanged, clear
/// when newly emptied (was set, now nil), set when changed to a value.
func triState<T: Equatable & Sendable>(new: T?, old: T?) -> RecordPatchField<T> {
    if new == old { return .unchanged }
    guard let new else { return .clear }
    return .set(new)
}
