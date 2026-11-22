import SwiftUI

/// The quiet way back to the new Apple Health read types
/// at the foot of the type list.
///
/// The dashboard card (`HealthKitNewReadTypesCard`) explains them once. After
/// "Not now" it stays away, but iOS still calls the types unanswered, and the
/// Health app lists only types an app has asked for, so without this link the
/// person could never turn them on. It shows only while iOS would still ask
/// (`pendingAnnouncedReadTypes(ignoringFlags: true)`), and it is gone once the
/// sheet was answered, granted or not.
struct AppleHealthNewReadTypesLink: View {
    @Environment(HKReadinessStore.self) private var readiness
    @State private var pending: [String] = []
    @State private var isRequesting = false

    var body: some View {
        Group {
            if isRequesting {
                // In the link's place and height while iOS asks.
                HLInlineProgress()
                    .frame(maxWidth: .infinity, minHeight: HLLinkButton.hitHeight)
            } else if !pending.isEmpty {
                HLLinkButton("settings.applehealth.newTypes.link") {
                    Task {
                        isRequesting = true
                        await readiness.requestAnnouncedReadAuthorization(ignoringFlags: true)
                        isRequesting = false
                        await refresh()
                    }
                }
                .accessibilityHint(Text(HealthKitNewReadTypesCard.body(for: pending)))
                .accessibilityIdentifier("settings.integrations.appleHealth.newTypes")
            }
        }
        .task(id: readiness.state) { await refresh() }
    }

    private func refresh() async {
        pending = await readiness.pendingAnnouncedReadTypes(ignoringFlags: true)
    }
}
