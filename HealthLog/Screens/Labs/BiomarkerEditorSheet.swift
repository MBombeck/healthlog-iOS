import SwiftUI

/// Create or edit a catalog biomarker. Name + unit are required; lower/upper
/// bound, panel, and a context note are optional. A duplicate name surfaces the
/// server `409` as an inline ``HLFormErrorText`` (`biomarker.duplicate.error`).
struct BiomarkerEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: LabsStore
    /// `nil` → create; non-nil → edit that marker.
    let existing: BiomarkerDTO?

    @State private var name: String
    @State private var unit: String
    @State private var lowerBoundText: String
    @State private var upperBoundText: String
    @State private var panel: String
    @State private var context: String
    /// Build 3 / item 3.2 — the server `hidden` flag (v1.22). Hiding is the
    /// non-destructive alternative to deleting: the marker leaves the active
    /// catalog + every entry picker, but its readings and its canonical
    /// unit/range definition survive. Only offered when editing — a marker you
    /// are creating right now has no reason to start hidden.
    @State private var hidden: Bool
    /// Build 3 / item 3.2 — the currently picked seed slug (create form only).
    /// Purely a picker binding; the seed's values are copied into the editable
    /// fields on selection and the slug is never sent to the server.
    @State private var selectedSeedSlug: String?
    @State private var isSaving = false
    @State private var inlineError: String?
    /// FORM-1 (Audit v0162) — drives the discard-confirmation dialog.
    @State private var showDiscardConfirm = false
    /// FORM-2 (Audit v0162) — initial-focus + submit-chain across the text fields.
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, unit, panel, lowerBound, upperBound, context
    }

    init(store: LabsStore, existing: BiomarkerDTO?) {
        self.store = store
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _unit = State(initialValue: existing?.unit ?? "")
        _lowerBoundText = State(initialValue: existing?.lowerBound.map { $0.formatted() } ?? "")
        _upperBoundText = State(initialValue: existing?.upperBound.map { $0.formatted() } ?? "")
        _panel = State(initialValue: existing?.panel ?? "")
        _context = State(initialValue: existing?.context ?? "")
        _hidden = State(initialValue: existing?.hidden ?? false)
    }

    private var isEditing: Bool {
        existing != nil
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !unit.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// FORM-1 — any field diverges from the initial (empty on create, prefilled
    /// on edit) value.
    private var isDirty: Bool {
        name != (existing?.name ?? "")
            || unit != (existing?.unit ?? "")
            || lowerBoundText != (existing?.lowerBound.map { $0.formatted() } ?? "")
            || upperBoundText != (existing?.upperBound.map { $0.formatted() } ?? "")
            || panel != (existing?.panel ?? "")
            || context != (existing?.context ?? "")
            || hidden != (existing?.hidden ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Build 3 / item 3.2 — seed catalog. CREATE only: on edit the
                // marker already has an identity and overwriting it from a seed
                // would silently re-point the operator's history.
                if !isEditing {
                    seedSection
                }
                Section("biomarker.editor.identity") {
                    TextField("biomarker.editor.name", text: $name)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .unit }
                    TextField("biomarker.editor.unit", text: $unit)
                        .focused($focusedField, equals: .unit)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .panel }
                    TextField("biomarker.editor.panel", text: $panel)
                        .focused($focusedField, equals: .panel)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .lowerBound }
                }
                Section("biomarker.editor.bounds") {
                    TextField("labs.add.referenceLow", text: $lowerBoundText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .lowerBound)
                    TextField("labs.add.referenceHigh", text: $upperBoundText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .upperBound)
                }
                Section("biomarker.editor.context") {
                    TextField("biomarker.editor.contextField", text: $context, axis: .vertical)
                        .lineLimit(2 ... 5)
                        .focused($focusedField, equals: .context)
                }
                // Build 3 / item 3.2 — hide instead of delete. Only on edit.
                if isEditing {
                    Section {
                        Toggle("biomarker.editor.hidden", isOn: $hidden)
                            .accessibilityIdentifier("biomarker.editor.hidden")
                    } footer: {
                        Text("biomarker.editor.hidden.footer")
                    }
                }
                if let inlineError {
                    Section { HLFormErrorText(inlineError) }
                }
            }
            .navigationTitle(Text(isEditing ? "biomarker.edit.title" : "biomarker.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("labs.action.cancel") {
                        if isDirty { showDiscardConfirm = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("labs.action.save") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            // FORM-2 — seed focus onto the name field once the sheet settles.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = .name
            }
        }
        // FORM-1 — guard against a swipe-down discarding unsaved edits.
        .hlDiscardGuard(isDirty: isDirty, isSaving: isSaving, isPresented: $showDiscardConfirm) {
            dismiss()
        }
    }

    /// Build 3 / item 3.2 — the panel-grouped seed picker. Mirrors
    /// `biomarker-form.tsx:167-202`: one section, grouped by panel, that
    /// pre-fills the definition below.
    private var seedSection: some View {
        Section {
            Picker(selection: $selectedSeedSlug) {
                Text("biomarker.editor.seed.none").tag(String?.none)
                // Named `panelKey` rather than `panel` so it never shadows the
                // editor's own `panel` text field.
                ForEach(BiomarkerSeedPanel.allCases, id: \.self) { panelKey in
                    let seeds = BiomarkerSeedCatalog.seeds(in: panelKey)
                    if !seeds.isEmpty {
                        Section(panelKey.displayName) {
                            ForEach(seeds) { seed in
                                Text(seed.displayName).tag(String?.some(seed.slug))
                            }
                        }
                    }
                }
            } label: {
                Text("biomarker.editor.seed.label")
            }
            .accessibilityIdentifier("biomarker.editor.seed")
            .onChange(of: selectedSeedSlug) { _, newValue in
                guard let newValue, let seed = BiomarkerSeedCatalog.seed(slug: newValue) else { return }
                applySeed(seed)
            }
        } header: {
            Text("biomarker.editor.seed.section")
        } footer: {
            Text("biomarker.editor.seed.footer")
        }
    }

    /// Pre-fill the definition fields from a seed. **Overwrites** whatever is
    /// there — same as the web, and the only sane reading of "I picked LDL".
    /// The operator can still edit every field afterwards; nothing is written
    /// to the server until Save.
    private func applySeed(_ seed: BiomarkerSeed) {
        name = seed.displayName
        unit = seed.unit
        lowerBoundText = seed.lowerBound.map { $0.formatted() } ?? ""
        upperBoundText = seed.upperBound.map { $0.formatted() } ?? ""
        panel = seed.panel.displayName
        inlineError = nil
    }

    private func save() async {
        isSaving = true
        inlineError = nil
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespaces)
        let trimmedPanel = panel.trimmingCharacters(in: .whitespaces)
        let trimmedContext = context.trimmingCharacters(in: .whitespaces)
        let lower = LocaleDecimalParser.parse(lowerBoundText)
        let upper = LocaleDecimalParser.parse(upperBoundText)

        let ok: Bool = if let existing {
            // Build 3 / item 3.2 — bounds / context / panel are CLEARABLE. An
            // emptied field now sends an explicit `null` (server: "clear the
            // column") instead of omitting the key, which used to leave the old
            // value in place so the cleared bound reappeared on the next sync.
            // An unparseable bound stays `.unchanged` — a typo must never
            // destroy a stored reference range.
            await store.updateBiomarker(
                id: existing.id,
                BiomarkerPatch(
                    name: trimmedName,
                    unit: trimmedUnit,
                    lowerBound: .fromEditor(lowerBoundText, parse: { LocaleDecimalParser.parse($0) }),
                    upperBound: .fromEditor(upperBoundText, parse: { LocaleDecimalParser.parse($0) }),
                    context: .fromEditor(trimmedContext),
                    panel: .fromEditor(trimmedPanel),
                    hidden: hidden
                )
            )
        } else {
            await store.createBiomarker(
                BiomarkerCreate(
                    name: trimmedName,
                    unit: trimmedUnit,
                    lowerBound: lower,
                    upperBound: upper,
                    context: trimmedContext.isEmpty ? nil : trimmedContext,
                    panel: trimmedPanel.isEmpty ? nil : trimmedPanel
                )
            )
        }

        if ok {
            dismiss()
        } else if store.lastErrorWasDuplicateName {
            inlineError = String(localized: "biomarker.duplicate.error")
        } else {
            inlineError = store.lastError ?? String(localized: "labs.save.failed")
        }
    }
}
