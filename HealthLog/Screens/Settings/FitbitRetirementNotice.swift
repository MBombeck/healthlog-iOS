import SwiftUI

/// The Fitbit card's account of the turndown: Google turned
/// the Fitbit Web API off (or is about to), the imported data stays, and Google
/// Health reads the same devices. Plain lines inside the existing card, no new
/// badge; the guide is a quiet text link.
struct FitbitRetirementNotice: View {
    let retirement: FitbitRetirement

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text(verbatim: retirement.notice)
                .hlText(.prose)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("integration.fitbit.retired.notice")
            Text("integration.fitbit.retired.dataStays")
                .hlText(.rowSubtitle)
                .fixedSize(horizontal: false, vertical: true)
            if retirement.pointsToGoogleHealth, let guide = FitbitRetirement.googleHealthGuideURL {
                HLTextLink("integration.fitbit.retired.guide", destination: guide)
                    .font(.hlCaption)
                    .accessibilityHint(Text("integration.fitbit.retired.guide.hint"))
                    .accessibilityIdentifier("integration.fitbit.retired.guide")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
