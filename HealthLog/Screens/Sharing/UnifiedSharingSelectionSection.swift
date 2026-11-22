import SwiftUI

/// The first question — *what rides* — as its own component.
///
/// It owns the disclosure state and nothing else, which is why it is a view
/// rather than a `@ViewBuilder` on the screen: "Alles auswählen" opens the
/// drawer it just filled, and that is a fact about this section, not about the
/// page around it.
///
/// **E1.2 lives here in two visible pieces**: the state-dependent line that
/// says what an empty selection means, and the bulk pair whose widening half
/// carries its consequence in the sentence directly beneath it.
struct UnifiedSharingSelectionSection: View {
    let store: UnifiedSharingStore

    @State private var isSelectionExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            switch store.phase {
            case .idle, .loading:
                loadingRow
            case let .unavailable(reason):
                unavailable(reason)
            case .ready:
                selectionBody()
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: HLSpace.sm) {
            ProgressView().controlSize(.small)
            Text("report.selection.loading")
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
        }
    }

    @ViewBuilder
    private func unavailable(_ reason: UnifiedSharingStore.Unavailability) -> some View {
        switch reason {
        case let .loadFailed(message):
            Text(verbatim: message)
                .font(.hlFootnote)
                .foregroundStyle(HLColor.statusBad)
                .fixedSize(horizontal: false, vertical: true)
        case .noVocabulary:
            // Deliberately NOT a local fallback list: a scope this app invented
            // is the exact defect the v2 selection removes.
            Text("report.selection.noVocabulary")
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HLButton("report.selection.retry", variant: .secondary) {
            Task { await store.reload() }
        }
        .accessibilityIdentifier("sharing.unified.retry")
    }

    @ViewBuilder
    private func selectionBody() -> some View {
        Text(verbatim: UnifiedSharingCopy.countSummary(store))
            .font(.hlFootnote)
            .foregroundStyle(HLText.secondary)
            .accessibilityIdentifier("sharing.unified.summary")

        // "nothing chosen means no health data rides" is said once,
        // in the action card next to the button it is about.

        if let notice = store.profile.notice {
            Text(UnifiedSharingCopy.noticeText(notice))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !store.droppedForForm.isEmpty {
            Text(UnifiedSharingCopy.droppedSummary(store))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sharing.unified.dropped")
        }

        bulkControls()

        DisclosureGroup(isExpanded: $isSelectionExpanded) {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                ForEach(store.offeredLeaves, id: \.self) { leaf in
                    leafRow(leaf)
                }
            }
            .padding(.top, HLSpace.xs)
        } label: {
            Text("sharing.unified.disclose")
                .font(.hlSubhead.weight(.semibold))
        }
        .accessibilityIdentifier("sharing.unified.disclose")
    }

    /// **E1.2's pair.** Widening is an act with a stated consequence; narrowing
    /// is always available next to it.
    private func bulkControls() -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HLButtonPair {
                HLButton("sharing.unified.selectAll", variant: .secondary) {
                    store.selectAll()
                    isSelectionExpanded = true
                }
                .accessibilityIdentifier("sharing.unified.selectAll")
            } secondary: {
                HLButton("sharing.unified.clear", variant: .secondary) {
                    store.clearSelection()
                }
                // Nothing to clear, nothing to tap.
                .disabled(store.chosen.isEmpty)
                .accessibilityIdentifier("sharing.unified.clear")
            }
            // The consequence of "Select everything" appears when
            // it is true (everything is ticked), not as a standing line under
            // the buttons. The screen holds no dialog on purpose (see
            // `UnifiedSharingScreen`), so there is no confirmation to put it in.
            if !store.offeredLeaves.isEmpty, store.offeredLeaves.allSatisfy(store.isChosen) {
                Text("sharing.unified.selectAll.consequence")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sharing.unified.selectAll.consequence")
            }
        }
    }

    /// One selectable leaf. A row rather than a switch: this is a membership
    /// list, and a checkmark reads as membership where a switch reads as a
    /// setting.
    private func leafRow(_ leaf: String) -> some View {
        HLChoiceRow(
            title: Text(verbatim: ReportLeafDisplay.label(for: leaf)),
            isSelected: store.isChosen(leaf),
            mode: .multiple
        ) {
            store.toggle(leaf)
        }
        .accessibilityIdentifier("sharing.unified.leaf.\(leaf)")
    }
}
