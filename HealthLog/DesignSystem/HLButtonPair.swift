import SwiftUI

/// The order of a stacked ``HLButtonPair``.
public enum HLButtonPairOrder: Equatable, Sendable {
    /// The main action on top, as in a stacked alert (the default).
    case primaryFirst
    /// The order of the row, leading button on top: for two equal actions.
    case reading

    /// Which button of the pair.
    public enum Slot: Equatable, Sendable {
        case primary
        case secondary
    }

    /// The buttons from top to bottom when stacked. Side by side the
    /// secondary one always leads.
    public var stacked: [Slot] {
        self == .primaryFirst ? [.primary, .secondary] : [.secondary, .primary]
    }
}

/// Two buttons that belong together: the main action and the one beside it.
///
/// Side by side both are equally wide, the main action at the trailing edge.
/// The pair stands one above the other, main action first, from the first
/// accessibility text size on, and below that as soon as one of the two
/// buttons no longer has room for its whole label on one line at full size.
/// A title is never shrunk or wrapped to keep the pair on one line.
///
///     HLButtonPair {
///         HLButton(HLControlWord.save.key) { save() }
///     } secondary: {
///         HLButton(HLControlWord.cancel.key, variant: .secondary) { dismiss() }
///     }
///
/// Two buttons of equal weight ("Clear selection" and "Select all") pass
/// `order: .reading`: they keep the order of the row when stacked, the
/// leading one on top, in every language and at every size.
public struct HLButtonPair<Primary: View, Secondary: View>: View {
    /// The order of the stacked pair.
    public typealias Order = HLButtonPairOrder

    /// Room between the two buttons, in both arrangements.
    public nonisolated static var gap: CGFloat {
        HLLayout.buttonGap
    }

    private let primary: Primary
    private let secondary: Secondary
    private let order: Order
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        order: Order = .primaryFirst,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary
    ) {
        self.order = order
        self.primary = primary()
        self.secondary = secondary()
    }

    public var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                sideBySide
                stacked
            }
        }
    }

    private var sideBySide: some View {
        HLEqualWidthRow(spacing: Self.gap) {
            secondary
            primary
        }
    }

    private var stacked: some View {
        VStack(spacing: Self.gap) {
            if order == .primaryFirst {
                primary
                secondary
            } else {
                secondary
                primary
            }
        }
    }
}

/// A row whose elements share the width evenly.
///
/// Asked for the width it would like, it answers with what the widest element
/// needs for each of them. That is what lets `ViewThatFits` see that a pair
/// or a row does not fit before any of its labels has to give way.
struct HLEqualWidthRow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let count = CGFloat(subviews.count)
        let gaps = spacing * (count - 1)
        guard let width = proposal.width else {
            let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
            let widest = ideal.map(\.width).max() ?? 0
            return CGSize(width: widest * count + gaps, height: ideal.map(\.height).max() ?? 0)
        }
        let share = ProposedViewSize(width: max((width - gaps) / count, 0), height: proposal.height)
        let height = subviews.map { $0.sizeThatFits(share).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = CGFloat(subviews.count)
        let each = max((bounds.width - spacing * (count - 1)) / count, 0)
        var leading = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: leading, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: each, height: bounds.height)
            )
            leading += each + spacing
        }
    }
}

#Preview("HLButtonPair, light") {
    HLButtonPairPreview()
        .preferredColorScheme(.light)
}

#Preview("HLButtonPair, dark") {
    HLButtonPairPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLButtonPair, largest type") {
    HLButtonPairPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLButtonPairPreview: View {
    var body: some View {
        HLPage {
            HLButtonPair {
                HLButton(HLControlWord.save.key) {}
            } secondary: {
                HLButton(HLControlWord.cancel.key, variant: .secondary) {}
            }
            HLButtonPair {
                HLButton(HLControlWord.delete.key, systemImage: "trash", variant: .destructive) {}
            } secondary: {
                HLButton(HLControlWord.cancel.key, variant: .secondary) {}
            }
            // Too long for half the width: the pair stands stacked.
            HLButtonPair {
                HLButton(verbatim: "Disconnect and delete the data", variant: .primary) {}
            } secondary: {
                HLButton(HLControlWord.cancel.key, variant: .secondary) {}
            }
        }
    }
}
