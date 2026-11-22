import SwiftUI

public struct HLButton: View {
    /// Three variants with clear occasions:
    ///
    /// - `.primary`: at most one per screen, the action that completes a flow.
    /// - `.secondary`: a full-width action beside a primary one, and the retry
    ///   of an error state.
    /// - `.destructive`: the destructive commit on the screen that confirms it.
    ///   The outline of the secondary button with red words and a red symbol.
    ///   It has no red surface: a destructive action is not drawn as the
    ///   emphasised main action.
    ///
    /// ``standard`` lists them. ``retired`` lists the two that still draw for
    /// existing call sites and take no new ones: what was `.ghost` becomes an
    /// ``HLLinkButton``, what was `.restrained` becomes `.secondary` or a row.
    public enum Variant: CaseIterable, Sendable {
        case primary
        case secondary
        /// Retired. Use ``HLLinkButton``.
        case ghost
        case destructive
        /// Retired. No fill, a hairline, a monochrome label, 44 pt high: the
        /// calm in-card action. Use `.secondary` or a row instead.
        case restrained

        /// The variants a screen chooses from.
        public static let standard: [Variant] = [.primary, .secondary, .destructive]
        /// Variants kept only for call sites that have not moved yet.
        public static let retired: [Variant] = [.ghost, .restrained]
    }

    /// Height classes of the older initialisers. New code passes no size: a
    /// button is ``HLLayout/buttonHeight`` high, and onboarding asks for its
    /// larger one with `hlOnboardingSize()`.
    public enum Size: Sendable {
        case regular
        case compact
        case large
    }

    /// Pure, test-visible description of the load-bearing restraint contract
    /// of the `.restrained` variant — so the W-BUTTONS regression (an
    /// accidental re-inflation back to a `.tint`-filled / oversized CTA) is
    /// locked without introspecting the SwiftUI body. Mirrors the
    /// `MedicationQuickMarkState.PresentationDescriptor` pattern used across
    /// the design-system snapshot suite.
    public struct RestrainedContract: Equatable, Sendable {
        /// The variant paints NO background fill (vs `.primary`'s `.tint` slab).
        public let hasFill: Bool
        /// The label ink is monochrome `HLText.secondary` — never an accent
        /// (B2: restrained CTAs must not carry accent).
        public let monochromeLabel: Bool
        /// Compact 44pt HIG floor regardless of any passed `size`.
        public let minHeight: CGFloat
    }

    /// The canonical restrained contract — the single source of truth the
    /// body's `background` / `textForegroundStyle` / `minHeight` honour for
    /// `.restrained`, and the value the W-BUTTONS test pins.
    public nonisolated static let restrainedContract = RestrainedContract(
        hasFill: false,
        monochromeLabel: true,
        minHeight: 44
    )

    /// The label, shared by the visible button and VoiceOver. Resolved through
    /// the catalog by the key initialisers and taken as it is by
    /// `HLButton(verbatim:)`, so runtime text never gets a second lookup.
    private let titleText: Text
    /// The same title as plain words, where they can be known: the largest
    /// sizes wrap it between words only (``HLWholeWordText``). `nil` for a
    /// `Text` title.
    private var titleWords: String?
    private let icon: String?
    private let variant: Variant
    private let size: Size
    private let isLoading: Bool
    private let action: () -> Void
    /// Push form (`destination:`): the button builds the `NavigationLink`
    /// itself and pushes onto the enclosing `NavigationStack`. `nil` for the
    /// action forms.
    private let destination: AnyView?

    /// Test-visible: whether this button pushes a destination (the
    /// `destination:` form) rather than running an action.
    public var pushesDestination: Bool {
        destination != nil
    }

    /// v0.5.5.1 haptic migration: replaces the legacy
    /// `UIImpactFeedbackGenerator(style: .light).impactOccurred()` with
    /// iOS 17+'s declarative `.sensoryFeedback(.selection, trigger:)`.
    /// SwiftUI manages prepare-and-fire lifecycle internally + honours
    /// Reduce-Motion / per-app haptic settings, so the migration drops
    /// the UIKit dependency from the standard button tap.
    @State private var tapCount: Int = 0

    /// The standard button: a catalog key, an optional symbol, one of the
    /// three variants. Height, radius, font and colours are not the caller's.
    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        variant: Variant = .primary,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        titleText = Text(title)
        titleWords = HLLocalizedKey.string(title)
        icon = systemImage
        self.variant = variant
        size = .regular
        self.isLoading = isLoading
        self.action = action
        destination = nil
    }

    /// The standard button for a title that exists only at run time: a name
    /// the user typed, a figure with its unit.
    public init(
        _ title: Text,
        systemImage: String? = nil,
        variant: Variant = .primary,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        titleText = title
        icon = systemImage
        self.variant = variant
        size = .regular
        self.isLoading = isLoading
        self.action = action
        destination = nil
    }

    /// The standard button as a push: it is the `NavigationLink` itself and
    /// puts `destination` onto the enclosing stack, so the page around it
    /// keeps no presenter for it. Name the closure: an unnamed one after
    /// the call reads as an action.
    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        variant: Variant = .primary,
        destination: () -> some View
    ) {
        self.init(Text(title), systemImage: systemImage, variant: variant, destination: destination)
        titleWords = HLLocalizedKey.string(title)
    }

    /// The push for a title that exists only at run time.
    public init(
        _ title: Text,
        systemImage: String? = nil,
        variant: Variant = .primary,
        destination: () -> some View
    ) {
        titleText = title
        icon = systemImage
        self.variant = variant
        size = .regular
        isLoading = false
        action = {}
        self.destination = AnyView(destination())
    }

    /// Standard initializer — `title` is treated as a **localization key**
    /// and resolved through the string catalog at render time via
    /// `LocalizedStringKey`. Pass a catalog id (`"allergies.add.title"`) or
    /// an English source literal (`"Save"`); both resolve to their catalog
    /// translation (or echo verbatim when no entry exists — non-breaking).
    /// For an already-resolved dynamic string, use `HLButton(verbatim:)`.
    public init(
        _ title: String,
        icon: String? = nil,
        variant: Variant,
        size: Size = .regular,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        titleText = Text(LocalizedStringKey(title))
        titleWords = HLLocalizedKey.string(forKey: title)
        self.icon = icon
        self.variant = variant
        self.size = size
        self.isLoading = isLoading
        self.action = action
        destination = nil
    }

    /// Verbatim initializer — `title` is painted **as-is**, with no catalog
    /// lookup. Use for dynamic/user/server text that is already localized or
    /// carries runtime data (a medication or provider name, an interpolated
    /// count) so it is never re-resolved against the string catalog.
    public init(
        verbatim title: String,
        icon: String? = nil,
        variant: Variant,
        size: Size = .regular,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        titleText = Text(verbatim: title)
        titleWords = title
        self.icon = icon
        self.variant = variant
        self.size = size
        self.isLoading = isLoading
        self.action = action
        destination = nil
    }

    /// Push initializer — same look as the action form, but the button is a
    /// `NavigationLink` that pushes `destination` onto the enclosing
    /// `NavigationStack`. The call site then carries no presenter of its own
    /// (`.navigationDestination`): the push lives in this shared primitive,
    /// the way `HLSettingsActionRow(presents: .push)` carries a row's push.
    public init(
        _ title: String,
        icon: String? = nil,
        variant: Variant,
        size: Size = .regular,
        destination: () -> some View
    ) {
        titleText = Text(LocalizedStringKey(title))
        titleWords = HLLocalizedKey.string(forKey: title)
        self.icon = icon
        self.variant = variant
        self.size = size
        isLoading = false
        action = {}
        self.destination = AnyView(destination())
    }

    public var body: some View {
        if let destination {
            NavigationLink { destination } label: { label }
                .buttonStyle(PressedScaleStyle())
                .simultaneousGesture(TapGesture().onEnded { tapCount &+= 1 })
                .sensoryFeedback(.selection, trigger: tapCount)
                .accessibilityLabel(titleText)
        } else {
            Button(action: triggerHaptic) { label }
                .buttonStyle(PressedScaleStyle())
                .sensoryFeedback(.selection, trigger: tapCount)
                .accessibilityLabel(titleText)
        }
    }

    private var label: HLButtonLabel {
        HLButtonLabel(title: titleText, words: titleWords, icon: icon, variant: variant, size: size, isLoading: isLoading)
    }

    /// Smallest scale a title shrinks to before it may wrap.
    static let titleMinimumScale: CGFloat = 0.8
    /// Lines a title of several words may take once it wraps.
    static let wrappedTitleLines = 3

    private func triggerHaptic() {
        guard !isLoading else { return }
        tapCount &+= 1
        action()
    }

    /// The height of a button. A retired `.restrained` button stays at the
    /// hit-target floor whatever size it is given, so it cannot grow back
    /// into a slab.
    public nonisolated static func height(
        variant: Variant = .primary,
        size: Size = .regular,
        onboarding: Bool = false
    ) -> CGFloat {
        if variant == .restrained { return restrainedContract.minHeight }
        if onboarding { return HLLayout.onboardingButtonHeight }
        switch size {
        case .compact: return HLHitTarget.minimum
        case .regular: return HLLayout.buttonHeight
        case .large: return HLLayout.onboardingButtonHeight
        }
    }
}

private struct PressedScaleStyle: ButtonStyle {
    // Gate the press micro-shrink on Reduce Motion to match
    // `HLPressableButtonStyle.scale(for:)`. The haptic/opacity stay; only the
    // 0.97 scale jump is suppressed so the two canonical press primitives no
    // longer diverge.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .hlAnimation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct HLButtonOnboardingSizeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `true` where buttons take the larger onboarding height.
    var hlButtonOnboardingSize: Bool {
        get { self[HLButtonOnboardingSizeKey.self] }
        set { self[HLButtonOnboardingSizeKey.self] = newValue }
    }
}

public extension View {
    /// Gives the buttons below the larger onboarding height. Onboarding is
    /// the one place that uses it.
    func hlOnboardingSize() -> some View {
        environment(\.hlButtonOnboardingSize, true)
    }
}

#Preview("HLButton, light") {
    HLButtonPreview()
        .preferredColorScheme(.light)
}

#Preview("HLButton, dark") {
    HLButtonPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLButton, largest type") {
    HLButtonPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLButtonPreview: View {
    var body: some View {
        HLPage {
            HLButton(HLControlWord.save.key, systemImage: "checkmark") {}
            HLButton(HLControlWord.retry.key, variant: .secondary) {}
            HLButton(HLControlWord.delete.key, systemImage: "trash", variant: .destructive) {}
            HLButton(HLControlWord.save.key, isLoading: true) {}
            HLButton(HLControlWord.add.key) {}
                .hlOnboardingSize()
            HLLinkButton("Edit") {}
        }
    }
}
