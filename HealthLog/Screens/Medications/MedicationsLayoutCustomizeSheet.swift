import SwiftUI

/// **W-B184 MED-1 — medications list customize sheet ("Anpassen").**
///
/// The on-device counterpart to the web `/api/medications/layout` editor:
/// reorder the active medications by native drag (`EditButton` + `.onMove`).
/// The move PUTs the layout (`MedicationsStore.setListOrder`) with the
/// optimistic-write + Outbox + Idempotency-Key contract, so an order set here
/// shows up on the web and other devices on the next load.
///
/// **08-05 — the presentation picker is gone.** `MedicationListView` has one
/// case, so the segmented control had exactly one option to offer and stated a
/// choice the app does not have. Order is the whole of what this sheet
/// customises now.
///
/// Native reorder ONLY — the list stands in edit mode from the start, so the
/// drag handles of `.onMove` show at once (the project's reorder-native rule;
/// the custom jiggle/drag was retired in v0.8.7).
struct MedicationsLayoutCustomizeSheet: View {
    @Environment(MedicationsStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                orderSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .hlScreenBackground()
            .hlScrollEdgeSoft()
            // 1.4 B2 — the sheet exists to reorder, so it opens with the drag
            // handles showing; no Edit button and no footer explaining one.
            .environment(\.editMode, .constant(.active))
            .navigationTitle(String(localized: "med.layout.customize.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Done")) { dismiss() }
                        .tint(HLText.primary)
                }
            }
        }
    }

    // MARK: - Reorder

    /// 1.4 B4 — without an active medication there is nothing to order, and
    /// the section is left out rather than holding a sentence that says so.
    @ViewBuilder
    private var orderSection: some View {
        let meds = store.activeMedications
        if !meds.isEmpty {
            Section {
                ForEach(meds, id: \.id) { med in
                    orderRow(med)
                }
                .onMove(perform: moveMedication)
            } header: {
                Text(String(localized: "med.layout.order.section.header"))
            }
        }
    }

    private func orderRow(_ medication: Medication) -> some View {
        HStack(spacing: HLSpace.md) {
            Image(systemName: "pills.fill")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.secondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(medication.name)
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                let dose = medication.dose.trimmingCharacters(in: .whitespacesAndNewlines)
                if !dose.isEmpty {
                    Text(dose)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(medication.name))
    }

    /// Apply the native drag to the displayed (active, already-ordered) list,
    /// then PUT the full id sequence. `setListOrder` caps to the server bound
    /// and keeps the saved view via preserve-when-absent.
    private func moveMedication(from source: IndexSet, to destination: Int) {
        var ids = store.activeMedications.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        Task { await store.setListOrder(ids) }
    }
}
