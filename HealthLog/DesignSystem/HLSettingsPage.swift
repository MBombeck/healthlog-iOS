import SwiftUI

/// Wraps the standard `ScrollView { VStack(spacing: HLSpace.lg) { … } }`
/// shape every Settings sub-screen uses so callers don't repeat the boilerplate.
///
/// Use as the sole root view of a Settings sub-screen:
///
/// ```swift
/// HLSettingsPage(title: "Account") {
///     HLCard("Profile") { ... }
///     HLCard("Passkeys") { ... }
/// }
/// .navigationTitle("Account")
/// ```
///
/// **UI-Standard R5 / E1 — die Ebene „Seiten-Untertitel" existiert nicht mehr.**
/// Der frühere `subtitle:`-Parameter wurde seit W1-4 nicht mehr gerendert; 33
/// Aufrufstellen pflegten damit toten, teils falschen Text. Er ist ersatzlos
/// gelöscht — Orientierung gehört an die Hub-Zeile *vor* der Navigation,
/// nicht auf die Zielseite, deren Titel ohnehin in der Navigationsleiste steht.
public struct HLSettingsPage<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: Content

    public init(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        // The page frame (margins, card gap, eager stack, background) is the
        // shared one; the title already stands in the navigation bar.
        HLPage {
            content
        }
    }
}

#Preview("HLSettingsPage") {
    NavigationStack {
        HLSettingsPage(title: "Account") {
            HLCard("Profile", subtitle: "Dein Anzeigename und Stammdaten.") {
                Text("Form fields would live here.")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
            }
            HLCard("Passkeys", footer: "Passkeys sind sicherer als Passwörter.") {
                Text("Passkey list would live here.")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}
