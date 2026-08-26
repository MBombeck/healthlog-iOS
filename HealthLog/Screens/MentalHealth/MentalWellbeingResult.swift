import SwiftUI

/// The result phase: a "saved" status, the total score + severity band (a
/// descriptive screen label, never a diagnosis), the gentle "consider a
/// professional" note when `totalScore >= actionThreshold`, then — iff the item-9
/// flag is set — the ``MentalHealthCrisisCard`` immediately below. The verbatim
/// Pfizer attribution footnote, and a "take another check-in" action close it out.
///
/// SAFETY: the crisis card here renders strictly from ``MentalHealthStore/Result``
/// (server-driven when online, bundled fallback when the upload failed / the
/// server omitted the set) — it appears even on an offline submit.
struct MentalWellbeingResult: View {
    @Bindable var store: MentalHealthStore

    var body: some View {
        if let result = store.result {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Text(result.serverDerived ? "mentalHealth.saved" : "mentalHealth.result.provisionalNote")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mentalHealth.result.status")

                resultCard(result)

                if let crisis = result.crisis {
                    // SAFETY — item-9 crisis card, gated strictly on the flag.
                    MentalHealthCrisisCard(crisis: crisis)
                        .accessibilityIdentifier("mentalHealth.crisisCard")
                }

                attribution(result)

                HLButton(String(localized: "mentalHealth.result.takeAnother"), variant: .secondary) {
                    store.backToChoose()
                }
                .accessibilityIdentifier("mentalHealth.result.takeAnother")
            }
        }
    }

    private func resultCard(_ result: MentalHealthStore.Result) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Text("mentalHealth.result.title")
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
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
                    Text(considerKey(result))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(HLSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
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
