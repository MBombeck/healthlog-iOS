import Foundation

/// Spacing and sizes the Home and Lock Screen widgets share, so the same kind
/// of row, stack, or control has the same size in every widget.
public enum WidgetMetrics {
    /// Between the header and the lines of a text widget.
    public static let stackSpacing: CGFloat = 6
    /// Between the header, a ring, and the caption under it.
    public static let ringStackSpacing: CGFloat = 8
    /// Between a title and the caption directly under it.
    public static let lineSpacing: CGFloat = 2
    /// Between a value and its unit.
    public static let valueUnitSpacing: CGFloat = 3
    /// Between the text column and the control column of a medium widget.
    public static let columnSpacing: CGFloat = 14
    /// Width of the control column of a medium widget.
    public static let actionColumnWidth: CGFloat = 130
    /// Smallest tap target a widget control gets.
    public static let minTapTarget: CGFloat = 44
    /// Corner radius of a widget control.
    public static let controlCornerRadius: CGFloat = 12
}
