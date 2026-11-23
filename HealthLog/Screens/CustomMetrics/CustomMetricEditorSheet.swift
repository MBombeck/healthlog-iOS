import SwiftUI

/// Define or edit a custom metric. Name + unit are required; the target window,
/// display decimals and description are optional.
///
/// Field set mirrors the server schema exactly (`createCustomMetricSchema`) —
/// which is also what the web form offers (`custom-metric-form.tsx`). A
/// duplicate name surfaces the server `409` as an inline ``HLFormErrorText``,
/// and an inverted target window is caught client-side before the round-trip.
struct CustomMetricEditorSheet: View {
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
    /// Initial focus + submit-chain across the text fields.
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

    /// Any field diverges from the initial value.
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
        HLSheetScaffold(
            isEditing ? "customMetric.edit.title" : "customMetric.add.title",
            action: isEditing ? .save(isEnabled: canSave) { await save() } : .add(isEnabled: canSave) { await save() },
            isDirty: isDirty
        ) {
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
                    HLSectionHeader("customMetric.editor.identity")
                }
                .hlFormRowSurface()

                Section {
                    TextField("customMetric.editor.targetLow", text: $targetLowText)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .targetLow)
                    TextField("customMetric.editor.targetHigh", text: $targetHighText)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .targetHigh)
                } header: {
                    // No footer: the fields are optional by their
                    // placeholders, and the band shows itself on the chart.
                    HLSectionHeader("customMetric.editor.target")
                }
                .hlFormRowSurface()

                Section {
                    // "leave empty for automatic" is the field's
                    // placeholder instead of a footer.
                    LabeledContent {
                        TextField("customMetric.editor.decimals.placeholder", text: $decimalsText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .decimals)
                    } label: {
                        HLRowTitle("customMetric.editor.decimals")
                    }
                    TextField("customMetric.editor.description", text: $descriptionText, axis: .vertical)
                        .lineLimit(2 ... 5)
                        .focused($focusedField, equals: .description)
                } header: {
                    HLSectionHeader("customMetric.editor.display")
                }
                .hlFormRowSurface()

                // CU-35 (3) — its own section, because it is not a display
                // option like the two above it: it decides whether these values
                // get analysed alongside the rest of the health record. The
                // footer states what switching it on actually permits, and that
                // it can be taken back — a consent nobody could describe is not
                // one that was given.
                Section {
                    Toggle(isOn: $correlationEnabled) {
                        HLRowTitle("customMetric.editor.correlation")
                    }
                    .accessibilityIdentifier("customMetric.editor.correlation")
                } header: {
                    HLSectionHeader("customMetric.editor.analysis")
                } footer: {
                    Text("customMetric.editor.correlation.hint")
                }
                .hlFormRowSurface()

                if let inlineError {
                    Section { HLFormErrorText(inlineError) }
                        .hlFormRowSurface()
                }
            }
            .hlPageMargins()
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = .name
            }
        }
    }

    private func save() async -> Bool {
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

        // A field that holds text but no number must not save as "no target"
        // or "automatic": that would clear a stored value without a word.
        if let unreadable = Self.unreadableInput(
            targetLowText: targetLowText, targetHighText: targetHighText, decimalsText: decimalsText
        ) {
            inlineError = String(localized: unreadable)
            return false
        }

        if let failure = CustomMetricValidation.validate(
            name: trimmedName, unit: trimmedUnit,
            targetLow: low, targetHigh: high,
            decimals: decimals, description: description
        ) {
            inlineError = Self.message(for: failure)
            return false
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
            return true
        } else if store.lastErrorWasDuplicateName {
            inlineError = String(localized: "customMetric.duplicate.error")
        } else {
            inlineError = store.lastError ?? String(localized: "customMetric.save.failed")
        }
        return false
    }

    /// The message for a filled field that does not read as a number, `nil`
    /// when every filled field does. Blank fields are fine: they mean "none".
    nonisolated static func unreadableInput(
        targetLowText: String,
        targetHighText: String,
        decimalsText: String,
        locale: Locale = .current
    ) -> LocalizedStringResource? {
        func unreadable(_ text: String, _ parse: (String) -> Bool) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !parse(trimmed)
        }
        if unreadable(targetLowText, { LocaleDecimalParser.parse($0, locale: locale) != nil })
            || unreadable(targetHighText, { LocaleDecimalParser.parse($0, locale: locale) != nil })
        {
            return "customMetric.validation.targetNotNumber"
        }
        if unreadable(decimalsText, { Int($0) != nil }) {
            return "customMetric.validation.decimals"
        }
        return nil
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
