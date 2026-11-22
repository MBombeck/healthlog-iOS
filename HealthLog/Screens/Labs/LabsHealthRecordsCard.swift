import SwiftUI

/// The one Health Records offer in Labs (#180): lab results a provider
/// sends to Apple Health can land here. Connect asks HealthKit for lab
/// results alone; the cross declines for good. Shown only where the device,
/// its HealthKit and the server can do it, and only until it is answered.
struct LabsHealthRecordsCard: View {
    let store: ClinicalLabRecordsStore

    var body: some View {
        HLCard(
            "labs.healthRecords.title",
            subtitle: "labs.healthRecords.subtitle",
            trailing: {
                HLDismissButton(label: "labs.healthRecords.decline") { store.decline() }
                    .accessibilityIdentifier("labs.healthRecords.decline")
            },
            content: {
                HLButton(
                    "labs.healthRecords.connect",
                    systemImage: "heart.text.square",
                    variant: .secondary,
                    isLoading: store.isConnecting
                ) {
                    Task { await store.connect() }
                }
                .accessibilityIdentifier("labs.healthRecords.connect")
            }
        )
        .accessibilityIdentifier("labs.healthRecords.card")
    }
}

extension LabsScreen {
    /// The offer as one list section, or nothing.
    @ViewBuilder
    var healthRecordsSection: some View {
        if let records = container?.clinicalLabRecordsStore, records.offersCard {
            Section {
                LabsHealthRecordsCard(store: records)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: HLSpace.xs, leading: 0, bottom: HLSpace.xs, trailing: 0))
            }
        }
    }
}
