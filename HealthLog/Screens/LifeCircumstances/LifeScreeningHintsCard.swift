import SwiftUI

/// The screening hints the server derives from the life
/// circumstances (low-dose CT for lung cancer, ultrasound of the abdominal
/// aorta), each with its status, the server's reasons and the rule it comes
/// from, linked. A hint, never a reminder and never advice: nothing here is
/// worded by the app, and a reason key without the server's wording is left
/// out rather than paraphrased.
struct LifeScreeningHintsCard: View {
    let hints: [LifeDerived.ScreeningHint]

    var body: some View {
        HLCard("life.screening.cardTitle", footer: "life.screening.noReminder") {
            ForEach(hints) { hint in
                hintRow(hint)
            }
        }
        .accessibilityIdentifier("life.screening")
    }

    private func hintRow(_ hint: LifeDerived.ScreeningHint) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            // Whole words only: "Niedrigdosis-CT" broke into "Niedrig-/dosis-CT".
            HLWholeWordText(LifeCopy.screeningTitle(hint.id), font: .hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            Text(verbatim: LifeCopy.screeningStatus(hint.status))
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(hint.reasonKeys.compactMap(LifeCopy.screeningReason), id: \.self) { reason in
                Text(verbatim: reason)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LifeSourceLink(label: hint.sourceLabel, url: hint.sourceURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("life.screening.\(hint.id.rawValue)")
    }
}
