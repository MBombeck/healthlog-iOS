import SwiftUI

/// **HK-NEW (1.5)** — the quiet way back to the new Apple Health read types
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
            if !pending.isEmpty {
                Button {
                    Task {
                        isRequesting = true
                        await readiness.requestAnnouncedReadAuthorization(ignoringFlags: true)
                        isRequesting = false
                        await refresh()
                    }
                } label: {
                    HStack(spacing: HLSpace.xxs) {
                        Text("settings.applehealth.newTypes.link")
                        if isRequesting {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isRequesting)
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
