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
    let onDismiss: () -> Void

    @State private var label = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("cycle.custom.label.placeholder", text: $label)
                        .textInputAutocapitalization(.sentences)
                        .onChange(of: label) { _, value in
                            if value.count > 40 { label = String(value.prefix(40)) }
                        }
                } footer: {
                    Text("cycle.custom.label.footer")
                }
                if let error { Section { HLFormErrorText(error) } }
            }
            .disabled(isSaving)
            .navigationTitle(Text(
                target.symptom == nil
                    ? LocalizedStringKey("cycle.custom.create.title")
                    : LocalizedStringKey("cycle.custom.edit.title")
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { label = target.symptom?.displayLabel ?? "" }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        if let symptom = target.symptom {
            if await store.updateCustomSymptom(key: symptom.key, label: label) {
                onSaved(symptom.key)
                return
            }
        } else if let created = await store.createCustomSymptom(label: label) {
            onSaved(created.key)
            return
        }
        error = store.customSymptomsError ?? String(localized: "cycle.custom.error.generic")
    }
}
