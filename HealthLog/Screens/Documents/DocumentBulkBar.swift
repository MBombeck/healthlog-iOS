import SwiftUI

/// The floating bulk-action bar shown when ≥ 1 document is selected. Verbs, in
/// order: change kind, link condition, delete, clear — the destructive verb sits
/// last (before Clear) so a stray tap never lands on Delete (web parity).
struct DocumentBulkBar: View {
    let store: DocumentsStore
    let conditionChips: [DocumentConditionLink]

    @State private var isBusy = false

    var body: some View {
        HStack(spacing: HLSpace.sm) {
            Text(selectionLabel)
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
                .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: HLSpace.sm)

            Menu {
                ForEach(DocumentKindMeta.order) { kind in
                    Button {
                        run { await store.runBulk(.setKind, kind: kind) }
                    } label: {
                        Label(DocumentKindMeta.labelKey(kind), systemImage: DocumentKindMeta.icon(kind))
                    }
                }
            } label: {
                bulkIcon("tag", label: "documents.bulk.setKind")
            }
            .disabled(isBusy)
            .accessibilityIdentifier("documents.bulk.setKind")

            if !conditionChips.isEmpty {
                Menu {
                    ForEach(conditionChips) { chip in
                        Button {
                            run { await store.runBulk(.linkEpisode, episodeId: chip.episodeId) }
                        } label: {
                            Text(chip.name)
                        }
                    }
                } label: {
                    bulkIcon("folder.badge.plus", label: "documents.bulk.linkCondition")
                }
                .disabled(isBusy)
                .accessibilityIdentifier("documents.bulk.linkCondition")
            }

            Button {
                run {
                    await store.bulkDelete { count in
                        let template = String(localized: "documents.bulk.deleted")
                        return String(format: template, count)
                    }
                }
            } label: {
                bulkIcon("trash", label: "documents.bulk.delete", tint: HLColor.statusBad)
            }
            .disabled(isBusy)
            .accessibilityIdentifier("documents.bulk.delete")

            Button {
                store.clearSelection()
            } label: {
                Image(systemName: "xmark")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    // The clear verb is a bulk action too. It declares no frame
                    // of its own, so it inherits the shared region rather than a
                    // second literal — nothing scans this one, and the helper is
                    // the honest way to say "44, and nothing else".
                    .hlMinimumHitTarget()
                    .accessibilityLabel(Text("documents.selection.clear"))
            }
            .accessibilityIdentifier("documents.selection.clear")
        }
        .padding(.horizontal, HLSpace.md)
        .padding(.vertical, HLSpace.sm)
        // Reduce Transparency outranks the material: the bar is the only thing
        // between a selection count and whatever it floats over, so the opaque
        // answer is the elevated surface fill rather than a washed-out blur.
        // The shape moves from the material's `in:` argument onto the clip so
        // the rounded rect and the stroke overlay below still agree.
        .background(
            HLMaterialBackground(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                .stroke(HLColor.separator, lineWidth: 1)
        )
        .shadow(radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("documents.bulk.barLabel"))
    }

    /// The glyph keeps its headline typography and grows only its *region*:
    /// a `min` frame enlarges what was too small and leaves anything already
    /// large alone, so 36×32 becomes 44×44 without the icon changing size.
    ///
    /// The literal is deliberate. `Phase8AccessibilityPolicyTests` reads this
    /// member by name and parses digits out of its `.frame(`, so
    /// `.hlMinimumHitTarget()` — which is the same 44 by construction — is
    /// invisible to it, and `HLHitTarget.minimum` is an identifier rather than a
    /// number. Third time in the phase: 08-10's back chevron, 08-11's edit
    /// button, this.
    private func bulkIcon(_ systemName: String, label: LocalizedStringKey, tint: Color? = nil) -> some View {
        Image(systemName: systemName)
            .font(.hlHeadline)
            .foregroundStyle(tint ?? HLAccent.userBrandTint)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(label))
    }

    private var selectionLabel: String {
        let template = String(localized: "documents.selection.count")
        return String(format: template, store.selection.count)
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
