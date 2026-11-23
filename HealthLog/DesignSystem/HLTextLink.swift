import SwiftUI

/// A reference inside running text or a footer: sources, licence, privacy,
/// a crisis number.
///
/// It keeps the size of the text around it and the secondary ink, carries
/// no underline (that is not an iOS form) and, when it leaves the app, the
/// one external sign `arrow.up.right` behind its words. The tap area grows to
/// 44 pt high without moving the text. A quiet action that stays in the app
/// is ``HLLinkButton``.
struct HLTextLink: View {
    private let title: Text
    private let destination: URL?
    private let action: (() -> Void)?

    init(_ title: LocalizedStringKey, destination: URL) {
        self.title = Text(title)
        self.destination = destination
        action = nil
    }

    /// For words that exist only at run time (a phone number, a host name).
    init(verbatim title: String, destination: URL) {
        self.title = Text(verbatim: title)
        self.destination = destination
        action = nil
    }

    /// A reference that opens something inside the app.
    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = Text(title)
        destination = nil
        self.action = action
    }

    /// Whether a link leaves the app: the web, mail, the phone. These carry
    /// the external sign.
    nonisolated static func isExternal(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto", "tel", "sms"].contains(scheme)
    }

    /// How far the tap area reaches above and below a footnote line, so the
    /// two together come to the 44 pt of every control.
    nonisolated static let hitOutset: CGFloat = HLSpace.md

    /// The sign behind an external link, the same as in the accessory column.
    nonisolated static let externalSymbol = HLRowIndicator.externalSymbol

    var body: some View {
        if let destination {
            Link(destination: destination) { label(external: Self.isExternal(destination)) }
                .buttonStyle(.plain)
        } else {
            Button { action?() } label: { label(external: false) }
                .buttonStyle(.plain)
        }
    }

    private func label(external: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xxs) {
            title
            if external {
                Image(systemName: Self.externalSymbol)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(HLText.secondary)
        .fontWeight(.semibold)
        // The tap area reaches past the line without moving the text.
        .padding(.vertical, Self.hitOutset)
        .contentShape(Rectangle())
        .padding(.vertical, -Self.hitOutset)
    }
}

#Preview("HLTextLink") {
    HLPage {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(verbatim: "Wetterdaten von Open-Meteo.")
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.secondary)
                HLTextLink(verbatim: "open-meteo.com", destination: URL(string: "https://open-meteo.com")!)
                    .font(.hlFootnote)
            }
        }
    }
}
