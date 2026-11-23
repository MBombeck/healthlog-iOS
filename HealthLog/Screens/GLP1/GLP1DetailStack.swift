import SwiftUI

/// **The GLP-1 sections of the medication detail, without empty cards.**
///
/// Titration, side effects and pens each used to stand as a label over a ghost
/// card explaining what could be logged there, so a fresh GLP-1 medication
/// opened onto a stack of empty cards. A journal with entries still renders
/// as its own section; the ones without any become one row each in a single
/// card, and the row's + opens the same sheet the section header would. The
/// injection-site map follows, as before.
struct GLP1DetailStack: View {
    let titrationStore: TitrationLadderStore
    let sideEffectsStore: SideEffectsLogbookStore
    let penInventoryStore: PenInventoryStore
    let injectionSiteStore: InjectionSiteStore
    let catalogPrefill: PenInventoryPrefill

    /// The open add sheet. It hangs on this stack, not on a section: the first
    /// entry swaps a section from its row in the add card to its full form,
    /// and a sheet on the row would lose its presenter while still saving.
    @State private var addSheet: GLP1AddSheet?

    var body: some View {
        let titrationEmpty = titrationStore.mergedTimeline.isEmpty
        let sideEffectsEmpty = sideEffectsStore.entries.isEmpty
        let pensEmpty = penInventoryStore.pens.isEmpty
        // The page's gap, so wrapping the sections changes no layout and
        // their headers keep their room.
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            if !titrationEmpty {
                TitrationLadderSection(store: titrationStore) { addSheet = .titrationStep }
            }
            if !sideEffectsEmpty {
                SideEffectsLogbookSection(store: sideEffectsStore) { addSheet = .sideEffect }
            }
            if !pensEmpty {
                PenInventoryView(store: penInventoryStore, catalogPrefill: catalogPrefill) { addSheet = .pen }
            }
            if titrationEmpty || sideEffectsEmpty || pensEmpty {
                // The card gets the header every section beside it has.
                HLSectionHeader("glp1.add.section.label", rank: .area)
                addCard(titrationEmpty: titrationEmpty, sideEffectsEmpty: sideEffectsEmpty, pensEmpty: pensEmpty)
            }
            InjectionSitePicker(store: injectionSiteStore)
        }
        .sheet(item: $addSheet) { sheet in
            addSheetContent(sheet)
        }
    }

    @ViewBuilder
    private func addSheetContent(_ sheet: GLP1AddSheet) -> some View {
        switch sheet {
        case .pen:
            PenInventoryEditSheet(prefill: catalogPrefill) { manufacturer, dose, dispensedAt, firstUsedAt, notes in
                await penInventoryStore.add(
                    manufacturer: manufacturer,
                    doseStrength: dose,
                    dispensedAt: dispensedAt,
                    firstUsedAt: firstUsedAt,
                    notes: notes
                )
            }
        case .sideEffect:
            SideEffectLogSheet { loggedAt, kind, severity, note in
                await sideEffectsStore.log(loggedAt: loggedAt, kind: kind, severity: severity, note: note)
            }
        case .titrationStep:
            TitrationStepEditSheet(mode: .add) { effective, doseMg, note in
                await titrationStore.add(effectiveFrom: effective, doseMg: doseMg, note: note)
            }
        }
    }

    private func addCard(titrationEmpty: Bool, sideEffectsEmpty: Bool, pensEmpty: Bool) -> some View {
        HLCard(layout: .rows) {
            if titrationEmpty {
                TitrationLadderSection(store: titrationStore, showsAddRowOnly: true) { addSheet = .titrationStep }
            }
            if sideEffectsEmpty {
                SideEffectsLogbookSection(store: sideEffectsStore, showsAddRowOnly: true) { addSheet = .sideEffect }
            }
            if pensEmpty {
                PenInventoryView(
                    store: penInventoryStore,
                    catalogPrefill: catalogPrefill,
                    showsAddRowOnly: true
                ) { addSheet = .pen }
            }
        }
    }
}

/// The three GLP-1 journals that are added to through a sheet.
enum GLP1AddSheet: String, Identifiable {
    case pen
    case sideEffect
    case titrationStep

    var id: String {
        rawValue
    }
}

/// One journal in the GLP-1 "add" card: what it records, and the + that opens
/// its entry sheet. A full row of the grid, the whole row is the target.
struct GLP1AddRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    var identifier: String?
    let action: () -> Void

    var body: some View {
        HLSettingsActionRow(icon: systemImage, title: title, presents: .create, action: action)
            .accessibilityIdentifier(identifier ?? "")
    }
}

/// The actions of a GLP-1 journal row. A row in a card carries no menu button
/// of its own: a long press opens the actions, and VoiceOver offers the same.
struct GLP1RowActions: ViewModifier {
    var markUsedUp: (() -> Void)?
    var edit: (() -> Void)?
    var delete: HLDeleteAction?
    /// Comes from `hlDeleteConfirmation()` on the section, which asks first.
    @Environment(HLDeleteRunner.self) private var deleteRunner: HLDeleteRunner?

    func body(content: Content) -> some View {
        if markUsedUp == nil, edit == nil, delete == nil {
            // An empty long-press menu would feel broken.
            content
        } else {
            content
                .contextMenu {
                    if let markUsedUp {
                        Button(action: markUsedUp) {
                            Label("Mark as used up", systemImage: "checkmark.circle")
                        }
                    }
                    if let edit {
                        Button(action: edit) {
                            Label(HLControlWord.edit.key, systemImage: "pencil")
                        }
                    }
                    if let delete {
                        HLDeleteMenuItem(delete)
                    }
                }
                // A long press has no VoiceOver equivalent of its own.
                .accessibilityActions {
                    if let markUsedUp {
                        Button("Mark as used up", action: markUsedUp)
                    }
                    if let edit {
                        Button(HLControlWord.edit.key, action: edit)
                    }
                    if let delete {
                        // The runner asks first, like the menu item.
                        Button { runDelete(delete) } label: { delete.wordText }
                    }
                }
        }
    }

    private func runDelete(_ action: HLDeleteAction) {
        if let deleteRunner {
            deleteRunner.trigger(action)
        } else if !action.requiresConfirmation {
            Task { await action.run() }
        }
    }
}

extension View {
    /// Long-press menu and VoiceOver actions of a GLP-1 journal row.
    func glp1RowActions(
        markUsedUp: (() -> Void)? = nil,
        edit: (() -> Void)? = nil,
        delete: HLDeleteAction? = nil
    ) -> some View {
        modifier(GLP1RowActions(markUsedUp: markUsedUp, edit: edit, delete: delete))
    }
}
