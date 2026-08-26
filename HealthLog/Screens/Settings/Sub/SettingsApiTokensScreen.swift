import SwiftUI

/// `Settings → API tokens` (Build 2 / 2.8, mirrors web `api-section.tsx`).
///
/// Lists every API token on the account and lets the user revoke one from the
/// phone. Until this shipped, a leaked token could only be killed from a
/// desktop browser — the phone showed nothing at all.
///
/// **There is deliberately no "create token" button.** The generic mint
/// (`POST /api/tokens`) was removed server-side: it issued a
/// `["medication:ingest"]` credential that could never do its advertised job,
/// because the ingest surface gates on the per-medication
/// `medication:<id>:ingest` grant that route never issued. The working
/// credential is minted by the per-medication API-endpoint toggle. The web
/// section has no create control either — a button here would POST to a route
/// that no longer exists. See ``ApiTokenRepository``.
///
/// Server-only surface; standalone mode gets the calm placeholder.
struct SettingsApiTokensScreen: View {
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) private var container

    @State private var store: ApiTokenStore?
    @State private var showInactive = false

    var body: some View {
        HLSettingsPage(title: "API tokens") {
            if backend.hasServer {
                connectedBody
            } else {
                HLCloudDerivedPlaceholder(
                    variant: .inline,
                    surfaceName: String(localized: "API tokens"),
                    onConnect: { authStore.beginServerPairing() }
                )
            }
        }
        .navigationTitle("API tokens")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard backend.hasServer, store == nil, let api = container?.api else { return }
            let s = ApiTokenStore(repo: ApiTokenRepository(api: api))
            store = s
            await s.load()
        }
    }

    @ViewBuilder
    private var connectedBody: some View {
        if let store {
            if let error = store.error {
                HLSettingsCard(icon: "exclamationmark.triangle", title: "Something went wrong") {
                    Text(error)
                        .font(.hlFootnote)
                        .foregroundStyle(HLColor.statusBad)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.apiTokens.error")
                }
            }
            activeCard(store: store)
            if !store.inactiveTokens.isEmpty {
                inactiveCard(store: store)
            }
            infoCard
        }
    }

    private func activeCard(store: ApiTokenStore) -> some View {
        HLSettingsCard(
            icon: "key",
            title: "Active tokens",
            subtitle: "Each one can read or write data through the API.",
            footer: "Revoking takes effect immediately. Anything still using the token stops working.",
            // R5-Ausnahme, R19: beide Slots tragen **verschiedene** Klasse-D-
            // Aussagen — der Subtitle die Reichweite eines Tokens, der Footer
            // die Sofortwirkung des Widerrufs. Der Seiten-Subtitle, der die
            // erste Aussage bisher mittrug, ist mit W0 (E1) ersatzlos
            // entfallen; sie hier zu streichen wäre eine Kürzung, keine
            // Entdopplung.
            bothSlotsJustification: "D-Fläche: Reichweite (Subtitle) und Widerrufsfolge (Footer) sind zwei Aussagen."
        ) {
            if store.isLoading, store.tokens.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            } else if store.activeTokens.isEmpty {
                Text("No active API tokens.")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .accessibilityIdentifier("settings.apiTokens.empty")
            } else {
                VStack(spacing: HLSpace.md) {
                    ForEach(store.activeTokens) { token in
                        ApiTokenRow(
                            token: token,
                            isRevoking: store.revoking.contains(token.id),
                            revokeIdentifier: "settings.apiTokens.revoke"
                        ) {
                            Task { await store.revoke(id: token.id) }
                        }
                    }
                }
            }
        }
    }

    /// Revoked / expired tokens stay visible behind a disclosure — after a
    /// scare, "did that actually get revoked?" is the next question the user
    /// has, and an empty list is a poor answer.
    private func inactiveCard(store: ApiTokenStore) -> some View {
        HLSettingsCard(
            icon: "clock.arrow.circlepath",
            title: "Revoked and expired",
            subtitle: "Kept so you can see what was cut off and when."
        ) {
            Button {
                showInactive.toggle()
            } label: {
                HStack(spacing: HLSpace.md) {
                    Text(showInactive ? "Hide" : "Show")
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                    Spacer()
                    Image(systemName: showInactive ? "chevron.up" : "chevron.down")
                        .font(.hlIcon(HLIconSize.sm))
                        .foregroundStyle(HLText.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.apiTokens.toggleInactive")

            if showInactive {
                VStack(spacing: HLSpace.md) {
                    ForEach(store.inactiveTokens) { token in
                        ApiTokenRow(
                            token: token,
                            isRevoking: false,
                            revokeIdentifier: "settings.apiTokens.revoke.inactive"
                        ) {}
                    }
                }
            }
        }
    }

    /// R2 (Leerzustand) — die Karte existiert, weil dieser Screen bewusst
    /// **keinen** Erstellen-Knopf hat: die drei Zeilen sagen, warum die Fläche
    /// leer ist. Der frühere Subtitle war nur die abstrakte Zusammenfassung
    /// genau dieser drei Zeilen (Klasse A) und fällt.
    private var infoCard: some View {
        HLSettingsCard(
            icon: "lock.shield",
            title: "About API tokens"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                infoRow(
                    icon: "pills",
                    text: "Medication ingest tokens are created on the medication itself, not here."
                )
                infoRow(
                    icon: "plug",
                    text: "Tokens for an external assistant live under the MCP connector."
                )
                infoRow(
                    icon: "eye.slash",
                    text: "A token's secret is shown only when it's created — it can't be recovered."
                )
            }
        }
    }

    private func infoRow(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: icon)
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.tertiary)
                .frame(width: 20)
            Text(text)
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
