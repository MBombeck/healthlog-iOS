import SwiftUI

/// The value at the right edge of a row, for values that arrive as text
/// ("1,3 mg/L", "heute, 08:05", "302").
///
/// It is as large as the row title and one weight lighter, with digits of
/// equal width, so a value never outweighs the name it belongs to. A status
/// stands under it as text (``HLRowStatus``), never as a capsule. For a
/// number with a unit, ``HLValueText`` with `size: .row` sets the same font.
///
/// Value and status take one line each; only at the accessibility sizes,
/// where the row puts them under its title, do they wrap.
public struct HLRowValue: View {
    /// Which kind of value the row shows.
    public enum Emphasis: Equatable, Sendable {
        /// A reading the row is about: medium weight, primary ink.
        case reading
        /// A setting or a fact about the app: regular weight, secondary ink.
        case setting

        public var font: Font {
            switch self {
            case .reading: .hlSubhead.weight(.medium)
            case .setting: .hlSubhead
            }
        }

        public var tint: Color {
            switch self {
            case .reading: HLText.primary
            case .setting: HLText.secondary
            }
        }
    }

    private let value: Text?
    private let emphasis: Emphasis
    private let status: HLRowStatus?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A value that exists only at run time.
    public init(_ value: String, emphasis: Emphasis = .reading, status: HLRowStatus? = nil) {
        self.value = Text(verbatim: value)
        self.emphasis = emphasis
        self.status = status
    }

    /// A value that is already a text (formatted or localized).
    public init(_ value: Text, emphasis: Emphasis = .reading, status: HLRowStatus? = nil) {
        self.value = value
        self.emphasis = emphasis
        self.status = status
    }

    /// A status without a value, for ``HLRow``.
    init(value: Text?, emphasis: Emphasis = .reading, status: HLRowStatus?) {
        self.value = value
        self.emphasis = emphasis
        self.status = status
    }

    public var body: some View {
        // At the accessibility sizes the row moves its trailing slot under
        // the title, so the value starts at the leading edge there.
        let leading = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: leading ? .leading : .trailing, spacing: HLSpace.xxs) {
            if let value {
                value
                    .font(emphasis.font)
                    .monospacedDigit()
                    .foregroundStyle(emphasis.tint)
                    .multilineTextAlignment(leading ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status {
                status.badge
            }
        }
        .lineLimit(leading ? nil : 1)
    }
}

#Preview("HLRowValue") {
    HLPage {
        HLCard(layout: .rows) {
            HLRowLayout(title: Text(verbatim: "INR"), subtitle: Text(verbatim: "2 Werte")) {
                HLRowValue("1,3", status: HLRowStatus("Über Bereich", icon: "arrow.up", tone: .warning))
            }
            HLRowLayout(title: Text(verbatim: "Build")) {
                HLRowValue("302", emphasis: .setting)
            }
        }
    }
}
