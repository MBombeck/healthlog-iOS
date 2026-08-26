import SwiftUI

/// **A360-1 M2 — discreet "Learn more" pointer to a public `/learn` guide.**
///
/// One small, calm anchor (no new colour, no card chrome) that links a concept
/// out to its plain-language guide. The iOS mirror of the server's
/// `<LearnMoreLink>` React component (`src/components/ui/learn-more-link.tsx`).
///
/// Fail-closed by construction:
///   - the href is resolved through ``HLLearnLinks/guide(forConcept:)`` — a
///     closed-set, registry-backed URL, never user/model content — so there is
///     no injection surface and no invented link;
///   - an unmapped concept resolves to `nil` and the view renders nothing, so a
///     surface that wires a concept with no guide simply shows no pointer.
///
/// It is a SwiftUI ``Link`` to the public guide URL (opens in Safari) — NOT an
/// in-app `WKWebView` rendering untrusted content (A360-3 security constraint).
/// The accessible label is "Learn more: <guide title>".
struct HLLearnMoreLink: View {
    /// A concept key — a ``MetricKind`` `rawValue` or a concept-shaped key
    /// (e.g. `"RESILIENCE"`, `"LAB_BIOMARKER"`). Anything unmapped renders
    /// nothing.
    let concept: String

    var body: some View {
        if let guide = HLLearnLinks.guide(forConcept: concept) {
            Link(destination: guide.url) {
                HStack(spacing: HLSpace.xxs) {
                    Text("common.learnMore")
                    Image(systemName: "arrow.up.right")
                        .font(.hlCaption2)
                        .accessibilityHidden(true)
                }
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            }
            .accessibilityIdentifier("learnMore.\(guide.slug)")
            .accessibilityLabel(
                Text("learnMore.a11y \(guide.title)")
            )
        }
    }
}
