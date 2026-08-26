import SwiftUI

/// Audit-01 C1 — the ONE canonical empty-state lockup.
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
/// The lockup is horizontally greedy (`maxWidth: .infinity`) but does NOT
/// claim vertical space — hosts keep their placement intent (a `List` row, an
/// `HLCard`, or a full-bleed centre via `.containerCentered()`).
///
/// MONOCHROME: the lockup is informational, never a signal — no status colour.
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
                .padding(.top, HLSpace.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpace.lg)
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
    /// Centers an `HLEmptyState` in a full-bleed host (the placement
    /// `ContentUnavailableView` used to supply for whole-screen empties).
    func containerCentered() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("HLEmptyState") {
    VStack(spacing: HLSpace.xl) {
        HLEmptyState(
            icon: "tray",
            title: "No measurements yet",
            message: "Log your first measurement to see the history."
        ) {
            HLButton("Log a measurement", icon: "plus", variant: .restrained) {}
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
