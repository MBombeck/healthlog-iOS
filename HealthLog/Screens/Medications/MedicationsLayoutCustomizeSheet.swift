import SwiftUI

/// **Medications list customize sheet ("Anpassen").**
///
/// The on-device counterpart to the web `/api/medications/layout` editor:
/// reorder the active medications by native drag (`EditButton` + `.onMove`).
/// The move PUTs the layout (`MedicationsStore.setListOrder`) with the
/// optimistic-write + Outbox + Idempotency-Key contract, so an order set here
/// shows up on the web and other devices on the next load.
///
/// **The presentation picker is gone.** `MedicationListView` has one
/// case, so the segmented control had exactly one option to offer and stated a
/// choice the app does not have. Order is the whole of what this sheet
/// customises now.
///
/// Medications hidden on this device are not listed; they keep their slot in
/// the saved order (`MedicationVisibilityOrder`), so moving the visible ones
/// never drops or shifts a hidden one.
///
/// Native reorder ONLY — the list stands in edit mode from the start, so the
/// drag handles of `.onMove` show at once (the project's reorder-native rule;
/// the custom jiggle/drag was retired in v0.8.7).
struct MedicationsLayoutCustomizeSheet: View {
    @Environment(MedicationsStore.self) private var store
    @Environment(\.appContainer) private var container

    private var hiddenIDs: Set<String> {
        container?.medicationVisibilityStore.hiddenIDs ?? []
    }

    var body: some View {
        HLSheetScaffold("med.layout.customize.title", action: .done()) {
            List {
                orderSection
            }
            .listStyle(.insetGrouped)
            .hlPageMargins()
            .hlScrollEdgeSoft()
            // The sheet exists to reorder, so it opens with the drag
            // handles showing; no Edit button and no footer explaining one.
            .environment(\.editMode, .constant(.active))
        }
    }

    // MARK: - Reorder

    /// Without an active medication there is nothing to order, and
    /// the section is left out rather than holding a sentence that says so.
    @ViewBuilder
    private var orderSection: some View {
        let meds = store.visibleActiveMedications(hiding: hiddenIDs)
        if !meds.isEmpty {
            Section {
                ForEach(meds, id: \.id) { med in
                    orderRow(med)
                }
                .onMove(perform: moveMedication)
            } header: {
                HLSectionHeader("med.layout.order.section.header")
            }
            .hlFormRowSurface()
        }
    }

    private func orderRow(_ medication: Medication) -> some View {
        HLRow(
            title: Text(verbatim: medication.name),
            detail: HLRowDetail.text([medication.dose.trimmingCharacters(in: .whitespacesAndNewlines)])
        ) {
            HLRowGlyph(symbol: "pills.fill")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(medication.name))
    }

    /// Apply the native drag to the displayed (visible, already-ordered) list,
    /// put the hidden ids back in their slots, then PUT the full id sequence.
    /// `setListOrder` caps to the server bound and keeps the saved view via
    /// preserve-when-absent.
    private func moveMedication(from source: IndexSet, to destination: Int) {
        let hidden = hiddenIDs
        var visible = store.visibleActiveMedications(hiding: hidden).map(\.id)
        visible.move(fromOffsets: source, toOffset: destination)
        let order = MedicationVisibilityOrder.merged(
            fullOrder: store.activeMedications.map(\.id),
            visibleOrder: visible,
            hidden: hidden
        )
        Task { await store.setListOrder(order) }
    }
}
