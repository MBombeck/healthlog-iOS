import SwiftUI

/// The soft edges of a horizontal strip that scrolls (chips, pills): the
/// content fades out over the page margin at both ends, so a chip cut by the
/// screen edge reads as "more this way" instead of as a mistake.
enum HLEdgeFade {
    /// How long the fade is at each end: the page margin, so a strip that
    /// rests at its start shows its first chip unfaded.
    static let length: CGFloat = HLLayout.pageMargin

    /// The mask: clear at the outer edges, opaque in between. An end that
    /// is not cut (`leading`/`trailing` false) stays opaque.
    static func mask(length: CGFloat = length, leading: Bool = true, trailing: Bool = true) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: length)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: length)
        }
    }

    /// Which ends of a strip are cut: the leading one once it has scrolled,
    /// the trailing one while content lies beyond the visible width.
    static func cutEnds(offset: CGFloat, visible: CGFloat, content: CGFloat) -> (leading: Bool, trailing: Bool) {
        (leading: offset > 0.5, trailing: offset + visible < content - 0.5)
    }
}

extension View {
    /// Fades a horizontal strip out at both ends (``HLEdgeFade``). Put it on
    /// the `ScrollView`, not on its content.
    func hlEdgeFade(length: CGFloat = HLEdgeFade.length, leading: Bool = true, trailing: Bool = true) -> some View {
        mask { HLEdgeFade.mask(length: length, leading: leading, trailing: trailing) }
    }
}
