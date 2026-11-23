import SwiftUI

/// The editor for one nutrient's personal target (#182 A2, server v1.48):
/// an amount to reach or one to stay under, in the nutrient's own unit.
///
/// Laid out like the metric target editor: one form, the choice as check-mark
/// rows, the value with its unit, the bar's check mark saves. A target that
/// exists can be removed from the form. The server checks the value against
/// the nutrient's plausibility range and the editor shows its refusal; the
/// app keeps no range table of its own.
struct NutrientTargetEditorSheet: View {
    let code: NutrientCode
    /// The nutrient's wire unit (`mg`, `ug`, `g`, `kcal`, `ml`).
    let wireUnit: String
    let store: NutrientStore

    @Environment(\.dismiss) private var dismiss
    @State private var direction: NutrientTargetDirection = .target
    @State private var valueText = ""
    @State private var seeded: Draft?
    /// The last save from this sheet was refused; its message shows under
    /// the value until the next try.
    @State private var saveFailed = false
    @FocusState private var valueFocused: Bool

    /// What the form holds, for the unsaved-changes question.
    struct Draft: Equatable {
        let direction: NutrientTargetDirection
        let valueText: String
    }

    private var existing: NutrientPersonalTarget? {
        store.personalTarget(for: code)
    }

    private var draft: Draft {
        Draft(direction: direction, valueText: valueText)
    }

    private var parsedTarget: NutrientPersonalTarget? {
        Self.target(direction: direction, valueText: valueText)
    }

    private var isSaving: Bool {
        store.savingTarget.contains(code.rawValue)
    }

    var body: some View {
        HLSheetScaffold(
            "nutrients.target.editor.title",
            action: .save(isEnabled: parsedTarget != nil && draft != seeded) { await save() },
            isDirty: seeded != nil && draft != seeded,
            isBusy: isSaving
        ) {
            Form {
                Group {
                    Section {
                        choiceRow(.target, title: "nutrients.target.direction.target", detail: "nutrients.target.direction.target.detail")
                        choiceRow(.limit, title: "nutrients.target.direction.limit", detail: "nutrients.target.direction.limit.detail")
                    } header: {
                        Text(NutrientDisplay.name(for: code))
                            .textCase(nil)
                    }
                    Section {
                        HStack(spacing: HLSpace.sm) {
                            TextField("nutrients.target.editor.value", text: $valueText)
                                .keyboardType(.decimalPad)
                                .monospacedDigit()
                                .focused($valueFocused)
                                .accessibilityIdentifier("nutrients.target.editor.value")
                            Text(verbatim: NutrientDisplay.unitGlyph(wireUnit))
                                .hlText(.rowSubtitle)
                        }
                    } footer: {
                        if saveFailed, let lastError = store.lastError, !isSaving {
                            HLFormErrorText(lastError)
                        }
                    }
                    if existing != nil {
                        Section {
                            HLDeleteButton(
                                "nutrients.target.editor.remove",
                                form: .row,
                                action: .confirmed(
                                    title: "nutrients.target.editor.remove.confirm",
                                    word: "nutrients.target.editor.remove"
                                ) {
                                    let removed = await store.setTarget(nil, for: code)
                                    saveFailed = !removed
                                    if removed { dismiss() }
                                }
                            )
                            .disabled(isSaving)
                        }
                    }
                }
                .hlFormRowSurface()
            }
            .hlPageMargins()
            .task {
                seed()
                try? await Task.sleep(for: HLSheet.focusDelay)
                valueFocused = true
            }
        }
    }

    private func choiceRow(
        _ value: NutrientTargetDirection,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HLChoiceRow(title, detail: detail, isSelected: direction == value) {
            direction = value
        }
        .accessibilityIdentifier("nutrients.target.direction.\(value.rawValue)")
    }

    private func seed() {
        guard seeded == nil else { return }
        if let existing {
            direction = existing.direction
            valueText = HLValueFormat.number(existing.value, fractionDigits: 0 ... 2)
        }
        seeded = draft
    }

    private func save() async -> Bool {
        guard let parsedTarget else { return false }
        let saved = await store.setTarget(parsedTarget, for: code)
        saveFailed = !saved
        return saved
    }

    /// The target the form describes, or `nil` for an empty, unreadable or
    /// non-positive value. The upper bound is the server's to check.
    nonisolated static func target(direction: NutrientTargetDirection, valueText: String) -> NutrientPersonalTarget? {
        guard let value = LocaleDecimalParser.parse(valueText), value.isFinite, value > 0 else { return nil }
        return NutrientPersonalTarget(value: value, direction: direction)
    }
}
