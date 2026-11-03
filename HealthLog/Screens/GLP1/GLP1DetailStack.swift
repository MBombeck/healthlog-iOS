import SwiftUI

/// **1.4 B2 — the GLP-1 sections of the medication detail, without empty cards.**
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

    var body: some View {
        let titrationEmpty = titrationStore.mergedTimeline.isEmpty
        let sideEffectsEmpty = sideEffectsStore.entries.isEmpty
        let pensEmpty = penInventoryStore.pens.isEmpty
        if !titrationEmpty {
            TitrationLadderSection(store: titrationStore)
        }
        if !sideEffectsEmpty {
            SideEffectsLogbookSection(store: sideEffectsStore)
        }
        if !pensEmpty {
            PenInventoryView(store: penInventoryStore, catalogPrefill: catalogPrefill)
        }
        if titrationEmpty || sideEffectsEmpty || pensEmpty {
            // 1.4 B4 — the card gets the label every section beside it has.
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel("glp1.add.section.label")
                addCard(titrationEmpty: titrationEmpty, sideEffectsEmpty: sideEffectsEmpty, pensEmpty: pensEmpty)
            }
        }
        InjectionSitePicker(store: injectionSiteStore)
    }

    private func addCard(titrationEmpty: Bool, sideEffectsEmpty: Bool, pensEmpty: Bool) -> some View {
        HLCard {
            VStack(spacing: 0) {
                if titrationEmpty {
                    TitrationLadderSection(store: titrationStore, showsAddRowOnly: true)
                }
                if titrationEmpty, sideEffectsEmpty || pensEmpty {
                    Divider().background(HLColor.separator)
                }
                if sideEffectsEmpty {
                    SideEffectsLogbookSection(store: sideEffectsStore, showsAddRowOnly: true)
                }
                if sideEffectsEmpty, pensEmpty {
                    Divider().background(HLColor.separator)
                }
                if pensEmpty {
                    PenInventoryView(store: penInventoryStore, catalogPrefill: catalogPrefill, showsAddRowOnly: true)
                }
            }
        }
    }
}

/// One journal in the GLP-1 "add" card: what it records, and the + that opens
/// its entry sheet. 44 pt tall, the whole row is the target.
struct GLP1AddRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HLSpace.md) {
                Image(systemName: systemImage)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                Spacer(minLength: HLSpace.sm)
                Image(systemName: "plus.circle.fill")
                    .font(.hlTitle3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
