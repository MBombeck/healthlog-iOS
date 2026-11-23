import SwiftUI

enum CycleCustomEditorTarget: Identifiable {
    case create
    case edit(CycleCustomSymptomDTO)

    var id: String {
        switch self {
        case .create: "create"
        case let .edit(symptom): symptom.key
        }
    }

    var symptom: CycleCustomSymptomDTO? {
        if case let .edit(symptom) = self { return symptom }
        return nil
    }
}

struct CycleCustomSymptomEditor: View {
    let target: CycleCustomEditorTarget
    let store: CycleStore
    let onSaved: (String) -> Void

    @State private var label = ""
    @State private var error: String?

    var body: some View {
        HLSheetScaffold(
            target.symptom == nil ? "cycle.custom.create.title" : "cycle.custom.edit.title",
            action: .save(isEnabled: !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                await save()
            },
            isDirty: label != (target.symptom?.displayLabel ?? "")
        ) {
            Form {
                Section {
                    TextField("cycle.custom.label.placeholder", text: $label)
                        .textInputAutocapitalization(.sentences)
                        .onChange(of: label) { _, value in
                            if value.count > 40 { label = String(value.prefix(40)) }
                        }
                }
                .hlFormRowSurface()
                // The field stops at 40 characters by itself; no
                // footer states the rule.
                if let error {
                    Section { HLFormErrorText(error) }
                        .hlFormRowSurface()
                }
            }
            .hlPageMargins()
            .onAppear { label = target.symptom?.displayLabel ?? "" }
        }
    }

    /// `true` when the sheet may close.
    private func save() async -> Bool {
        error = nil
        if let symptom = target.symptom {
            if await store.updateCustomSymptom(key: symptom.key, label: label) {
                onSaved(symptom.key)
                return true
            }
        } else if let created = await store.createCustomSymptom(label: label) {
            onSaved(created.key)
            return true
        }
        error = store.customSymptomsError ?? String(localized: "cycle.custom.error.generic")
        return false
    }
}
