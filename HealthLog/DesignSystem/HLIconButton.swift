import SwiftUI

/// Where an icon button sits decides how it is drawn.
public enum HLIconButtonStyle: Equatable, Sendable {
    /// In the content: the symbol alone.
    case plain
    /// In a tab header without a navigation bar: the symbol in a glass circle.
    case bar
}

/// How large an icon button's symbol is drawn. The tap area is 44 pt either way.
public enum HLIconButtonSize: Equatable, Sendable {
    /// The symbol in the title-3 face: a button of its own.
    case standard
    /// The symbol at the size of the text beside it: the clear cross in a
    /// field, a small sign at the end of a line.
    case inline
}

/// A button that is only a symbol.
///
/// One size, one symbol weight, and a spoken label that the caller has to
/// give: a symbol without a name is silent in VoiceOver.
///
/// With `menu:` the same symbol opens a menu on the same area. Write the
/// label `menu:` out. As a trailing closure a single entry would be read as
/// the action of a plain button.
///
/// A button that stands for a state (a favourite, a filter that is set) says
/// so with `isSelected:`. "On" is dark, as on a chosen chip and a switch: in a
/// bar the circle takes the surface and the ink of the chosen chip, in the
/// content the symbol takes the full ink. In both styles the symbol is drawn
/// in its filled variant, so give a symbol that has one.
public struct HLIconButton: View {
    /// What a style and a state come to on the screen.
    public struct Appearance: Equatable, Sendable {
        public enum Surface: Equatable, Sendable {
            /// No surface, the symbol alone.
            case none
            /// The glass circle of a bar.
            case glass
            /// The surface of a chosen chip.
            case selected
        }

        public enum Ink: Equatable, Sendable {
            /// The quiet ink of a button at rest.
            case resting
            /// The full ink, for "on" without a surface.
            case full
            /// The ink of a chosen chip, on its surface.
            case onSelectedSurface
        }

        public let surface: Surface
        public let ink: Ink
        /// Whether the symbol is drawn in its filled variant.
        public let filledSymbol: Bool
    }

    /// The one place that decides how style and state are drawn. Inside the
    /// action group of a tab header the group is the glass, so a bar button
    /// at rest draws no circle of its own (no glass on glass).
    public nonisolated static func appearance(
        style: HLIconButtonStyle,
        isSelected: Bool,
        inGroup: Bool = false
    ) -> Appearance {
        if inGroup, style == .bar, !isSelected {
            return Appearance(surface: .none, ink: .resting, filledSymbol: false)
        }
        return switch (style, isSelected) {
        case (.plain, false): Appearance(surface: .none, ink: .resting, filledSymbol: false)
        case (.plain, true): Appearance(surface: .none, ink: .full, filledSymbol: true)
        case (.bar, false): Appearance(surface: .glass, ink: .resting, filledSymbol: false)
        case (.bar, true): Appearance(surface: .selected, ink: .onSelectedSurface, filledSymbol: true)
        }
    }

    /// Side length at the standard text size, visible circle and tap area.
    public nonisolated static let baseSide: CGFloat = HLLayout.iconButton
    /// Largest side length the button grows to with the text size.
    public nonisolated static let maxSide: CGFloat = 64

    /// The face of the symbol for a size.
    public nonisolated static func symbolFont(for size: HLIconButtonSize) -> Font {
        size == .standard ? .hlTitle3 : .hlBody
    }

    private let systemImage: String
    private let label: LocalizedStringKey
    private let style: HLIconButtonStyle
    private let isSelected: Bool
    private let size: HLIconButtonSize
    private let isLoading: Bool
    private let action: () -> Void
    private let menu: AnyView?
    @Environment(\.hlInHeaderActionGroup) private var inGroup
    @ScaledMetric(relativeTo: .title3) private var scaledSide: CGFloat = HLLayout.iconButton

    public init(
        systemImage: String,
        label: LocalizedStringKey,
        style: HLIconButtonStyle = .plain,
        isSelected: Bool = false,
        size: HLIconButtonSize = .standard,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.label = label
        self.style = style
        self.isSelected = isSelected
        self.size = size
        self.isLoading = isLoading
        self.action = action
        menu = nil
    }

    /// The symbol as the handle of a menu, for the "more" of a row or a bar.
    public init(
        systemImage: String,
        label: LocalizedStringKey,
        style: HLIconButtonStyle = .plain,
        isSelected: Bool = false,
        @ViewBuilder menu: () -> some View
    ) {
        self.systemImage = systemImage
        self.label = label
        self.style = style
        self.isSelected = isSelected
        size = .standard
        isLoading = false
        action = {}
        self.menu = AnyView(menu())
    }

    /// The side length for a scaled base value: never below the tap-target
    /// floor, never so large that two buttons crowd a title out of its line.
    public nonisolated static func side(forScaled scaled: CGFloat) -> CGFloat {
        min(max(scaled, baseSide), maxSide)
    }

    public var body: some View {
        Group {
            if let menu {
                Menu { menu } label: { symbol }
            } else {
                Button(action: action) { symbol }
            }
        }
        .buttonStyle(.plain)
        // A running button keeps its place and takes no second tap.
        .disabled(isLoading)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: systemImage)
        }
    }

    private var symbol: some View {
        let side = size == .standard ? Self.side(forScaled: scaledSide) : HLHitTarget.minimum
        let appearance = Self.appearance(style: style, isSelected: isSelected, inGroup: inGroup)
        return ZStack {
            if isLoading {
                ProgressView()
                    .controlSize(HLInlineProgress.controlSize)
                    .tint(Self.color(of: appearance.ink))
            } else {
                Image(systemName: systemImage)
                    .symbolVariant(appearance.filledSymbol ? .fill : .none)
                    .font(Self.symbolFont(for: size))
                    .foregroundStyle(Self.color(of: appearance.ink))
            }
        }
        // The symbol stops growing where the circle does.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .frame(width: side, height: side)
        .modifier(HLIconButtonSurface(surface: appearance.surface))
        .contentShape(Circle())
    }

    private static func color(of ink: Appearance.Ink) -> Color {
        switch ink {
        case .resting: HLText.secondary
        case .full: HLText.primary
        case .onSelectedSurface: HLSelectedSurface.ink
        }
    }
}

/// The close of a card that can be put away (a hint, a notice): the cross,
/// alone, at the trailing end of the card's head. One form for every card,
/// 44 pt, spoken as "Close" unless the card names what goes.
public struct HLDismissButton: View {
    /// The symbol of every dismiss.
    public static let systemImage = "xmark"

    private let label: LocalizedStringKey
    private let action: () -> Void

    public init(label: LocalizedStringKey = HLControlWord.close.key, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some View {
        HLIconButton(systemImage: Self.systemImage, label: label, style: .plain, action: action)
    }
}

private struct HLIconButtonSurface: ViewModifier {
    let surface: HLIconButton.Appearance.Surface

    func body(content: Content) -> some View {
        switch surface {
        case .none:
            content
        case .glass:
            content.hlGlassEffect(in: Circle(), interactive: true, fallback: HLColor.backgroundEleva)
        case .selected:
            content.background(HLSelectedSurface.fill, in: Circle())
        }
    }
}

#Preview("HLIconButton, light") {
    HLIconButtonPreview()
        .preferredColorScheme(.light)
}

#Preview("HLIconButton, dark") {
    HLIconButtonPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLIconButton, largest type") {
    HLIconButtonPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLIconButtonPreview: View {
    @State private var isFavourite = true
    @State private var isFiltered = true

    var body: some View {
        VStack(spacing: HLSpace.lg) {
            HStack(spacing: HLSpace.md) {
                HLIconButton(systemImage: "gearshape", label: "Settings", style: .bar) {}
                HLIconButton(systemImage: "plus", label: HLControlWord.add.key, style: .bar) {}
                HLIconButton(systemImage: "pencil", label: HLControlWord.edit.key) {}
                HLDismissButton {}
                HLIconButton(systemImage: "ellipsis", label: "More", menu: {
                    Button {} label: { Label(HLControlWord.edit.key, systemImage: "pencil") }
                    HLDeleteMenuItem(.undoable {})
                })
            }
            // Off and on, in the content and in a bar.
            HStack(spacing: HLSpace.md) {
                HLIconButton(systemImage: "star", label: "Pinned") {}
                HLIconButton(systemImage: "star", label: "Pinned", isSelected: isFavourite) {
                    isFavourite.toggle()
                }
                HLIconButton(systemImage: "line.3.horizontal.decrease.circle", label: "Filters", style: .bar) {}
                HLIconButton(
                    systemImage: "line.3.horizontal.decrease.circle",
                    label: "Filters",
                    style: .bar,
                    isSelected: isFiltered
                ) {
                    isFiltered.toggle()
                }
            }
        }
        .padding(HLLayout.pageMargin)
        .frame(maxWidth: .infinity)
        .background(HLSurface.primary)
    }
}
