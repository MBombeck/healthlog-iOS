import SwiftUI

/// The ONE canonical empty-state lockup.
///
/// Before this primitive the app spoke two empty-state languages: ~20 screens
/// used the system `ContentUnavailableView` (system title2-bold + body, system
/// gray) while ~7 screens hand-rolled a VStack lockup with a raw
/// `.font(.largeTitle)` icon — visibly different sizes, colours and rhythm
/// ("wer durch die Tabs wischt, sieht zwei Apps"). `HLEmptyState` codifies the
/// single canonical treatment on the design-system scale:
///
/// - **Glyph:** `.hlIcon(HLIconSize.hero, weight: .medium)` + `HLText.tertiary`
///   (pixel-locked per the sanctioned glyph doctrine in `Tokens.swift`).
/// - **Title:** `.hlHeadline` + `HLText.primary`, marked `.isHeader`.
/// - **Message:** `.hlSubhead` + `HLText.secondary`, centered, wraps freely.
/// - **Actions:** optional `@ViewBuilder` slot (typically an `HLButton`),
///   spaced `HLSpace.xs` below the copy.
///
/// The lockup stands in the middle of the area it is given, centred across
/// the width with the page margin at both sides; its button is never wider
/// than ``HLLayout/actionMaxWidth``. In a host that offers no height (a
/// `List` row, a scrolling page) it stays as tall as its content; a page
/// gives it the free area with ``SwiftUI/View/hlStateFreeArea()``.
///
/// MONOCHROME: the lockup is informational, never a signal — no status colour.
///
/// **The one form, and how to fill it.** An empty or failed surface
/// is this lockup placed directly on the page or list, never inside an
/// `HLCard`, a ghost card or a settings card (a box around "nothing" is a
/// card in a card). It carries a symbol, a title, at most one sentence that
/// says something the title and the button do not, and at most one action,
/// an `HLButton` with `variant: .secondary` ("Try again" for a failure).
/// A second way out belongs in the toolbar, not under the first.
struct HLEmptyState<Actions: View>: View {
    private let icon: String
    private let title: Text
    private let message: Text?
    private let actions: Actions

    /// Localized-key initializer — the standard call shape for static copy.
    init(
        icon: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = Text(title)
        self.message = message.map { Text($0) }
        self.actions = actions()
    }

    /// `Text`-based initializer for runtime-resolved copy (interpolated or
    /// pre-localized strings) — avoids re-interpreting resolved strings as
    /// localization keys.
    init(
        icon: String,
        title: Text,
        message: Text? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions()
    }

    /// Gap between the header above and the symbol.
    static var topGap: CGFloat {
        HLSpace.xl
    }

    var body: some View {
        VStack(spacing: HLSpace.sm) {
            Image(systemName: icon)
                .font(.hlIcon(HLIconSize.hero, weight: .medium))
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
            title
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let message {
                message
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .multilineTextAlignment(.center)
            }
            actions
                .frame(maxWidth: HLLayout.actionMaxWidth)
                .padding(.top, HLSpace.xs)
        }
        .padding(.top, Self.topGap)
        .padding(.bottom, HLSpace.lg)
        .padding(.horizontal, HLLayout.pageMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension HLEmptyState where Actions == EmptyView {
    /// Action-less convenience — the plain informational lockup.
    init(icon: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }

    /// Action-less `Text` convenience for runtime-resolved copy.
    init(icon: String, title: Text, message: Text? = nil) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}

extension View {
    /// Centers a view in a full-bleed host. ``HLEmptyState`` does this on its
    /// own; the modifier stays for the other views that use it.
    func containerCentered() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("HLEmptyState") {
    VStack(spacing: HLSpace.xl) {
        HLEmptyState(icon: "tray", title: "No measurements yet") {
            HLButton("Log a measurement", icon: "plus", variant: .secondary) {}
        }
        HLEmptyState(
            icon: "face.smiling",
            title: "No entries yet",
            message: "Log your first mood to see the trend."
        )
    }
    .padding()
    .hlScreenBackground()
}
