import SwiftUI

/// **1.0.3 (App Review 1.4.1) — the guideline caption that cites itself.**
///
/// A status card's guideline caption ("ESH 2023", "WHO 2000") already names the
/// authority a classification rests on; it was just inert text. This makes the
/// caption itself the way into ``HLSourcesSheet`` — the affordance sits exactly
/// where the claim is made, instead of a second "Sources" control repeating the
/// same thing a line below.
///
/// All the button chrome, the accessibility label and the identifier come from
/// ``HLSourcesLink``: there is ONE citation control in the app, and this is the
/// caption-shaped way of asking for it. What is left here is the fallback —
/// a caption whose topic the catalog does not know (or that has no topic at
/// all) stays plain text, so it never advertises an empty sheet and never
/// disappears either.
struct HLSourcesGuidelineCaption: View {
    /// The guideline name, already localized by the caller.
    let caption: String
    /// The citation topic behind the guideline. `nil` → plain text.
    let topic: MedicalSourceTopic?

    var body: some View {
        if let topic, HLSourcesLink.isRenderable(topic) {
            HLSourcesLink(topic: topic, style: .captionText(caption))
        } else {
            Text(verbatim: caption)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
        }
    }
}
