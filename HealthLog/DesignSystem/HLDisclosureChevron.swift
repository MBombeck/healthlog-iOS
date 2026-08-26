import SwiftUI

/// The ONE canonical trailing disclosure chevron (W6-3 / STANDARDS §3).
///
/// Before this primitive the same `chevron.right` disclosure affordance was
/// hand-rolled at three different fixed point sizes (13pt ×17, 14pt ×2,
/// 11pt ×1) across ~20 manual rows — even though
/// `HLListRow` already owns the canonical trailing chevron
/// (`.font(.hlFootnote.weight(.semibold))` + `HLText.tertiary`) and
/// `HLSettingsRow` delegates its chevron to `NavigationLink`.
///
/// `HLDisclosureChevron` codifies that canonical treatment as a token so any
/// manual row that can't go through `NavigationLink`/`HLSettingsRow` still
/// renders the identical disclosure glyph: `.hlFootnote.weight(.semibold)`,
/// `HLText.tertiary`, marked `.accessibilityHidden` because the row's own
/// label + the `NavigationLink` semantics carry the affordance to VoiceOver.
///
/// Audit-01 H1 extensions:
/// - `expanded` renders the SAME token as an expand/collapse indicator
///   (`chevron.down` when expanded) so expander rows share the disclosure
///   language instead of hand-rolling a second glyph recipe.
/// - `tint` overrides the ink for sanctioned on-scrim hero moments (e.g. the
///   Coach AI-hero CTA pill, `HLColor.aiHeroInk`) where `HLText.tertiary`
///   would vanish on the dark gradient. Leave `nil` everywhere else.
struct HLDisclosureChevron: View {
    var expanded: Bool?
    var tint: Color?

    init(expanded: Bool? = nil, tint: Color? = nil) {
        self.expanded = expanded
        self.tint = tint
    }

    var body: some View {
        Image(systemName: expanded == true ? "chevron.down" : "chevron.right")
            .font(.hlFootnote.weight(.semibold))
            .foregroundStyle(tint ?? HLText.tertiary)
            .accessibilityHidden(true)
    }
}

#Preview("HLDisclosureChevron") {
    VStack(spacing: HLSpace.md) {
        HStack {
            Text("Export")
                .font(.hlBody)
            Spacer()
            HLDisclosureChevron()
        }
        HStack {
            Text("Account")
                .font(.hlBody)
            Spacer()
            HLDisclosureChevron()
        }
    }
    .padding()
    .background(HLSurface.primary)
}
