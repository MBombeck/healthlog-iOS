import SwiftUI

/// The result phase: one card with the total score + severity band (a
/// descriptive screen label, never a diagnosis), the gentle "consider a
/// professional" note when `totalScore >= actionThreshold`, the screening
/// disclaimer and the verbatim attribution with its Sources link; then — iff the
/// item-9 flag is set — the ``MentalHealthCrisisCard`` immediately below, and a
/// "take another check-in" action.
///
/// SAFETY: the crisis card here renders strictly from ``MentalHealthStore/Result``
/// (server-driven when online, bundled fallback when the upload failed / the
/// server omitted the set) — it appears even on an offline submit.
struct MentalWellbeingResult: View {
    @Bindable var store: MentalHealthStore

    var body: some View {
        if let result = store.result {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                resultCard(result)

                if let crisis = result.crisis {
                    // SAFETY — item-9 crisis card, gated strictly on the flag.
                    MentalHealthCrisisCard(crisis: crisis)
                        .accessibilityIdentifier("mentalHealth.crisisCard")
                }

                HLButton(String(localized: "mentalHealth.result.takeAnother"), variant: .secondary) {
                    store.backToChoose()
                }
                .accessibilityIdentifier("mentalHealth.result.takeAnother")
            }
        }
    }

    /// 1.4 B2 — everything that belongs to the result stands in its card: the
    /// offline note under the title (only when the result is not the server's
    /// yet; "Saved" no longer says the obvious), the score and band, the
    /// screening disclaimer where the score is read (1.0.3, App Review 1.4.1),
    /// and at the foot the required attribution with the validation paper.
    private func resultCard(_ result: MentalHealthStore.Result) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text("mentalHealth.result.title")
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    if !result.serverDerived {
                        Text("mentalHealth.result.provisionalNote")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("mentalHealth.result.status")
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("mentalHealth.result.totalLabel")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                    Spacer()
                    Text("\(result.totalScore)")
                        .font(.hlTitle2)
                        .foregroundStyle(HLText.primary)
                        .accessibilityIdentifier("mentalHealth.result.totalScore")
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("mentalHealth.result.bandLabel")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                    Spacer()
                    Text(bandKey(result))
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                }
                if result.showConsiderProfessional {
                    // 1.4 B4 — a line of the card in body ink instead of a
                    // grey box inside it; the stronger ink keeps it noticed.
                    Text(considerKey(result))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("mentalHealth.disclaimer")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mentalHealth.result.disclaimer")
                VStack(alignment: .leading, spacing: 0) {
                    attribution(result)
                    // 1.0.3 (1.4.1) — the validation paper behind this instrument.
                    HLSourcesLink(topic: .mentalHealth(result.instrument))
                }
            }
        }
    }

    private func attribution(_ result: MentalHealthStore.Result) -> some View {
        // Required source attribution — rendered VERBATIM, never translated.
        // Per-instrument: PHQ/GAD carry the Pfizer grant, WHO-5 the WHO CC notice.
        (Text(LocalizedStringKey("mentalHealth.attributionLabel")).font(.hlCaption2.weight(.semibold)) +
            Text(": ").font(.hlCaption2) +
            Text(result.instrument.attribution).font(.hlCaption2))
            .foregroundStyle(HLText.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Instrument-specific, direction-aware follow-up wording from the current
    /// web contract. Every message remains a suggestion, never a diagnosis.
    private func considerKey(_ result: MentalHealthStore.Result) -> LocalizedStringKey {
        LocalizedStringKey("mentalHealth.followUpHint.\(result.instrument.keySegment)")
    }

    private func bandKey(_ result: MentalHealthStore.Result) -> LocalizedStringKey {
        // Resolve the dotted key as a plain String first, then wrap — so the lookup
        // key is `mentalHealth.band.PHQ9.moderate`, not the `…%@` format string.
        let key = "mentalHealth.band.\(result.instrument.rawValue).\(result.severityBand)"
        return LocalizedStringKey(key)
    }
}
