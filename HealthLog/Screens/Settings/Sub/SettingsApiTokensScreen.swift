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
        // 1.4 B2-c — where tokens come from (the wayfinding card that stood
        // at the end of the list) is the screen's one (i).
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HLInfoButton(content: Self.info, accessibilityIdentifier: "settings.apiTokens.info")
            }
        }
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
        }
    }

    static var info: HLInfoContent {
        HLInfoContent(
            title: String(localized: "API tokens"),
            identifier: "settings.apiTokens.info.sheet",
            about: String(localized: "settings.apiTokens.info.about")
        )
    }

    private func activeCard(store: ApiTokenStore) -> some View {
        // 1.4 B2-c — no subtitle and no footer: each row shows its rights,
        // and the revoke dialog says the revocation is immediate and final.
        HLSettingsCard(
            icon: "key",
            title: "Active tokens"
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
            title: "Revoked and expired"
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
}
