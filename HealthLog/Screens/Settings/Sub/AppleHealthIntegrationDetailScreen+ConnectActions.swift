import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// **#154 (MIRROR, 1.5)** — the one action the Apple Health connection card
/// offers, chosen by ``HKReadinessStore/ConnectionAction``.
///
/// - `.connect`: the system dialog is unanswered, so the primary button asks.
/// - `.reviewWriteAccess`: receiving works (or the dialog was answered) but
///   write types are missing. A quiet link beside the write-back notice opens
///   Apple Health; a second "Connect" would only flash the sheet, because iOS
///   never asks twice about the same type.
/// - `.openHealthApp`: declined and nothing arrived. Apple Health is the only
///   place left to change it, so opening it is the primary button.
/// - `.none`: nothing to do.
///
/// Its own view so the three states can be rendered and checked in a test
/// without a HealthKit store.
struct AppleHealthConnectActions: View {
    let action: HKReadinessStore.ConnectionAction
    /// The connect request is running.
    var isRequesting = false
    /// iOS closed the sheet at once on the last request (see
    /// `HKReadinessStore.lastAuthorizationWasNoOp`).
    var showsNoOpHint = false
    let connect: () -> Void

    var body: some View {
        switch action {
        case .none:
            EmptyView()
        case .connect:
            HLButton(
                String(localized: "Connect to Apple Health"),
                icon: "heart.fill",
                variant: .primary,
                isLoading: isRequesting,
                action: connect
            )
            .accessibilityIdentifier("settings.integrations.connectAppleHealth")
        case .reviewWriteAccess:
            if let url = HKReadinessStore.healthAppDeepLink {
                Link(destination: url) {
                    HStack(spacing: HLSpace.xxs) {
                        Text("settings.applehealth.writeback.review")
                        Image(systemName: "arrow.up.right")
                            .font(.hlCaption2)
                            .accessibilityHidden(true)
                    }
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                }
                .accessibilityHint(Text("settings.applehealth.writeback.review.hint"))
                .accessibilityIdentifier("settings.integrations.reviewWriteAccess")
            }
        case .openHealthApp:
            if let url = HKReadinessStore.healthAppDeepLink {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    if showsNoOpHint {
                        Text("settings.integrations.healthapp_hint")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HLButton(
                        String(localized: "Open in Apple Health"),
                        icon: "arrow.up.right.square",
                        variant: .primary
                    ) {
                        #if canImport(UIKit)
                            UIApplication.shared.open(url)
                        #endif
                    }
                    .accessibilityIdentifier("settings.integrations.openHealthApp")
                }
            }
        }
    }
}
