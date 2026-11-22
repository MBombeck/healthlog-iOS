import SwiftUI

/// Per QA3 BLOCKER 2 — Apple Guideline 5.1.2(i) (Nov 2025): before sending
/// health data to a remote LLM, present an informed-consent sheet ONCE per
/// provider change. Sheet copy enumerates the data flow, the anonymisation
/// promise, and the revoke path.
struct AIConsentSheet: View {
    /// Bug 5 — distinguishes WHICH data-flow this consent governs so
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
    /// The operator-held services the server names in
    /// `ai.consent.recipients` while it reports `needed` (`OpenAI`,
    /// `Anthropic`, an endpoint host). When present, the server-mediated copy
    /// names them as where the data goes instead of "its AI provider".
    var recipients: [String] = []
    let onAccept: () -> Void
    let onDecline: () -> Void

    /// A required decision in the sheet frame: the decision is the title,
    /// the X at the leading edge declines like the "Decline" button beside
    /// "Accept", and swiping down is locked so no answer is skipped.
    var body: some View {
        HLSheetScaffold("Enable assistant insights", onClose: onDecline) {
            HLPage {
                Text(consentCopy)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        HLIconTextRow(
                            icon: "lock.shield",
                            verbatim: String(
                                localized: "Your name, email, and device ID are never sent."
                            )
                        )
                        if showsExternalProcessingDisclosure {
                            HLIconTextRow(
                                icon: "doc.viewfinder",
                                verbatim: documentProcessingDisclosure
                            )
                            HLIconTextRow(
                                icon: "building.2",
                                verbatim: recipientBulletText
                            )
                        }
                        HLIconTextRow(
                            icon: "arrow.uturn.backward",
                            verbatim: String(localized: "You can disable transmission at any time in Settings → Assistant.")
                        )
                    }
                }

                if showsExternalProcessingDisclosure {
                    legalDisclosure
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

    /// G5/G6/G8 (AUDIT-onboarding) — the legal disclosure block the web privacy
    /// page asserts at the external-AI opt-in but the iOS consent sheet omitted:
    /// the third-party-LLM sub-processor identity, US data transfer, retention,
    /// the GDPR Art. 9(2)(a) explicit-consent legal basis, and a plain
    /// "your data leaves the device" notice. A server-mediated `.local`
    /// provider still leaves this device for a server/self-hosted endpoint;
    /// only a genuinely user-chosen local/on-device route omits this block.
    /// Mirrors the wording of `src/app/privacy/page.tsx`.
    private var legalDisclosure: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Label(
                    String(localized: "consent.legal.leavesDevice"),
                    systemImage: "iphone.and.arrow.forward"
                )
                .font(.hlFootnote.weight(.semibold))
                .foregroundStyle(HLText.primary)

                Text(subProcessorDisclosure)
                    .hlText(.rowSubtitle)
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(localized: "consent.legal.transferRetention"))
                    .hlText(.rowSubtitle)
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(localized: "consent.legal.article9"))
                    .hlText(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var consentCopy: String {
        // Bug 5 — never hardcode a third-party provider name in the
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
            // An OpenAI-compatible endpoint can be anyone's; naming a
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
            if let names = recipientList {
                return String(format: String(localized: "consent.legal.subProcessor.userChosen"), names)
            }
            return String(localized: "consent.legal.subProcessor.server")
        case .userChosen:
            let providerName = switch provider {
            case .anthropic: "Anthropic, PBC"
            case .openai: "OpenAI, L.L.C."
            case .local: String(localized: "your local LLM")
            // An OpenAI-compatible endpoint is NOT necessarily OpenAI.
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

    /// Bug 5 — the server-mediated body copy, composed from two
    /// localized sentences so each literal stays under the line-length budget and
    /// translators get focused units. The data goes to the user's own server,
    /// which forwards it onward — never a hardcoded third-party name.
    private var serverConsentCopy: String {
        let sent =
            String(
                localized: "HealthLog sends excerpts of your health data — recent measurements, medications, sleep, and mood — to your server."
            )
        let forwarded = if let names = recipientList {
            String(format: String(localized: "consent.recipients.forwarded"), names)
        } else {
            String(localized: "Your server forwards them to its configured AI provider to generate personal insights.")
        }
        return sent + " " + forwarded
    }

    /// The server-named recipients as one locale-formatted list
    /// ("OpenAI und Anthropic"), `nil` when the server named none.
    private var recipientList: String? {
        let names = recipients.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return names.formatted(.list(type: .and))
    }

    /// Bug 5 — the "who receives this data" bullet. Server-mediated
    /// grants name the server (the client can't trust the onward provider name);
    /// user-chosen grants name the provider the user themselves picked.
    private var recipientBulletText: String {
        switch context {
        case .serverMediated:
            if let names = recipientList {
                String(format: String(localized: "consent.recipients.bullet"), names)
            } else {
                String(localized: "Your server receives this data and forwards it to its AI provider under that provider's privacy policy.")
            }
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
}
