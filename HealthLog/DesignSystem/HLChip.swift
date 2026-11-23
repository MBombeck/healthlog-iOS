import SwiftUI

/// The one chip that can be chosen: a filter, a tag, an option out of many.
///
/// A chip that only shows a state is an `HLStatusPill`, one that only marks
/// something is an `HLBadge`. Several chips stand in an ``HLFlowLayout``.
public struct HLChip: View {
    /// Height of the capsule.
    public static let visibleHeight: CGFloat = HLLayout.chipHeight
    /// Height of the area that takes the tap. It reaches past the capsule, so
    /// the chip stays small without becoming hard to hit.
    public static let hitHeight: CGFloat = HLHitTarget.minimum
    /// How far the tap area reaches past the capsule above and below. It
    /// does not reach past it to the sides: chips stand closer together than
    /// twice this, and their tap areas would overlap.
    public static var hitOutset: CGFloat {
        (hitHeight - visibleHeight) / 2
    }

    private let title: Text
    private let spokenTitle: Text?
    private let systemImage: String?
    private let isSelected: Bool
    private let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.hlChipSharesWidth) private var sharesWidth

    /// - Parameter spokenTitle: what VoiceOver reads where the visible title
    ///   is an abbreviation ("Mo" for Monday).
    public init(
        _ title: LocalizedStringKey,
        spokenTitle: LocalizedStringKey? = nil,
        systemImage: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = Text(title)
        self.spokenTitle = spokenTitle.map { Text($0) }
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.action = action
    }

    /// For text that is already final: a tag the user typed, a name from the
    /// server.
    public init(
        verbatim title: String,
        systemImage: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = Text(verbatim: title)
        spokenTitle = nil
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: HLSpace.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.hlFootnote.weight(.semibold))
                }
                title
                    .font(.hlSubhead)
                    .lineLimit(wraps ? nil : 1)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(isSelected ? HLSelectedSurface.ink : HLText.primary)
            .padding(.horizontal, sharesWidth ? HLSpace.xs : HLSpace.md)
            .padding(.vertical, wraps ? HLSpace.xs : 0)
            .frame(minWidth: sharesWidth ? nil : Self.hitHeight, minHeight: Self.visibleHeight)
            .frame(maxWidth: sharesWidth ? .infinity : nil)
            .background {
                if isSelected {
                    outline.fill(HLSelectedSurface.fill)
                } else {
                    outline.strokeBorder(HLColor.separator, lineWidth: 1)
                }
            }
            .contentShape(HLChipHitShape(outset: Self.hitOutset))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .modifier(HLChipSpokenTitle(title: spokenTitle))
    }

    /// At the accessibility sizes a long name takes a second line instead of
    /// ending in an ellipsis.
    private var wraps: Bool {
        typeSize.isAccessibilitySize
    }

    /// The corners of a 32 pt capsule. Up to the largest standard size the
    /// chip is that high and this is a capsule. At the accessibility sizes
    /// it grows and may wrap, and the fixed corners keep a second line inside.
    private var outline: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.visibleHeight / 2)
    }
}

/// How a control that is chosen is drawn: the tint as its surface, the ground
/// of the page as its ink. The chosen chip and the chosen icon button in a
/// bar take both from here, so "on" is one picture.
enum HLSelectedSurface {
    static var fill: TintShapeStyle {
        .tint
    }

    static var ink: Color {
        HLSurface.primary
    }
}

/// Replaces what VoiceOver reads for a chip whose visible title is an
/// abbreviation. A chip without a spoken title keeps the label it has.
private struct HLChipSpokenTitle: ViewModifier {
    let title: Text?

    func body(content: Content) -> some View {
        if let title {
            content.accessibilityLabel(title)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// `true` inside an ``HLChipRow`` that stands on one line: its chips
    /// fill the share of the width the row gives them.
    @Entry var hlChipSharesWidth: Bool = false
}

/// A fixed set of chips that share one line evenly: the seven days of the
/// week, the hours of a day plan.
///
/// A set whose size the data decides stands in an ``HLFlowLayout``. The row
/// becomes one as well, as soon as its chips no longer fit on one line.
///
///     HLChipRow {
///         ForEach(days) { day in
///             HLChip(day.shortKey, spokenTitle: day.longKey, isSelected: chosen.contains(day)) { toggle(day) }
///         }
///     }
public struct HLChipRow<Content: View>: View {
    /// Room between two chips of the row.
    public nonisolated static var gap: CGFloat {
        HLSpace.xs
    }

    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HLEqualWidthRow(spacing: Self.gap) { content }
                .environment(\.hlChipSharesWidth, true)
            HLFlowLayout { content }
        }
    }
}

/// The tap area of a chip: its own width, and the outset above and below.
struct HLChipHitShape: Shape {
    let outset: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -outset))
    }
}

#Preview("HLChip, light") {
    HLChipPreview()
        .preferredColorScheme(.light)
}

#Preview("HLChip, dark") {
    HLChipPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLChip, largest type") {
    HLChipPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLChipPreview: View {
    @State private var range = "Week"

    var body: some View {
        HLPage {
            HLFlowLayout {
                ForEach(["All", "Week", "Month", "Year"], id: \.self) { title in
                    HLChip(LocalizedStringKey(title), isSelected: range == title) { range = title }
                }
                HLChip("Notes", systemImage: "note.text", isSelected: false) {}
                HLChip(verbatim: "Lisinopril", isSelected: true) {}
                HLChip(verbatim: "Blood pressure in the morning before breakfast", isSelected: false) {}
            }
            HLChipRow {
                ForEach(["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"], id: \.self) { day in
                    HLChip(verbatim: day, isSelected: day == "We") {}
                }
            }
        }
    }
}
