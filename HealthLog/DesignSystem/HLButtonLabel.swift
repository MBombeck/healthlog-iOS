import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// What an ``HLButton`` draws, for the controls that bring a button of their
/// own and take only a label: a share link, a photo picker, a menu.
///
///     ShareLink(item: url) {
///         HLButtonLabel("Share", systemImage: "square.and.arrow.up", variant: .secondary)
///     }
///     .hlPressable()
///
/// An action or a push is an ``HLButton``, never a `Button` around this.
public struct HLButtonLabel: View {
    private let titleText: Text
    private let titleWords: String?
    private let icon: String?
    private let variant: HLButton.Variant
    private let size: HLButton.Size
    private let isLoading: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.hlButtonOnboardingSize) private var onboardingSize
    @Environment(\.hlButtonRowSize) private var rowSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The primary fill is the ink of the appearance, so the words on it
    /// have to be resolved against that appearance.
    @Environment(\.colorScheme) private var colorScheme

    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        variant: HLButton.Variant = .primary
    ) {
        self.init(title: Text(title), icon: systemImage, variant: variant, size: .regular, isLoading: false)
    }

    /// For a title that exists only at run time.
    public init(
        _ title: Text,
        systemImage: String? = nil,
        variant: HLButton.Variant = .primary
    ) {
        self.init(title: title, icon: systemImage, variant: variant, size: .regular, isLoading: false)
    }

    init(
        title: Text,
        words: String? = nil,
        icon: String?,
        variant: HLButton.Variant,
        size: HLButton.Size,
        isLoading: Bool
    ) {
        titleText = title
        titleWords = words
        self.icon = icon
        self.variant = variant
        self.size = size
        self.isLoading = isLoading
    }

    public var body: some View {
        labelContent
            .frame(minHeight: minHeight)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, sidePadding)
            .background(background)
            .foregroundStyle(textForegroundStyle)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
            .overlay {
                // Universal 1pt hairline keeps every
                // variant visually framed in both appearances, including
                // ghost / secondary on canvas where the fill is transparent.
                // Der Sonderfall mit eigener 1,5-pt-Kontur ist entfallen —
                // die Variante ging eins zu eins in `.secondary` auf.
                RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                    .strokeBorder(HLText.tertiary.opacity(0.25), lineWidth: 1)
            }
            .hlAnimation(.easeOut(duration: 0.12), value: isLoading)
    }

    /// The first form that fits is drawn, so a word is never cut in two for
    /// lack of room: symbol and title on one line, then the title alone, then
    /// the title a little smaller. Only a title that still does not fit wraps,
    /// and that is one of several words. A running button keeps its spinner
    /// and gives up the title instead.
    @ViewBuilder
    private var labelContent: some View {
        if isLoading {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HLSpace.sm) {
                    spinner
                    oneLineTitle
                }
                spinner
            }
        } else {
            ViewThatFits(in: .horizontal) {
                if let icon {
                    HStack(spacing: HLSpace.sm) {
                        if Self.iconFollowsTitle(icon) {
                            oneLineTitle
                            Image(systemName: icon)
                        } else {
                            Image(systemName: icon)
                            oneLineTitle
                        }
                    }
                }
                oneLineTitle
                // At the accessibility sizes the title is not shrunk: the
                // shrunk line was chosen on its estimated width, then broke
                // into two lines inside a one-line button and was cut.
                if !dynamicTypeSize.isAccessibilitySize {
                    HLShrunkIdealWidth(factor: HLButton.titleMinimumScale) {
                        oneLineTitle.minimumScaleFactor(HLButton.titleMinimumScale)
                    }
                }
                // The wrapped title keeps the height of its lines, so the
                // button grows around them instead of cutting the first and
                // the last line at its minimum height. At the accessibility
                // sizes it wraps between words only ("Jetzt /
                // synchronisieren"), never inside one.
                if Self.wrapsWholeWords(at: dynamicTypeSize, words: titleWords), let titleWords {
                    HLWholeWordText(titleWords, font: font, alignment: .center)
                        .padding(.vertical, HLSpace.xs)
                } else {
                    titleText
                        .font(font)
                        .multilineTextAlignment(.center)
                        .lineLimit(HLButton.wrappedTitleLines)
                        .minimumScaleFactor(HLButton.titleMinimumScale)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, HLSpace.xs)
                }
            }
        }
    }

    /// Whether the last form of a title wraps between whole words: at the
    /// accessibility sizes, when the words are known.
    public nonisolated static func wrapsWholeWords(at typeSize: DynamicTypeSize, words: String?) -> Bool {
        typeSize.isAccessibilitySize && words != nil
    }

    /// A symbol that points onward ("Weiter ›") stands after the word, the
    /// way a reader goes; every other symbol stands before it.
    public nonisolated static func iconFollowsTitle(_ symbol: String) -> Bool {
        ["chevron.right", "chevron.forward", "arrow.right", "arrow.forward"].contains { symbol.hasPrefix($0) }
    }

    /// How a button that cannot be tapped yet looks: a quiet surface with
    /// words in secondary ink for the filled button, secondary words in the
    /// hairline for every other one. The words keep at least 3:1, so the
    /// button can be read before it can be used.
    public enum DisabledLook: Equatable, Sendable {
        case quietSurface
        case quietWords
    }

    public nonisolated static func disabledLook(for variant: HLButton.Variant) -> DisabledLook {
        variant == .primary ? .quietSurface : .quietWords
    }

    private var oneLineTitle: some View {
        titleText.font(font).lineLimit(1)
    }

    /// ProgressView's `tint` takes a concrete colour. Variants with their own
    /// label colour pass it, `.secondary` leaves the inherited tint to paint
    /// the spinner.
    @ViewBuilder
    private var spinner: some View {
        if let spinnerTint {
            ProgressView().controlSize(.small).tint(spinnerTint)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// A button in a small row is the compact form whatever it was given.
    private var effectiveSize: HLButton.Size {
        rowSize == .small ? .compact : size
    }

    private var minHeight: CGFloat {
        HLButton.height(variant: variant, size: effectiveSize, onboarding: onboardingSize && rowSize != .small)
    }

    /// Three small buttons share a card's width, so each gives up some of
    /// its side room to its words.
    private var sidePadding: CGFloat {
        rowSize == .small ? HLSpace.md : HLSpace.lg
    }

    private var font: Font {
        // A restrained label is never larger than a section heading.
        if variant == .restrained { return .hlSubhead }
        if onboardingSize, rowSize != .small { return .hlTitle3 }
        switch effectiveSize {
        case .compact: return .hlSubhead
        case .regular: return .hlHeadline
        case .large: return .hlTitle3
        }
    }

    /// Primary CTAs paint a flat `.tint` fill; the scene-root `.tint` is the
    /// monochrome ink `HLText.primary`, so every `HLButton(.primary)` fills
    /// with the mono ink. Every other variant has no fill and stands in the
    /// shared hairline; the destructive one tells itself apart by its words.
    private var background: AnyShapeStyle {
        if !isEnabled {
            return Self.disabledLook(for: variant) == .quietSurface
                ? AnyShapeStyle(HLSurface.tertiary)
                : AnyShapeStyle(Color.clear)
        }
        return switch variant {
        case .primary:
            AnyShapeStyle(.tint)
        case .secondary, .ghost, .restrained, .destructive:
            AnyShapeStyle(Color.clear)
        }
    }

    /// Secondary buttons paint the monochrome ink `HLText.primary`
    /// as label color (no fill). The primary variant's fill is
    /// the mono ink too, so its foreground flips to `systemBackground` in dark
    /// mode (see `primaryForegroundColor`). Destructive words and symbol are
    /// `HLColor.statusBad`: the danger semantic must not user-tune.
    private var textForegroundStyle: AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(HLText.secondary) }
        return switch variant {
        case .primary:
            AnyShapeStyle(primaryForegroundColor)
        case .destructive:
            AnyShapeStyle(HLColor.statusBad)
        case .secondary:
            // v0.17 monochrome: secondary labels paint the mono ink
            // (`HLText.primary` never collapses against `HLSurface.primary`).
            AnyShapeStyle(HLText.primary)
        case .ghost:
            AnyShapeStyle(HLText.primary)
        case .restrained:
            // Monochrome label — NEVER the user's accent pick.
            // Mirrors `ActiveMedicationRow.monochromeActionButton`'s
            // `HLText.secondary` so the restrained CTA reads identically to
            // the "Genommen"/"Übersprungen" pair.
            AnyShapeStyle(HLText.secondary)
        }
    }

    /// Resolves the primary-variant foreground against the monochrome ink
    /// fill. The `.primary` background paints `AnyShapeStyle(.tint)`, and the
    /// scene-root `.tint` is `HLText.primary`. `Color.white` reads cleanly on
    /// the near-black light-mode ink but collapses on the near-white dark-mode
    /// ink, so the foreground flips to `systemBackground` (the ink's inverse)
    /// whenever white-on-ink sinks below the WCAG AA text ratio.
    private var primaryForegroundColor: Color {
        #if canImport(UIKit)
            let fillUI = UIColor(HLText.primary)
                .resolvedColor(with: UITraitCollection(
                    userInterfaceStyle: colorScheme == .dark ? .dark : .light
                ))
            let ratio = HLContrastClamp.contrastRatio(
                foreground: .white,
                background: fillUI
            )
            if ratio < HLContrastClamp.wcagAATextRatio {
                return Color(uiColor: .systemBackground)
            }
        #endif
        return Color.white
    }

    /// Concrete spinner tint for variants where we can't defer to the
    /// inherited `.tint(...)`: the spinner takes the colour of the label it
    /// stands beside, so primary mirrors `primaryForegroundColor` and
    /// destructive is red. Returns nil when the inherited `.tint` is the
    /// right answer (secondary).
    private var spinnerTint: Color? {
        switch variant {
        case .primary: primaryForegroundColor
        case .destructive: HLColor.statusBad
        case .secondary: nil
        case .ghost: HLText.primary
        case .restrained: HLText.secondary
        }
    }
}

/// Reports a narrower ideal width than its content has, so `ViewThatFits`
/// takes a line of text that fits once it has shrunk to `factor`.
private struct HLShrunkIdealWidth: Layout {
    let factor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        guard proposal.width == nil else { return content.sizeThatFits(proposal) }
        let ideal = content.sizeThatFits(proposal)
        return CGSize(width: ideal.width * factor, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
