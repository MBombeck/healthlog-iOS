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

                HLButton("mentalHealth.result.takeAnother", variant: .secondary) {
                    store.backToChoose()
                }
                .accessibilityIdentifier("mentalHealth.result.takeAnother")
            }
        }
    }

    /// Everything that belongs to the result stands in its card: the
    /// offline note under the title (only when the result is not the server's
    /// yet; "Saved" no longer says the obvious), the score and band, the
    /// screening disclaimer where the score is read (1.0.3, App Review 1.4.1),
    /// and at the foot the required attribution with the validation paper.
    private func resultCard(_ result: MentalHealthStore.Result) -> some View {
        HLCard("mentalHealth.result.title") {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                if !result.serverDerived {
                    Text("mentalHealth.result.provisionalNote")
                        .hlText(.note)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mentalHealth.result.status")
                }
                scoreBlock(result)
                if result.showConsiderProfessional {
                    // A line of the card in body ink instead of a
                    // grey box inside it; the stronger ink keeps it noticed.
                    Text(considerKey(result))
                        .hlText(.prose)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if result.wording == .unvalidatedTranslation {
                    // Answered in HealthLog's own translation: said
                    // once, where the score is read.
                    Text("mentalHealth.wording.resultUnvalidated")
                        .hlText(.note)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mentalHealth.result.wordingNote")
                }
                Text("mentalHealth.disclaimer")
                    .hlText(.note)
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

    /// The score is the page's one key figure; the band is its status, as a
    /// capsule at the trailing edge like on every detail head. At the
    /// accessibility sizes the band moves under the score.
    private func scoreBlock(_ result: MentalHealthStore.Result) -> some View {
        HLAdaptiveStack(alignment: .top) { stacked in
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                HLCardLabel("mentalHealth.result.totalLabel")
                HLValueText(Double(result.totalScore), unit: .plain, size: .hero)
                    .accessibilityIdentifier("mentalHealth.result.totalScore")
            }
            if !stacked { Spacer(minLength: HLSpace.sm) }
            HLBadge(Self.bandLabel(instrument: result.instrument, band: result.severityBand))
        }
    }

    /// The localized band name ("Mild"), looked up as a whole key.
    nonisolated static func bandLabel(instrument: MentalHealthInstrument, band: String) -> String {
        // A plain String first: an interpolated LocalizationValue would turn
        // the parts into format arguments and miss the catalogue.
        let key = "mentalHealth.band.\(instrument.rawValue).\(band)"
        return String(localized: String.LocalizationValue(key))
    }

    private func attribution(_ result: MentalHealthStore.Result) -> some View {
        // Required source attribution — rendered VERBATIM, never translated.
        // Per-instrument: PHQ/GAD carry the Pfizer grant, WHO-5 the WHO CC notice.
        let label = Text("mentalHealth.attribution.preface").fontWeight(.semibold)
        let attribution = Text(result.instrument.attribution)
        return Text("\(label) \(attribution)")
            .hlText(.footnote)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Instrument-specific, direction-aware follow-up wording from the current
    /// web contract. Every message remains a suggestion, never a diagnosis.
    private func considerKey(_ result: MentalHealthStore.Result) -> LocalizedStringKey {
        LocalizedStringKey(Self.followUpHintKey(result.instrument))
    }

    /// The catalog key of the follow-up hint, built as a plain String first:
    /// an interpolated literal would be looked up as the format
    /// `mentalHealth.followUpHint.%@`, which the catalog does not have.
    nonisolated static func followUpHintKey(_ instrument: MentalHealthInstrument) -> String {
        "mentalHealth.followUpHint.\(instrument.keySegment)"
    }
}
