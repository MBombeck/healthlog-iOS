import SwiftUI

/// The two ranks a section header has.
public enum HLSectionRank: Equatable, Sendable {
    /// One of the large parts of a screen.
    case area
    /// A group inside an area, and every header on a settings page.
    case group

    /// The rank after `offset` steps down: in a detail column beside a list
    /// an area becomes a group, so the column's own name stays the only
    /// 17 pt text in it. A group stays a group.
    public func lowered(by offset: Int) -> HLSectionRank {
        offset > 0 ? .group : self
    }

    /// The text role the rank is set in.
    public var textRole: HLTextRole {
        self == .area ? .areaHeader : .groupHeader
    }
}

private struct HLSectionRankOffsetKey: EnvironmentKey {
    static let defaultValue = 0
}

public extension EnvironmentValues {
    /// How many ranks the section headers under this view step down. A list
    /// that shows its detail beside it sets 1 for the detail column.
    var hlSectionRankOffset: Int {
        get { self[HLSectionRankOffsetKey.self] }
        set { self[HLSectionRankOffsetKey.self] = newValue }
    }
}

/// The published measures of a section header.
public enum HLSectionHeaderMetrics {
    /// Room between the content above and the header.
    public static let before: CGFloat = HLLayout.sectionGapBefore
    /// Room between the header and the card under it.
    public static let after: CGFloat = HLLayout.sectionGapAfter

    /// What the header adds above itself, given what its container already
    /// puts there. Never less than nothing: the room above only grows.
    public static func topPadding(in gap: HLContainerGap) -> CGFloat {
        max(0, before - gap.before)
    }

    /// What the header adds below itself. Negative only where a container
    /// has said that it puts more than 8 pt under each element.
    public static func bottomPadding(in gap: HLContainerGap) -> CGFloat {
        after - gap.after
    }
}

/// The header above a card or a group of cards.
///
/// It stands outside the card, in mixed case like the system's own list
/// headers, and brings its own room: 24 pt above, 8 pt below. Inside a page
/// (``HLPage``) or a list with the page margins it hears which gap is
/// already there and adds only the difference; anywhere else it brings the
/// full room as real spacing. A card under a section header carries no title
/// of its own.
///
/// The trailing place takes one text link or one icon button. It does not
/// change the height of the header, so a header with a link and one without
/// keep the same rhythm.
public struct HLSectionHeader<Trailing: View>: View {
    private let title: Text
    private let rank: HLSectionRank
    private let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.hlContainerGap) private var containerGap
    @Environment(\.hlSectionRankOffset) private var rankOffset

    public init(
        _ title: LocalizedStringKey,
        rank: HLSectionRank = .group,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = Text(title)
        self.rank = rank
        self.trailing = trailing()
    }

    /// For a title that is already final, such as a category name resolved at
    /// run time.
    public init(
        verbatim title: String,
        rank: HLSectionRank = .group,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = Text(verbatim: title)
        self.rank = rank
        self.trailing = trailing()
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Large type needs the full width for the title.
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    titleText
                    trailingControl
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                    titleText
                    // Holds the width of the trailing control without its
                    // height; the control itself is drawn over the line.
                    trailingControl
                        .hidden()
                        .frame(height: 0)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .trailing) { trailingControl }
            }
        }
        .padding(.top, HLSectionHeaderMetrics.topPadding(in: containerGap))
        .padding(.bottom, HLSectionHeaderMetrics.bottomPadding(in: containerGap))
        // As the header of a list section it keeps its own measures and its
        // own case; the list adds neither insets nor capitals.
        .listRowInsets(EdgeInsets())
        .textCase(nil)
    }

    /// A link button asks for the full width; here it takes only its own.
    private var trailingControl: some View {
        trailing.fixedSize(horizontal: true, vertical: false)
    }

    private var titleText: some View {
        title
            .hlText(rank.lowered(by: rankOffset).textRole)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("HLSectionHeader, light") {
    HLSectionHeaderPreview()
        .preferredColorScheme(.light)
}

#Preview("HLSectionHeader, dark") {
    HLSectionHeaderPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLSectionHeader, largest type") {
    HLSectionHeaderPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLSectionHeaderPreview: View {
    var body: some View {
        HLPage {
            HLSectionHeader("Overview", rank: .area)
            HLCard {
                HLRowLayout(title: "Blood pressure", indicator: .disclosure)
            }
            HLSectionHeader("Medications") {
                HLLinkButton(HLControlWord.edit.key) {}
            }
            HLCard {
                HLRowLayout(title: "Daily", indicator: .disclosure)
            }
            HLSectionHeader("Notes")
            HLCard {
                HLRowLayout(title: "Weight", indicator: .disclosure)
            }
        }
    }
}
