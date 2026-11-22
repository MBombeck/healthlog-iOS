import SwiftUI

/// Informed-consent sheet for the **client-side BYO-key** AI path
/// (Apple Guideline 5.1.2(i)). Mirrors ``AIConsentSheet`` but the data-flow copy
/// is adapted for the device→provider-direct egress: the user's values go
/// straight from this iPhone to *their own* provider, NOT through HealthLog's
/// servers. Presented after a key validates + saves, before the per-provider
/// grant lands (``BYOKeyEntryModel/confirmConsent()``).
struct BYOConsentSheet: View {
    let provider: BYOProviderID
    let onAccept: () -> Void
    let onDecline: () -> Void

    /// The same frame as ``AIConsentSheet``: the decision is the title, the X
    /// declines like "Decline", and swiping down is locked.
    var body: some View {
        HLSheetScaffold("Use your own AI key", onClose: onDecline) {
            HLPage {
                Text(consentCopy)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        HLIconTextRow(
                            icon: "iphone.gen3",
                            verbatim: String(
                                localized: "Requests go directly from this device to your provider — not through HealthLog's servers."
                            )
                        )
                        HLIconTextRow(
                            icon: "lock.shield",
                            verbatim: String(
                                localized: "Your name, email, and device ID are never sent."
                            )
                        )
                        HLIconTextRow(
                            icon: "building.2",
                            verbatim: String(
                                localized: "Your provider receives this data and handles it under their own privacy policy."
                            )
                        )
                        HLIconTextRow(
                            icon: "arrow.uturn.backward",
                            verbatim: String(localized: "You can remove your key at any time in Settings → Assistant.")
                        )
                    }
                }
            }
            // Locked at both ends of the sheet's own discard guard (which
            // unlocks while nothing is typed), so no swipe skips the answer.
            .interactiveDismissDisabled(true)
            .hlBottomBar {
                HLButtonPair {
                    HLButton("Accept", variant: .primary, action: onAccept)
                } secondary: {
                    HLButton("Decline", variant: .secondary, action: onDecline)
                }
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var consentCopy: String {
        String(
            // swiftlint:disable:next line_length
            localized: "HealthLog sends excerpts of your health data — recent measurements, medications, sleep, and mood — directly to \(provider.displayName), using the API key you provided, to generate personal insights."
        )
    }
}
