import SwiftUI

/// Define or edit a custom metric. Name + unit are required; the target window,
/// display decimals and description are optional.
///
/// Field set mirrors the server schema exactly (`createCustomMetricSchema`) —
/// which is also what the web form offers (`custom-metric-form.tsx`). A
/// duplicate name surfaces the server `409` as an inline ``HLFormErrorText``,
/// and an inverted target window is caught client-side before the round-trip.
struct CustomMetricEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: CustomMetricsStore
    /// `nil` → define a new metric; non-nil → edit that definition.
    let existing: CustomMetricDTO?

    @State private var name: String
    @State private var unit: String
    @State private var targetLowText: String
    @State private var targetHighText: String
    @State private var decimalsText: String
    @State private var descriptionText: String
    /// CU-35 (3) — the correlation-analysis consent. Defaults OFF for a new
    /// metric, matching the server (`z.boolean().default(false)`).
    @State private var correlationEnabled: Bool
    @State private var isSaving = false
    @State private var inlineError: String?
    /// FORM-1 — drives the discard-confirmation dialog.
    @State private var showDiscardConfirm = false
    /// FORM-2 — initial focus + submit-chain across the text fields.
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, unit, targetLow, targetHigh, decimals, description
    }

    init(store: CustomMetricsStore, existing: CustomMetricDTO?) {
        self.store = store
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _unit = State(initialValue: existing?.unit ?? "")
        _targetLowText = State(initialValue: Self.initialText(existing?.targetLow))
        _targetHighText = State(initialValue: Self.initialText(existing?.targetHigh))
        _decimalsText = State(initialValue: existing?.decimals.map(String.init) ?? "")
        _descriptionText = State(initialValue: existing?.description ?? "")
        _correlationEnabled = State(initialValue: existing?.correlationEnabled ?? false)
    }

    /// Seed a bound text field. Uses the same `.formatted()` rendering the
    /// biomarker editor uses so an untouched field round-trips to the identical
    /// string and `isDirty` stays false.
    private static func initialText(_ value: Double?) -> String {
        value.map { $0.formatted() } ?? ""
    }

    private var isEditing: Bool {
        existing != nil
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !unit.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// FORM-1 — any field diverges from the initial value.
    private var isDirty: Bool {
        name != (existing?.name ?? "")
            || unit != (existing?.unit ?? "")
            || targetLowText != Self.initialText(existing?.targetLow)
            || targetHighText != Self.initialText(existing?.targetHigh)
            || decimalsText != (existing?.decimals.map(String.init) ?? "")
            || descriptionText != (existing?.description ?? "")
            || correlationEnabled != (existing?.correlationEnabled ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("customMetric.editor.name", text: $name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .unit }
                    TextField("customMetric.editor.unit", text: $unit)
                        .focused($focusedField, equals: .unit)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .targetLow }
                } header: {
                    Text("customMetric.editor.identity")
                } footer: {
                    Text("customMetric.editor.identity.hint")
                }

                Section {
                    TextField("customMetric.editor.targetLow", text: $targetLowText)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .targetLow)
                    TextField("customMetric.editor.targetHigh", text: $targetHighText)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .targetHigh)
                } header: {
                    Text("customMetric.editor.target")
                } footer: {
                    Text("customMetric.editor.target.hint")
                }

                Section {
                    TextField("customMetric.editor.decimals", text: $decimalsText)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .decimals)
                    TextField("customMetric.editor.description", text: $descriptionText, axis: .vertical)
                        .lineLimit(2 ... 5)
                        .focused($focusedField, equals: .description)
                } header: {
                    Text("customMetric.editor.display")
                } footer: {
                    Text("customMetric.editor.decimals.hint")
                }

                // CU-35 (3) — its own section, because it is not a display
                // option like the two above it: it decides whether these values
                // get analysed alongside the rest of the health record. The
                // footer states what switching it on actually permits, and that
                // it can be taken back — a consent nobody could describe is not
                // one that was given.
                Section {
                    Toggle("customMetric.editor.correlation", isOn: $correlationEnabled)
                        .accessibilityIdentifier("customMetric.editor.correlation")
                } header: {
                    Text("customMetric.editor.analysis")
                } footer: {
                    Text("customMetric.editor.correlation.hint")
                }

                if let inlineError {
                    Section { HLFormErrorText(inlineError) }
                }
            }
            .navigationTitle(Text(isEditing ? "customMetric.edit.title" : "customMetric.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("customMetric.action.cancel") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("customMetric.action.save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = .name
            }
        }
        .hlDiscardGuard(isDirty: isDirty, isSaving: isSaving, isPresented: $showDiscardConfirm) {
            dismiss()
        }
    }

    private func save() async {
        isSaving = true
        inlineError = nil
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespaces)
        let trimmedDescription = descriptionText.trimmingCharacters(in: .whitespaces)
        let low = LocaleDecimalParser.parse(targetLowText)
        let high = LocaleDecimalParser.parse(targetHighText)
        // `decimals` is a plain integer count, not a locale-formatted decimal —
        // parse it as `Int`, so "2,5" is rejected rather than silently truncated.
        let decimals = Int(decimalsText.trimmingCharacters(in: .whitespaces))
        let description: String? = trimmedDescription.isEmpty ? nil : trimmedDescription

        if let failure = CustomMetricValidation.validate(
            name: trimmedName, unit: trimmedUnit,
            targetLow: low, targetHigh: high,
            decimals: decimals, description: description
        ) {
            inlineError = Self.message(for: failure)
            return
        }

        let ok: Bool = if let existing {
            // A full-surface edit: an emptied optional field is a genuine CLEAR,
            // not "leave it alone" — the sheet always shows every field, so the
            // user's blank IS the intent. `fullEdit` maps `nil` → explicit null.
            await store.updateMetric(
                id: existing.id,
                CustomMetricPatch.fullEdit(
                    name: trimmedName, unit: trimmedUnit,
                    targetLow: low, targetHigh: high,
                    decimals: decimals, description: description,
                    correlationEnabled: correlationEnabled
                )
            )
        } else {
            await store.createMetric(
                CustomMetricCreate(
                    name: trimmedName, unit: trimmedUnit,
                    targetLow: low, targetHigh: high,
                    decimals: decimals, description: description,
                    correlationEnabled: correlationEnabled
                )
            )
        }

        if ok {
            dismiss()
        } else if store.lastErrorWasDuplicateName {
            inlineError = String(localized: "customMetric.duplicate.error")
        } else {
            inlineError = store.lastError ?? String(localized: "customMetric.save.failed")
        }
    }

    /// Localized copy for a client-side validation failure.
    private static func message(for failure: CustomMetricValidation.Failure) -> String {
        switch failure {
        case .nameEmpty: String(localized: "customMetric.validation.nameEmpty")
        case .nameTooLong: String(localized: "customMetric.validation.nameTooLong")
        case .unitEmpty: String(localized: "customMetric.validation.unitEmpty")
        case .unitTooLong: String(localized: "customMetric.validation.unitTooLong")
        case .descriptionTooLong: String(localized: "customMetric.validation.descriptionTooLong")
        case .decimalsOutOfRange: String(localized: "customMetric.validation.decimals")
        case .invertedTargetBand: String(localized: "customMetric.validation.invertedBand")
        }
    }
}
