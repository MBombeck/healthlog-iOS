import SwiftUI

/// **v1.27.7 — the hero score-ring picker.**
///
/// Lets the user choose up to ``ScoreRingID/maxSelected`` scores from the closed
/// ``ScoreRingID`` set to feature as dashboard hero rings. On Save it hands the
/// chosen ids AND the hero ring order back to the caller, which persists both
/// via ``DashboardLayoutStore/setScoreRings(selected:heroOrder:)`` (the widgets
/// PUT with the preserve-when-absent contract). The server RESOLVES today's
/// value per ring; this sheet only records the choice.
///
/// **1.4 B1 — the order section is gone.** Parity Build 4 · 4.8 added a
/// move-up/move-down list over ``HeroRingID`` for the hero row on the
/// dashboard. That row no longer exists anywhere: iOS moved the rings to
/// Insights (`acb44cb70`), and the web hero dropped its ring cluster in
/// v1.29.1. Insights orders its cards by the pick sequence, so the editor
/// changed nothing the user could see, and its copy („Reihenfolge auf der
/// Startseite") described a place the rings had left. The stored
/// `heroRingOrder` is still reconciled against the selection on every toggle
/// and saved with it, so the server value stays consistent.
///
/// The server has preserved `heroRingOrder` when a payload omits it since
/// v1.27.27 (`api/dashboard/widgets/route.ts:286-310`).
struct ScoreRingSelectionSheet: View {
    /// The current selection to pre-check the rows (selection-ordered).
    let initialSelection: [ScoreRingID]
    /// The current hero ring order (anchor + selection), reconciled by the
    /// caller. Empty → derived from `initialSelection` on the fly.
    var initialOrder: [HeroRingID] = []
    /// Called with the new selection + hero order when the user saves.
    let onSave: ([ScoreRingID], [HeroRingID]) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Working selection — ORDERED (append-on-select): the pick sequence is the
    /// order the Insights cards render in.
    @State private var selection: [ScoreRingID]
    /// Stored hero order, no longer editable here. Kept reconciled against
    /// `selection` on every toggle so a deselected ring never lingers in it.
    @State private var order: [HeroRingID]

    init(
        initialSelection: [ScoreRingID],
        initialOrder: [HeroRingID] = [],
        onSave: @escaping ([ScoreRingID], [HeroRingID]) -> Void
    ) {
        self.initialSelection = initialSelection
        self.initialOrder = initialOrder
        self.onSave = onSave
        _selection = State(initialValue: initialSelection)
        _order = State(initialValue: HeroRingID.resolved(
            order: initialOrder.isEmpty ? nil : initialOrder,
            selected: initialSelection
        ))
    }

    private var isAtCap: Bool {
        selection.count >= ScoreRingID.maxSelected
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    Text(String(
                        localized: "Pick up to \(ScoreRingID.maxSelected) scores to feature in Insights.",
                        comment: "Score-ring picker subtitle"
                    ))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: HLSpace.sm) {
                        ForEach(ScoreRingID.allCases, id: \.self) { id in
                            row(for: id)
                        }
                    }
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.vertical, HLSpace.lg)
            }
            .hlScreenBackground()
            .hlScrollEdgeSoft()
            .navigationTitle(Text(String(localized: "Score rings", comment: "Score-ring picker title")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        onSave(selection, order)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for id: ScoreRingID) -> some View {
        let isSelected = selection.contains(id)
        // A non-selected row is disabled once the cap is reached — the user
        // must deselect one first (honest cap, no silent drop).
        let isDisabled = !isSelected && isAtCap
        Button {
            toggle(id)
        } label: {
            HLCard {
                HStack(spacing: HLSpace.md) {
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(id.label)
                            .font(.hlSubhead.weight(.medium))
                            .foregroundStyle(isDisabled ? HLText.tertiary : HLText.primary)
                        Text(description(for: id))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: HLSpace.sm)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.hlIcon(HLIconSize.md, weight: .semibold))
                        .foregroundStyle(isSelected ? HLText.primary : HLText.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .hlPressable()
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(id.label))
        .accessibilityValue(Text(isSelected
                ? String(localized: "Selected")
                : String(localized: "Not selected")))
        .accessibilityHint(Text(isDisabled
                ? String(localized: "Deselect a score first")
                : String(localized: "Double-tap to toggle")))
    }

    private func toggle(_ id: ScoreRingID) {
        if let idx = selection.firstIndex(of: id) {
            selection.remove(at: idx)
        } else if selection.count < ScoreRingID.maxSelected {
            selection.append(id)
        }
        // Keep the order reconciled against the live selection: a ring the user
        // just dropped must leave the order in the same gesture, and a newly
        // picked one appears at the tail (never silently at the front).
        order = HeroRingID.resolved(order: order, selected: selection)
    }

    /// A one-line "what needs what" description per ring so the user knows why a
    /// ring might not resolve (a wearable-derived score vs the always-available
    /// medication tally).
    private func description(for id: ScoreRingID) -> String {
        switch id {
        case .readiness:
            String(localized: "Your daily readiness blend.", comment: "READINESS ring picker description")
        case .recovery:
            String(localized: "Overnight recovery from your wearable.", comment: "RECOVERY ring picker description")
        case .sleepScore:
            String(localized: "Last night's sleep quality.", comment: "SLEEP_SCORE ring picker description")
        case .medCompliance:
            String(localized: "Today's medication doses taken.", comment: "MED_COMPLIANCE ring picker description")
        }
    }
}
