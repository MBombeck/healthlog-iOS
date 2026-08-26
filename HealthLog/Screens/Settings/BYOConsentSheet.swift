import SwiftUI

/// v0.13 W4 — informed-consent sheet for the **client-side BYO-key** AI path
/// (Apple Guideline 5.1.2(i)). Mirrors ``AIConsentSheet`` but the data-flow copy
/// is adapted for the device→provider-direct egress: the user's values go
/// straight from this iPhone to *their own* provider, NOT through HealthLog's
/// servers. Presented after a key validates + saves, before the per-provider
/// grant lands (``BYOKeyEntryModel/confirmConsent()``).
struct BYOConsentSheet: View {
    let provider: BYOProviderID
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    Image(systemName: "key")
                        .font(.hlLargeTitle.weight(.light))
                        .foregroundStyle(HLText.primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(String(localized: "Use your own AI key"))
                        .font(.hlLargeTitle)
                        .foregroundStyle(HLText.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(consentCopy)
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        bulletRow(
                            symbol: "iphone.gen3",
                            text: String(
                                localized: "Requests go directly from this device to your provider — not through HealthLog's servers."
                            )
                        )
                        bulletRow(
                            symbol: "lock.shield",
                            text: String(
                                localized: "Your name, email, and device ID are never sent."
                            )
                        )
                        bulletRow(
                            symbol: "building.2",
                            text: String(
                                localized: "Your provider receives this data and handles it under their own privacy policy."
                            )
                        )
                        bulletRow(
                            symbol: "arrow.uturn.backward",
                            text: String(localized: "You can remove your key at any time in Settings → Assistant.")
                        )
                    }
                    .padding(HLSpace.md)
                    .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.md))

                    Spacer(minLength: HLSpace.xl)
                }
                .padding(HLSpace.lg)
            }
            .hlScrollEdgeSoft()
            .navigationTitle(String(localized: "Data flow"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Decline"), action: onDecline)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: HLSpace.sm) {
                    // v0.14.4 FW-COACH — see AIConsentSheet: pin the fill to the
                    // monochrome `HLAccent.primary` token so it matches the
                    // tint the button's WCAG label-clamp samples, preventing a
                    // white-on-white CTA when the sheet's ambient `.tint`
                    // resolves near-white in light mode.
                    HLButton(
                        String(localized: "Accept"),
                        variant: .primary,
                        size: .large,
                        action: onAccept
                    )
                    .tint(HLAccent.primary)
                    Text(String(localized: "You can change this choice at any time in Settings."))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(HLSpace.lg)
                .background(HLMaterialBackground(.regularMaterial))
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

    private func bulletRow(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: symbol)
                .font(.hlCallout.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .frame(width: 24)
            Text(text)
                .font(.hlFootnote)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
