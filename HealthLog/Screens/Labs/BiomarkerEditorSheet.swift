import SwiftUI

/// Create or edit a catalog biomarker. Name + unit are required; lower/upper
/// bound, panel, and a context note are optional. A duplicate name surfaces the
/// server `409` as an inline ``HLFormErrorText`` (`biomarker.duplicate.error`).
struct BiomarkerEditorSheet: View {
    let store: LabsStore
    /// `nil` → create; non-nil → edit that marker.
    let existing: BiomarkerDTO?

    @State private var name: String
    @State private var unit: String
    /// "No unit": the marker is a ratio or an index and is stored
    /// with the unity `"1"`. ``unit`` keeps what was typed for the way back.
    @State private var noUnit: Bool
    /// Whether the "No unit" switch is offered (server 1.46.6, or a marker
    /// that already has no unit).
    private let offersNoUnit: Bool
    /// `false` for a marker with an empty unit on a server that would refuse
    /// any unit change (``LabUnit/markerUnitEditable(stored:defaults:)``).
    private let unitEditable: Bool
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
    @State private var inlineError: String?
    /// Drives the discard-confirmation dialog.
    /// Initial-focus + submit-chain across the text fields.
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, unit, panel, lowerBound, upperBound, context
    }

    init(store: LabsStore, existing: BiomarkerDTO?) {
        self.store = store
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        // An empty unit (minted from a text result) opens like "No unit".
        let storedWithoutUnit = existing.map { LabUnit.isNoUnit($0.unit) } ?? false
        _unit = State(initialValue: storedWithoutUnit ? "" : existing?.unit ?? "")
        _noUnit = State(initialValue: storedWithoutUnit)
        offersNoUnit = storedWithoutUnit || LabUnit.offersNoUnit(current: existing?.unit)
        unitEditable = LabUnit.markerUnitEditable(stored: existing?.unit)
        _lowerBoundText = State(initialValue: existing?.lowerBound.map { $0.formatted() } ?? "")
        _upperBoundText = State(initialValue: existing?.upperBound.map { $0.formatted() } ?? "")
        // The stored panel can be a key ("coagulation"); the field shows its label.
        _panel = State(initialValue: LabPanelName.display(existing?.panel) ?? "")
        _context = State(initialValue: existing?.context ?? "")
        _hidden = State(initialValue: existing?.hidden ?? false)
    }

    private var isEditing: Bool {
        existing != nil
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && wireUnit != nil
    }

    /// The unit this form saves: the typed one, or the unity for "No unit".
    private var wireUnit: String? {
        LabUnit.wire(typed: unit, noUnit: noUnit)
    }

    /// Any field diverges from the initial (empty on create, prefilled
    /// on edit) value.
    private var isDirty: Bool {
        name != (existing?.name ?? "")
            || unitChanged
            || lowerBoundText != (existing?.lowerBound.map { $0.formatted() } ?? "")
            || upperBoundText != (existing?.upperBound.map { $0.formatted() } ?? "")
            || panel != (LabPanelName.display(existing?.panel) ?? "")
            || context != (existing?.context ?? "")
            || hidden != (existing?.hidden ?? false)
    }

    /// Whether the unit differs from the stored one in a way a save would send.
    private var unitChanged: Bool {
        guard let existing else { return wireUnit != nil }
        return LabUnit.markerPatchUnit(stored: existing.unit, edited: wireUnit) != nil
    }

    var body: some View {
        HLSheetScaffold(
            isEditing ? "biomarker.edit.title" : "biomarker.add.sheetTitle",
            action: isEditing
                ? .save(isEnabled: canSave) { await save() }
                : .add(isEnabled: canSave) { await save() },
            isDirty: isDirty
        ) {
            Form {
                Group {
                    // Build 3 / item 3.2 — seed catalog. CREATE only: on edit the
                    // marker already has an identity and overwriting it from a seed
                    // would silently re-point the operator's history.
                    if !isEditing {
                        seedSection
                    }
                    Section("biomarker.editor.identity") {
                        LabFormField("biomarker.editor.name") {
                            TextField("biomarker.editor.name", text: $name)
                                .focused($focusedField, equals: .name)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .unit }
                        }
                        // "No unit" hides the field instead of leaving an
                        // empty one that cannot be typed into.
                        if !noUnit {
                            LabFormField("biomarker.editor.unit") {
                                TextField("labs.unit.placeholder", text: LabUnit.fieldBinding(typed: $unit, noUnit: noUnit))
                                    .focused($focusedField, equals: .unit)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .panel }
                                    .disabled(!unitEditable)
                            }
                        }
                        if offersNoUnit {
                            LabNoUnitToggle(isOn: $noUnit)
                                .disabled(!unitEditable)
                        }
                        if !unitEditable {
                            Text("biomarker.editor.unit.waitsForServer")
                                .hlText(.note)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        LabFormField("biomarker.editor.panel") {
                            TextField("biomarker.editor.panel", text: $panel)
                                .focused($focusedField, equals: .panel)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .lowerBound }
                        }
                        LabPanelSuggestionChips(panels: store.customPanels, text: $panel)
                    }
                    Section("biomarker.editor.bounds") {
                        LabFormField("labs.add.referenceLow") {
                            TextField("labs.add.referenceLow", text: $lowerBoundText)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .lowerBound)
                        }
                        LabFormField("labs.add.referenceHigh") {
                            TextField("labs.add.referenceHigh", text: $upperBoundText)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .upperBound)
                        }
                    }
                    Section("biomarker.editor.context") {
                        TextField("biomarker.editor.contextField", text: $context, axis: .vertical)
                            .lineLimit(2 ... 5)
                            .focused($focusedField, equals: .context)
                    }
                    // Build 3 / item 3.2 — hide instead of delete. Only on edit.
                    if isEditing {
                        Section {
                            Toggle(isOn: $hidden) {
                                HLRowTitle("biomarker.editor.hidden")
                            }
                            .accessibilityIdentifier("biomarker.editor.hidden")
                        } footer: {
                            Text("biomarker.editor.hidden.footer")
                        }
                    }
                    if let inlineError {
                        Section { HLFormErrorText(inlineError) }
                    }
                }
                .hlFormRowSurface()
            }
            .hlPageMargins()
            // Seed focus onto the name field once the sheet settles.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                focusedField = .name
            }
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
                HLRowTitle("biomarker.editor.seed.label")
            }
            .accessibilityIdentifier("biomarker.editor.seed")
            .onChange(of: selectedSeedSlug) { _, newValue in
                guard let newValue, let seed = BiomarkerSeedCatalog.seed(slug: newValue) else { return }
                applySeed(seed)
            }
        } header: {
            Text("biomarker.editor.seed.section")
        } footer: {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("biomarker.editor.seed.footer")
                // 1.0.3 (1.4.1) — where the seeded reference ranges come from.
                HLSourcesLink(topic: .labReferenceRanges)
            }
        }
    }

    /// Pre-fill the definition fields from a seed. **Overwrites** whatever is
    /// there — same as the web, and the only sane reading of "I picked LDL".
    /// The operator can still edit every field afterwards; nothing is written
    /// to the server until Save.
    private func applySeed(_ seed: BiomarkerSeed) {
        name = seed.displayName
        unit = seed.unit
        noUnit = false
        lowerBoundText = seed.lowerBound.map { $0.formatted() } ?? ""
        upperBoundText = seed.upperBound.map { $0.formatted() } ?? ""
        panel = seed.panel.displayName
        inlineError = nil
    }

    /// Returns `true` when the sheet may close.
    private func save() async -> Bool {
        inlineError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedUnit = wireUnit ?? ""
        let trimmedPanel = LabPanelName.toSave(typed: panel, stored: existing?.panel)
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
                    // Only a real change: a rename of a marker without a unit
                    // must not send one (server 1.47.6 answers 422).
                    unit: LabUnit.markerPatchUnit(stored: existing.unit, edited: wireUnit),
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
            return true
        } else if store.lastErrorWasDuplicateName {
            inlineError = String(localized: "biomarker.duplicate.error")
        } else {
            inlineError = store.lastError ?? String(localized: "labs.save.failed")
        }
        return false
    }
}
