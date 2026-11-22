import SwiftUI

/// #130 (server v1.43) — the other spellings of one marker.
///
/// A lab report that writes "Hb A1c" instead of "HbA1c" lands on this marker
/// when the spelling is one of its aliases. The sheet edits the list and saves
/// it with `PUT /api/biomarkers/{id}` and `aliases`, which replaces the manual
/// and merge aliases. A spelling another marker already owns is refused with
/// its own sentence (`409 labs.biomarker.alias.taken`).
struct BiomarkerAliasesSheet: View {
    let store: LabsStore
    let marker: BiomarkerDTO

    @State private var aliases: [String]
    @State private var draft = ""
    @State private var inlineError: String?

    init(store: LabsStore, marker: BiomarkerDTO) {
        self.store = store
        self.marker = marker
        _aliases = State(initialValue: marker.aliases)
    }

    var body: some View {
        HLSheetScaffold(
            verbatim: marker.name,
            action: .save(isEnabled: LabsStore.cleanAliases(aliases) != marker.aliases) { await save() },
            isDirty: LabsStore.cleanAliases(aliases) != marker.aliases
        ) {
            Form {
                // What this list does is its header, read before the
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
                        HLIconButton(systemImage: "plus", label: "labs.aliases.add", size: .inline, action: addDraft)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("labs.aliases.footer")
                }
                .hlFormRowSurface()
                if let inlineError {
                    Section { HLFormErrorText(inlineError) }
                        .hlFormRowSurface()
                }
            }
            .hlPageMargins()
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

    /// Returns `true` when the sheet may close.
    private func save() async -> Bool {
        inlineError = nil
        if await store.setAliases(aliases, for: marker.id) {
            return true
        }
        inlineError = store.lastError ?? String(localized: "labs.save.failed")
        return false
    }
}
