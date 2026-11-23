import SwiftUI

/// "Show more" / "Show fewer" under a capped list of a mood card: the app's
/// centred text link with the turning chevron, so every mood card opens and
/// closes its list the same way.
struct MoodShowMoreLink: View {
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HLLinkButton(isExpanded ? "mood.list.showFewer" : "mood.list.showMore", isExpanded: isExpanded) {
            withAnimation(reduceMotion ? nil : HLMotion.spring) { isExpanded.toggle() }
        }
    }
}
