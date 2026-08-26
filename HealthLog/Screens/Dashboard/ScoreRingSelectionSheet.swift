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
/// **Parity Build 4 · 4.8 — the order section.** Web has always let the user
/// drag the hero rings, INCLUDING the always-present health-score anchor
/// (`dashboard-layout-section.tsx:626-663`); iOS could only imply an order from
/// the tap sequence and could not express the anchor's position at all. The
/// second section below is that missing capability: a move-up/move-down list
/// over ``HeroRingID`` with the anchor as an ordinary, movable row.
///
/// The server has preserved `heroRingOrder` when a payload omits it since
/// v1.27.27 (`api/dashboard/widgets/route.ts:286-310`), so every earlier iOS
/// save was safe — this adds a capability, it does not repair a data loss.
struct ScoreRingSelectionSheet: View {
    /// The current selection to pre-check the rows (selection-ordered).
    let initialSelection: [ScoreRingID]
    /// The current hero ring order (anchor + selection), reconciled by the
    /// caller. Empty → derived from `initialSelection` on the fly.
    var initialOrder: [HeroRingID] = []
    /// Called with the new selection + hero order when the user saves.
    let onSave: ([ScoreRingID], [HeroRingID]) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Working selection — ORDERED (append-on-select) so a user who never
    /// touches the order section still gets their pick sequence honoured.
    @State private var selection: [ScoreRingID]
    /// Working hero order. Kept reconciled against `selection` on every toggle
    /// so a deselected ring can never linger as a ghost row.
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
                        localized: "Pick up to \(ScoreRingID.maxSelected) scores to feature on your dashboard and in Insights.",
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

                    orderSection
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

    // MARK: - Parity Build 4 · 4.8 — hero ring order (incl. the anchor)

    /// The order editor. The health-score ring is an ordinary row here — it has
    /// no on/off toggle (it is always on the hero) but it IS positionable,
    /// which is exactly the capability iOS lacked. Uses arrow buttons rather
    /// than a `List`'s `.onMove`: this sheet is a `ScrollView`, and a nested
    /// `List` inside it would fight the outer scroll. Buttons are also the
    /// VoiceOver-correct path web already offers alongside its drag handles.
    @ViewBuilder
    private var orderSection: some View {
        if order.count > 1 {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(String(
                    localized: "Order on the dashboard",
                    comment: "Hero ring order section title"
                ))
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)

                Text(String(
                    localized: "The health score ring is always shown. Move it anywhere in the row.",
                    comment: "Hero ring order section hint"
                ))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: HLSpace.sm) {
                    ForEach(Array(order.enumerated()), id: \.element) { index, id in
                        orderRow(for: id, at: index)
                    }
                }
            }
            .padding(.top, HLSpace.md)
        }
    }

    private func orderRow(for id: HeroRingID, at index: Int) -> some View {
        HLCard {
            HStack(spacing: HLSpace.md) {
                Text(id.label)
                    .font(.hlSubhead.weight(.medium))
                    .foregroundStyle(HLText.primary)
                Spacer(minLength: HLSpace.sm)
                moveButton(systemImage: "chevron.up", disabled: index == 0) {
                    order.swapAt(index, index - 1)
                }
                moveButton(systemImage: "chevron.down", disabled: index == order.count - 1) {
                    order.swapAt(index, index + 1)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.heroRingOrder.\(id.rawValue)")
    }

    private func moveButton(
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.hlIcon(HLIconSize.sm, weight: .semibold))
                .foregroundStyle(disabled ? HLText.tertiary : HLText.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(Text(systemImage == "chevron.up"
                ? String(localized: "Move up")
                : String(localized: "Move down")))
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
