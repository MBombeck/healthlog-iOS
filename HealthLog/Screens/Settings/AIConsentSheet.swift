import SwiftUI

/// Per QA3 BLOCKER 2 — Apple Guideline 5.1.2(i) (Nov 2025): before sending
/// health data to a remote LLM, present an informed-consent sheet ONCE per
/// provider change. Sheet copy enumerates the data flow, the anonymisation
/// promise, and the revoke path.
struct AIConsentSheet: View {
    /// Bug 5 (v0.14.8) — distinguishes WHICH data-flow this consent governs so
    /// the copy never asserts a provider the client can't actually know.
    enum Context {
        /// Server (External) AI: data goes to the user's own server, which then
        /// forwards it to its configured provider. The client cannot trust which
        /// third party that is (it's a server/operator concern), so the copy is
        /// deliberately provider-agnostic — "your server".
        case serverMediated
        /// BYO-key / local: the user literally chose the provider themselves, so
        /// naming it is honest and useful.
        case userChosen
    }

    let provider: AIProvider
    /// Defaults to `.serverMediated` because both current call sites (the shell
    /// gate + the Coach server-fallback) are server-mediated grants.
    var context: Context = .serverMediated
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    // T2-4 + Y8: hero icon stays mono; size lifted off the
                    // raw 32pt literal onto .hlLargeTitle so Dynamic Type
                    // scales the glyph alongside the title beside it.
                    Image(systemName: "sparkles")
                        .font(.hlLargeTitle.weight(.light))
                        .foregroundStyle(HLText.primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("Enable assistant insights")
                        .font(.hlLargeTitle)
                        .foregroundStyle(HLText.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(consentCopy)
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        bulletRow(
                            symbol: "lock.shield",
                            text: String(
                                localized: "Your name, email, and device ID are never sent."
                            )
                        )
                        if showsExternalProcessingDisclosure {
                            bulletRow(
                                symbol: "doc.viewfinder",
                                text: documentProcessingDisclosure
                            )
                            bulletRow(
                                symbol: "building.2",
                                text: recipientBulletText
                            )
                        }
                        bulletRow(
                            symbol: "arrow.uturn.backward",
                            text: String(localized: "You can disable transmission at any time in Settings → Assistant.")
                        )
                    }
                    .padding(HLSpace.md)
                    .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.md))

                    if showsExternalProcessingDisclosure {
                        legalDisclosure
                    }

                    Spacer(minLength: HLSpace.xl)
                }
                .padding(HLSpace.lg)
            }
            // v0.5.x C-9 — iOS 26+ soft scroll-edge so consent body blurs
            // into the sheet's Liquid Glass header instead of clipping cleanly.
            // iOS 18-25: no-op (system stays flat-translucent).
            .hlScrollEdgeSoft()
            .navigationTitle("Data flow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Decline", action: onDecline)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: HLSpace.sm) {
                    // v0.14.4 FW-COACH — pin the primary CTA's fill to the
                    // monochrome `HLAccent.primary` token so it matches the
                    // tint the button's WCAG label-clamp samples. Without this
                    // the fill inherited the sheet's ambient `.tint` (the
                    // AccentColor asset), which could resolve near-white in
                    // light mode → white fill under the white label
                    // (white-on-white). Pinning fill + clamped label to the
                    // same token guarantees contrast in light AND dark.
                    HLButton(
                        String(localized: "Accept"),
                        variant: .primary,
                        size: .large,
                        action: onAccept
                    )
                    .tint(HLAccent.primary)
                    Text("You can change this choice at any time in Settings.")
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

    /// G5/G6/G8 (AUDIT-onboarding) — the legal disclosure block the web privacy
    /// page asserts at the external-AI opt-in but the iOS consent sheet omitted:
    /// the third-party-LLM sub-processor identity, US data transfer, retention,
    /// the GDPR Art. 9(2)(a) explicit-consent legal basis, and a plain
    /// "your data leaves the device" notice. A server-mediated `.local`
    /// provider still leaves this device for a server/self-hosted endpoint;
    /// only a genuinely user-chosen local/on-device route omits this block.
    /// Mirrors the wording of `src/app/privacy/page.tsx`.
    private var legalDisclosure: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Label(
                String(localized: "consent.legal.leavesDevice"),
                systemImage: "iphone.and.arrow.forward"
            )
            .font(.hlFootnote.weight(.semibold))
            .foregroundStyle(HLText.primary)

            Text(subProcessorDisclosure)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "consent.legal.transferRetention"))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "consent.legal.article9"))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HLSpace.md)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.md))
        .accessibilityElement(children: .combine)
    }

    private var consentCopy: String {
        // Bug 5 (v0.14.8) — never hardcode a third-party provider name in the
        // server (External) AI path. The client cannot know which provider the
        // *server* uses (it's a server/operator concern), so the old switch that
        // asserted a concrete vendor/model was a category error. For
        // server-mediated grants the data goes to "your server", which forwards
        // it onward. A concrete provider name is only honest when the user chose
        // it themselves (BYO-key / local).
        switch context {
        case .serverMediated:
            return serverConsentCopy
        case .userChosen:
            let providerName = switch provider {
            case .anthropic: "Anthropic"
            case .openai: "OpenAI"
            case .local: String(localized: "your local LLM")
            // CU-16 — an OpenAI-compatible endpoint can be anyone's; naming a
            // company here would be an invention. The neutral wording is the
            // honest one.
            case .unconfigured, .openaiCompatible: String(localized: "your assistant provider")
            }
            return String(
                localized: "HealthLog sends excerpts of your health data — recent measurements, medications, sleep, and mood — to \(providerName) to generate personal insights."
            )
        }
    }

    /// Names the third-party LLM sub-processor. For a user-chosen provider the
    /// concrete name is honest. For a server-mediated grant the client cannot
    /// trust the onward provider name, so we disclose the sub-processor *pool*
    /// the server can forward to (named generically in the localized string,
    /// never asserted as the concrete chosen provider) — matching the privacy
    /// page's named sub-processor list.
    private var subProcessorDisclosure: String {
        switch context {
        case .serverMediated:
            return String(localized: "consent.legal.subProcessor.server")
        case .userChosen:
            let providerName = switch provider {
            case .anthropic: "Anthropic, PBC"
            case .openai: "OpenAI, L.L.C."
            case .local: String(localized: "your local LLM")
            // CU-16 — an OpenAI-compatible endpoint is NOT necessarily OpenAI.
            // Naming a legal entity we cannot identify would be a false
            // sub-processor disclosure; stay generic.
            case .unconfigured, .openaiCompatible: String(localized: "your assistant provider")
            }
            return String(
                format: String(localized: "consent.legal.subProcessor.userChosen"),
                providerName
            )
        }
    }

    /// Bug 5 (v0.14.8) — the server-mediated body copy, composed from two
    /// localized sentences so each literal stays under the line-length budget and
    /// translators get focused units. The data goes to the user's own server,
    /// which forwards it onward — never a hardcoded third-party name.
    private var serverConsentCopy: String {
        let sent =
            String(
                localized: "HealthLog sends excerpts of your health data — recent measurements, medications, sleep, and mood — to your server."
            )
        let forwarded = String(localized: "Your server forwards them to its configured AI provider to generate personal insights.")
        return sent + " " + forwarded
    }

    /// Bug 5 (v0.14.8) — the "who receives this data" bullet. Server-mediated
    /// grants name the server (the client can't trust the onward provider name);
    /// user-chosen grants name the provider the user themselves picked.
    private var recipientBulletText: String {
        switch context {
        case .serverMediated:
            String(localized: "Your server receives this data and forwards it to its AI provider under that provider's privacy policy.")
        case .userChosen:
            String(localized: "Your provider receives this data and handles it under their own privacy policy.")
        }
    }

    /// Document AI can authorize processing of substantially more data than the
    /// short metric excerpts named above. Keep that category explicit at the
    /// consent action itself, while naming the honest recipient for each route.
    private var documentProcessingDisclosure: String {
        switch context {
        case .serverMediated:
            String(localized: "consent.documentProcessing.server")
        case .userChosen:
            String(localized: "consent.documentProcessing.userChosen")
        }
    }

    private var showsExternalProcessingDisclosure: Bool {
        switch context {
        case .serverMediated:
            true
        case .userChosen:
            provider != .local
        }
    }

    private func bulletRow(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            // T2-4 + Y8: bullet symbols stay mono; size lifts off the
            // raw 16pt literal onto the .hlCallout Dynamic-Type-aware
            // token so glyph weight tracks the body copy beside it.
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
