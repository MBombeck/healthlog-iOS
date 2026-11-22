import SwiftUI

public struct HLBadge: View {
    public enum Tone: Equatable, Sendable {
        case neutral
        case success
        case warning
        case critical
        case info
        case purple
    }

    /// How the status is drawn. The place decides, not the meaning: in a
    /// row and next to a value a status is text, so it stays quieter than
    /// the value; a capsule belongs to a card head, a detail head and to
    /// tags.
    public enum Form: Equatable, Sendable {
        /// A tinted capsule: 12 pt semibold.
        case capsule
        /// Symbol and text without a capsule: symbol 11 pt semibold, text
        /// 12 pt medium.
        case text

        public var titleFont: Font {
            switch self {
            case .capsule: .hlCaption.weight(.semibold)
            case .text: .hlCaption.weight(.medium)
            }
        }

        public var iconFont: Font {
            .hlCaption2.weight(.semibold)
        }
    }

    private let title: String
    private let icon: String?
    private let tone: Tone
    private let form: Form

    public init(_ title: String, icon: String? = nil, tone: Tone = .neutral, form: Form = .capsule) {
        self.title = title
        self.icon = icon
        self.tone = tone
        self.form = form
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public var body: some View {
        switch form {
        case .capsule: capsule
        case .text: plain
        }
    }

    /// The badge wraps between words, and at an
    /// accessibility size the capsule becomes a rounded rectangle so two
    /// lines still read as one badge. It takes no layout priority over the
    /// text beside it: a large value next to it (a lab result) would be the
    /// one squeezed then. Where both cannot share a line, the caller stacks
    /// them at the accessibility sizes (lab card, episode header, assistant
    /// status).
    private var capsule: some View {
        label
            .foregroundStyle(foreground)
            .padding(.horizontal, HLSpace.sm)
            .padding(.vertical, HLSpace.xs)
            .background(background.opacity(0.18))
            .clipShape(
                dynamicTypeSize.isAccessibilitySize
                    ? AnyShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                    : AnyShape(Capsule())
            )
            .accessibilityElement()
            .accessibilityLabel(title)
    }

    /// The status as a line of text. Neutral reads in secondary ink; only
    /// the status tones keep their colour.
    private var plain: some View {
        label
            .foregroundStyle(textForeground)
            .accessibilityElement()
            .accessibilityLabel(title)
    }

    private var label: some View {
        // A capsule centres its symbol; a status line keeps symbol and text
        // on one baseline like the value above it.
        HStack(alignment: form == .text ? .firstTextBaseline : .center, spacing: HLSpace.xs) {
            if let icon { Image(systemName: icon).font(form.iconFont) }
            Text(title)
                .font(form.titleFont)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var textForeground: Color {
        switch tone {
        case .neutral, .info: HLText.secondary
        case .success, .warning, .critical, .purple: foreground
        }
    }

    /// Theme-2.0: status semantics keep their clinical colour
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
        HLBadge("Critical", tone: .critical)
        HLBadge("New", tone: .purple)
        HLBadge("Above range", icon: "arrow.up", tone: .warning, form: .text)
        HLBadge("In range", icon: "checkmark", tone: .success, form: .text)
        HLBadge("Not connected", icon: "circle.slash", form: .text)
    }
    .padding()
    .background(HLSurface.primary)
}
