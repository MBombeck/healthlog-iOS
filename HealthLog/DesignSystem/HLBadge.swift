import SwiftUI

public struct HLBadge: View {
    public enum Tone {
        case neutral
        case success
        case warning
        case critical
        case info
        case purple
    }

    private let title: String
    private let icon: String?
    private let tone: Tone

    public init(_ title: String, icon: String? = nil, tone: Tone = .neutral) {
        self.title = title
        self.icon = icon
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: HLSpace.xs) {
            if let icon { Image(systemName: icon).font(.hlCaption2.weight(.semibold)) }
            Text(title)
                .font(.hlCaption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, HLSpace.sm)
        .padding(.vertical, HLSpace.xs)
        .background(background.opacity(0.18))
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(title)
    }

    /// Theme-2.0 (T2-2): status semantics keep their clinical colour
    /// (success/warning/critical) because a11y depends on the green/red/
    /// yellow signal — those are NOT decorative. The decorative `.info`
    /// (cyan) and `.neutral` tones route through the mono text scale.
    ///
    /// **V0.5.4-BF-4 (accent-leak fix):** `.purple` no longer hardcodes
    /// `HLAccent.primary` (Dracula `#BD93F9`). Operator-reported v0.5.3 bug:
    /// "Kachel hat halt eine falsche Hintergrundfarbe und da hat dann
    /// automatisch dieses Lila als Akzent auch wenn wir das ja gar nicht
    /// mehr wollten" — every accent-picker switch left the HighlightInsight
    /// provider badge painting in canonical Dracula-purple regardless of
    /// the user's pick. **v0.8.0 W6:** these are `Color`-returning computed
    /// properties (non-View context), so they route through
    /// `HLAccent.userBrandTint` — the live `SettingsStore.preferredTint`
    /// resolved at read time. The prior `Color.accentColor` read the *asset
    /// catalog* AccentColor, not the live tint, so it could disagree with the
    /// rest of the app. The `purple` case name stays for source-compat — it
    /// now semantically means "uses the app's brand accent", not literally
    /// "Dracula purple".
    private var background: Color {
        switch tone {
        case .neutral, .info: HLText.secondary
        case .success: HLColor.statusOK
        case .warning: HLColor.statusWarn
        case .critical: HLColor.statusBad
        case .purple: HLAccent.userBrandTint
        }
    }

    private var foreground: Color {
        switch tone {
        case .neutral, .info: HLText.primary
        case .success: HLColor.statusOK
        case .warning: HLColor.statusWarn
        case .critical: HLColor.statusBad
        case .purple: HLAccent.userBrandTint
        }
    }
}

#Preview("HLBadge") {
    VStack(alignment: .leading, spacing: HLSpace.sm) {
        HLBadge("12 days", icon: "flame.fill", tone: .warning)
        HLBadge("In range", icon: "checkmark", tone: .success)
        HLBadge("Kritisch", tone: .critical)
        HLBadge("New", tone: .purple)
    }
    .padding()
    .background(HLSurface.primary)
}
