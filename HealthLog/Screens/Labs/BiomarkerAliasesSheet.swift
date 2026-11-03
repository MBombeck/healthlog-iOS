import SwiftUI

/// #130 (server v1.43) — the other spellings of one marker.
///
/// A lab report that writes "Hb A1c" instead of "HbA1c" lands on this marker
/// when the spelling is one of its aliases. The sheet edits the list and saves
/// it with `PUT /api/biomarkers/{id}` and `aliases`, which replaces the manual
/// and merge aliases. A spelling another marker already owns is refused with
/// its own sentence (`409 labs.biomarker.alias.taken`).
struct BiomarkerAliasesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: LabsStore
    let marker: BiomarkerDTO

    @State private var aliases: [String]
    @State private var draft = ""
    @State private var isSaving = false
    @State private var inlineError: String?

    init(store: LabsStore, marker: BiomarkerDTO) {
        self.store = store
        self.marker = marker
        _aliases = State(initialValue: marker.aliases)
    }

    var body: some View {
        NavigationStack {
            Form {
                // 1.4 B2-c — what this list does is its header, read before the
                // rows instead of after them.
                Section {
                    ForEach(aliases, id: \.self) { alias in
                        Text(verbatim: alias)
                    }
                    .onDelete { aliases.remove(atOffsets: $0) }
                    HStack {
                        TextField("labs.aliases.add.placeholder", text: $draft)
                            .submitLabel(.done)
                            .onSubmit(addDraft)
                            .accessibilityIdentifier("labs.aliases.field")
                        Button("labs.aliases.add", action: addDraft)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("labs.aliases.footer")
                }
                if let inlineError {
                    Section { HLFormErrorText(inlineError) }
                }
            }
            .navigationTitle(Text(verbatim: marker.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("labs.action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("labs.action.save") { Task { await save() } }
                        .disabled(isSaving || LabsStore.cleanAliases(aliases) == marker.aliases)
                }
            }
        }
    }

    private func addDraft() {
        let next = LabsStore.cleanAliases(aliases + [draft])
        guard next.count > aliases.count else {
            draft = ""
            return
        }
        aliases = next
        draft = ""
    }

    private func save() async {
        isSaving = true
        inlineError = nil
        defer { isSaving = false }
        if await store.setAliases(aliases, for: marker.id) {
            dismiss()
        } else {
            inlineError = store.lastError ?? String(localized: "labs.save.failed")
        }
    }
}
