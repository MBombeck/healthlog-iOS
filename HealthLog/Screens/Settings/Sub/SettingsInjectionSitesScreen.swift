import SwiftUI

/// `/settings` → Privacy & Security → Injection sites. Edits the user-level
/// **global deny-list** (server v1.8.5 `/api/auth/me/injection-site-prefs`).
///
/// A site toggled OFF here is never offered on any medication's intake picker
/// and the server rejects it even if a medication lists it as preferred (deny
/// always wins). Optimistic write via ``InjectionSitePrefsStore`` — a failed
/// PATCH rolls the toggle back and surfaces an alert.
///
/// **MDR boundary:** this is hygiene preference (which body sites the user
/// does not want to use), not clinical guidance.
struct SettingsInjectionSitesScreen: View {
    @Environment(InjectionSitePrefsStore.self) private var store

    var body: some View {
        HLSettingsPage(title: "Injection sites") {
            // UI-Standard R3 — dies ist nach dem U5-Umbau der einzige Ort, an
            // dem die Deny-Liste erklärt wird (Seiten-Subtitle und
            // Einstiegskarten-Subtitle sind gefallen). Der Footer ist deshalb
            // auf die eine Aussage gekürzt, die der Schalter nicht zeigt: die
            // Reichweite. Die frühere erste Hälfte („Schalte eine Stelle aus,
            // um sie global auszuschließen.") war eine Bedien-Nacherzählung.
            HLSettingsCard(
                icon: "circle.grid.cross",
                title: "Allowed sites",
                footer: "Sites turned off here are hidden for every injection medication."
            ) {
                VStack(spacing: 0) {
                    let sites = InjectionSite.allCases
                    ForEach(Array(sites.enumerated()), id: \.element) { idx, site in
                        row(for: site)
                        if idx < sites.count - 1 {
                            Divider().opacity(0.6)
                        }
                    }
                }
            }
        }
        .navigationTitle("Injection sites")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
        .alert(
            String(localized: "Could not update injection-site preferences. Please try again."),
            isPresented: Binding(
                get: { store.error != nil },
                set: { _ in }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        }
    }

    private func row(for site: InjectionSite) -> some View {
        // "Allowed" = NOT excluded. The toggle reads as the positive
        // affordance so the deny-list never reads inverted.
        HStack(spacing: HLSpace.md) {
            Text(site.localizedLabel)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.md)
            Toggle(
                "",
                isOn: Binding(
                    get: { !store.isExcluded(site) },
                    set: { _ in Task { await store.toggle(site) } }
                )
            )
            .labelsHidden()
            .accessibilityLabel(Text(site.localizedLabel))
            .accessibilityIdentifier("settings.injectionSites.toggle.\(site.rawValue)")
        }
        .padding(.vertical, HLSpace.sm)
    }
}
