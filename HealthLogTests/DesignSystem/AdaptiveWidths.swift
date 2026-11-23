import CoreGraphics

/// The window widths every adaptive layout rule is checked at: the narrowest
/// iPad window, the phone, the closed and the open Duo, a form sheet, the iPad
/// mini, the iPad 11 and 13 inch upright and across.
enum AdaptiveWidths {
    static let all: [CGFloat] = [320, 440, 466, 540, 669, 744, 834, 1032, 1133, 1376]

    /// The width a page's content gets in a window of `width`: the window
    /// less the page margin on both sides.
    static func content(_ width: CGFloat) -> CGFloat {
        width - 2 * 16
    }
}
