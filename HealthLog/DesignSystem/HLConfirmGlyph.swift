import SwiftUI

/// The check that confirms a done thing: a dose taken, a value saved, a mood
/// logged. It draws itself on like a stroke of a pen the moment
/// `isConfirmed` turns true, the same way at every one of those moments.
///
/// With Reduce Motion it stands fully drawn at once. Size and colour come
/// from the caller (`.font`, `.foregroundStyle`); haptics stay with the
/// caller as well, the glyph adds none. It is decoration: the control or the
/// text beside it says what happened.
public struct HLConfirmGlyph: View {
    /// The default symbol: SF Symbols 7 draws it in one stroke.
    public static let defaultSymbol = "checkmark.circle.fill"

    private let isConfirmed: Bool
    private let systemImage: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isConfirmed: Bool, systemImage: String = HLConfirmGlyph.defaultSymbol) {
        self.isConfirmed = isConfirmed
        self.systemImage = systemImage
    }

    /// Whether the symbol is held undrawn: only while unconfirmed and only
    /// where motion is allowed. Pure, so the rule is tested without a view.
    public nonisolated static func isHeldUndrawn(isConfirmed: Bool, reduceMotion: Bool) -> Bool {
        !isConfirmed && !reduceMotion
    }

    /// Whether the symbol is visible at all.
    public nonisolated static func isVisible(isConfirmed: Bool, reduceMotion: Bool) -> Bool {
        // Undrawn is invisible; without motion there is no undrawn state, so
        // an unconfirmed glyph is hidden instead.
        isConfirmed || !reduceMotion
    }

    public var body: some View {
        Image(systemName: systemImage)
            .symbolEffect(
                .drawOn,
                options: .nonRepeating,
                isActive: Self.isHeldUndrawn(isConfirmed: isConfirmed, reduceMotion: reduceMotion)
            )
            .opacity(Self.isVisible(isConfirmed: isConfirmed, reduceMotion: reduceMotion) ? 1 : 0)
            .accessibilityHidden(true)
    }
}

#Preview("HLConfirmGlyph") {
    @Previewable @State var done = false
    HLConfirmGlyph(isConfirmed: done)
        .font(.hlIcon(44))
        .foregroundStyle(HLColor.statusOK)
        .frame(width: 88, height: 88)
        .contentShape(Rectangle())
        .onTapGesture { done.toggle() }
}
