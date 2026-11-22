import SwiftUI

/// **v1.18.6 — one-time medical-disclaimer acknowledgment.**
///
/// Replaces the scattered per-screen / per-chart "this is not medical advice"
/// banners app-wide. The user confirms ONCE, and this sheet blocks the app
/// until they do — jede Fläche dahinter ist also nur nach der Bestätigung
/// erreichbar.
///
/// **UI-Standard R15:** daraus folgt die eigentliche Vereinfachung. Der
/// Pauschaltext hat genau ZWEI Orte — dieses Sheet und die Disclaimer-Karte
/// unter Einstellungen → Über diese App (Apple 1.4.1). Auf keiner anderen
/// Fläche steht er. Der Zwischenschritt von v1.18.6, die verstreuten Hinweise
/// an einen `\.medicalDisclaimerAcknowledged`-Schalter zu hängen, ist damit
/// erledigt: `briefing.disclaimer` und die beiden Illness-Rückblick-Fußzeilen
/// sind ersatzlos gefallen, `correlations.disclaimer` und
/// `insights.bp.derived.caveat` sind auf ihre Zuschreibung gekürzt — und
/// der Schalter selbst ist mit ihnen verschwunden.
///
/// Der Fertilitäts-Vorbehalt (`cycle.prediction.disclaimer.local`) war nie an
/// diesem Schalter und bleibt unangetastet: „keine Verhütung" ist eine
/// konkrete Aussage über eine konkrete Fehlnutzung, kein Pauschaltext.
///
/// **Persistence is SERVER-OWNED.** `acknowledge()` posts
/// `POST /api/onboarding/disclaimer { version }`; the server stamps
/// `User.disclaimerAcknowledgedAt`. iOS never caches "acknowledged" locally.
///
/// **Copy reuses the App-Store-approved `appstore.disclaimer.*` strings** — the
/// same wording that lives permanently in Settings → About → "Not a Medical
/// Device", so the legal substance is consolidated here, not lost.
struct MedicalDisclaimerAckSheet: View {
    /// Posts the acknowledgment. The host (`RootView`) wires this to
    /// `DisclaimerAckStore.acknowledge()`. The sheet stays up on error.
    let onAcknowledge: () async -> Void
    /// `true` while the POST is in flight (driven by the store).
    let isSubmitting: Bool
    /// Non-nil when the last acknowledgment attempt failed — the sheet shows a
    /// retry-able error and stays presented.
    let errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.xl) {
                    intro
                    section(
                        title: "appstore.disclaimer.card_title",
                        body: "appstore.disclaimer.not_for_diagnosis"
                    )
                    section(
                        title: "disclaimer.ack.observations.title",
                        body: "appstore.disclaimer.methodology"
                    )
                    section(
                        title: "disclaimer.ack.consult.title",
                        body: "appstore.disclaimer.consult_doctor"
                    )
                    sourcesPointer
                    Text("appstore.disclaimer.footer")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let errorMessage {
                        errorBanner(message: errorMessage)
                    }
                    Spacer(minLength: HLSpace.lg)
                }
                .padding()
            }
            .hlScreenBackground()
            .navigationTitle(Text("disclaimer.ack.nav.title"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
            .hlBottomBar {
                HLButton(
                    String(localized: "disclaimer.ack.cta"),
                    icon: "checkmark.circle.fill",
                    variant: .primary,
                    size: .large,
                    isLoading: isSubmitting
                ) {
                    Task { await onAcknowledge() }
                }
                .accessibilityIdentifier("disclaimer.ack.confirm")
            }
        }
    }

    private var intro: some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.hlTitle2.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                        .accessibilityHidden(true)
                    Text("disclaimer.ack.intro.title")
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                }
                Text("disclaimer.ack.intro.body")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 1.0.3 (App Review 1.4.1) — the reviewer's first screen points at the hub.
    private var sourcesPointer: some View {
        HLCard("disclaimer.ack.sources.title", style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("disclaimer.ack.sources.body")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The sources are a page of their own: a menu row with its
                // chevron, the whole row the link.
                HLRow("disclaimer.ack.sources.cta", accessory: .chevron) {
                    HLRowGlyph(symbol: "text.book.closed")
                }
                .hlRowLink {
                    MedicalSourcesScreen()
                }
                .accessibilityIdentifier("disclaimer.ack.sourcesLink")
            }
        }
    }

    private func section(title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text(title)
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                .accessibilityAddTraits(.isHeader)
            Text(body)
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HLColor.statusBad)
            Text(message)
                .font(.hlSubhead)
                .foregroundStyle(HLColor.statusBad)
        }
        .padding(HLSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HLRadius.button, style: .continuous)
                .fill(HLColor.statusBad.opacity(HLOpacity.surfaceTintWeak))
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview("Medical Disclaimer Ack") {
    Color.clear.sheet(isPresented: .constant(true)) {
        MedicalDisclaimerAckSheet(
            onAcknowledge: {},
            isSubmitting: false,
            errorMessage: nil
        )
    }
}
