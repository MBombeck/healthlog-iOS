import SwiftUI

/// The bulk actions shown while ≥ 1 document is selected, as the items of the
/// system bottom bar (`ToolbarItemGroup(placement: .bottomBar)`), which brings
/// the glass. Verbs, in order: change kind, link condition, delete, clear — the
/// destructive verb sits last (before Clear) so a stray tap never lands on
/// Delete (web parity).
struct DocumentBulkBar: View {
    let store: DocumentsStore
    let conditionChips: [DocumentConditionLink]

    @State private var isBusy = false

    /// No stack around the items: the toolbar lays each one out as its own
    /// bar item.
    var body: some View {
        Text(selectionLabel)
            .hlText(.rowTitle)
            .accessibilityAddTraits(.updatesFrequently)
        Spacer(minLength: HLSpace.sm)

        HLIconButton(systemImage: "tag", label: "documents.bulk.setKind", menu: {
            ForEach(DocumentKindMeta.order) { kind in
                Button {
                    run { await store.runBulk(.setKind, kind: kind) }
                } label: {
                    Label(DocumentKindMeta.labelKey(kind), systemImage: DocumentKindMeta.icon(kind))
                }
            }
        })
        .disabled(isBusy)
        .accessibilityIdentifier("documents.bulk.setKind")

        if !conditionChips.isEmpty {
            HLIconButton(systemImage: "folder.badge.plus", label: "documents.bulk.linkCondition", menu: {
                ForEach(conditionChips) { chip in
                    Button(chip.name) {
                        run { await store.runBulk(.linkEpisode, episodeId: chip.episodeId) }
                    }
                }
            })
            .disabled(isBusy)
            .accessibilityIdentifier("documents.bulk.linkCondition")
        }

        // Several documents at once take their links and summaries
        // along: asked first, like a single document. The question is
        // asked by the `hlDeleteConfirmation()` on the documents list.
        HLDeleteButton(
            "documents.bulk.delete",
            form: .bar,
            action: .confirmed(title: deleteQuestion) { await deleteSelection() }
        )
        .labelStyle(BulkBarIconLabelStyle())
        .disabled(isBusy)
        .accessibilityLabel(Text("documents.bulk.delete"))
        .accessibilityIdentifier("documents.bulk.delete")

        HLIconButton(systemImage: "xmark", label: "documents.selection.clear") {
            store.clearSelection()
        }
        .accessibilityIdentifier("documents.selection.clear")
    }

    private var selectionLabel: String {
        let template = String(localized: "documents.selection.count")
        return String(format: template, store.selection.count)
    }

    /// "Delete document?" for one, "Delete 3 documents?" for more.
    private var deleteQuestion: LocalizedStringKey {
        let count = store.selection.count
        return count == 1
            ? "documents.detail.deleteConfirm.title"
            : "documents.bulk.deleteConfirm.title \(count)"
    }

    private func deleteSelection() async {
        isBusy = true
        defer { isBusy = false }
        _ = await store.bulkDelete { count in
            let template = String(localized: "documents.bulk.deleted")
            return String(format: template, count)
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await action()
            isBusy = false
        }
    }
}

/// The bar shows the sign of the delete button alone, on the same touch area
/// as its other verbs; the button keeps its colour and its spoken title.
private struct BulkBarIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon
            .font(.hlHeadline)
            .hlMinimumHitTarget()
    }
}
