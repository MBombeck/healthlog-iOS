import SwiftUI
#if canImport(SafariServices)
    import SafariServices
#endif

struct WithingsIntegrationScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(WithingsIntegrationStore.self) private var store
    /// v0.11 W3 — Withings is a pure (B) surface: the connect flow is a
    /// server-brokered 3-leg OAuth (`/api/withings/*`), impossible without a
    /// backend. In standalone we render the calm `HLCloudDerivedPlaceholder`
    /// instead of a "Connect" button that opens a doomed browser tab. `hasServer`
    /// is always `true` in paired mode → inert there. (§4 matrix: Withings = (B).)
    @Environment(BackendAvailability.self) private var backend
    /// v0.11 W3 — shared "Server verbinden" CTA path for the placeholder.
    @Environment(AuthStore.self) private var authStore
    @State private var refreshTick: Int = 0

    var body: some View {
        if backend.hasServer {
            liveBody
        } else {
            ScrollView {
                HLCloudDerivedPlaceholder(
                    variant: .hero,
                    surfaceName: String(localized: "cloud_derived.surface.withings"),
                    onConnect: { authStore.beginServerPairing() }
                )
                .padding(HLSpace.lg)
            }
            .background(HLColor.background)
            .navigationTitle("Withings")
            // SET-V2-C (C-4) — integrations detail canon is `.inline` (uniform with AppleHealthIntegrationDetailScreen).
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// **UI-Standard U2 (R12) — Gerüst C→A.** Bis U2 ein handgebautes
    /// `ScrollView` + `HLCard` im `.elevated`-Stil: anderes Karten-Primitive,
    /// handgebauter 17-pt-Kartenkopf, **kein** unterer Seitenrand. Liegt jetzt
    /// auf `HLSettingsPage` + `HLSettingsCard`.
    private var liveBody: some View {
        HLSettingsPage(title: "Withings") {
            connectionCard
            HLSyncStatusFooter(screenLoading: store.isWorking)
        }
        .navigationTitle("Withings")
        // SET-V2-C (C-4) — integrations detail canon is `.inline` (uniform with AppleHealthIntegrationDetailScreen).
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadStatus() }
        .refreshable {
            await store.loadStatus()
            refreshTick &+= 1
        }
        // POLISH-SWEEP: success-tick confirms pull-to-refresh round-trip.
        .sensoryFeedback(.success, trigger: refreshTick)
    }

    /// Status + Aktionen in einer Karte. Der Zustand („Verbunden" / „Nicht
    /// verbunden") wandert vom handgebauten Kartenkopf auf die `HLStatusPill`
    /// im Trailing-Slot — dasselbe Bild wie auf der Integrationen-Liste.
    private var connectionCard: some View {
        HLSettingsCard(
            icon: "link.circle.fill",
            title: "Withings",
            trailing: { statusPill },
            content: { connectionBody }
        )
    }

    @ViewBuilder
    private var statusPill: some View {
        switch IntegrationConnectedState.withings(store.status) {
        case .some(true):
            HLStatusPill(.connected(label: String(localized: "Connected")))
        case .some(false):
            HLStatusPill(.disconnected(label: String(localized: "Not connected")))
        case .none:
            HLStatusPill(.unknown(label: String(localized: "Checking")))
        }
    }

    private var connectionBody: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            if let status = store.status, status.connected {
                Text("Last sync \(status.lastSyncedAt?.formatted(.relative(presentation: .named)) ?? "—")")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                // R9 — „Jetzt synchronisieren" ist eine wiederholbare
                // Verwaltungsaktion, nicht das Commit des Flows.
                HLButton("Sync now", icon: "arrow.triangle.2.circlepath", variant: .secondary, isLoading: store.isWorking) {
                    Task { await store.syncNow() }
                }
                HLButton("Disconnect", variant: .destructive) {
                    Task { await store.disconnect() }
                }
            } else {
                // Audit-Gruppe 3 — die Caption „Tippe unten, um zu verbinden."
                // ist ersatzlos gefallen: der Knopf beschriftet sich selbst.
                // R9 — „Verbinden" ist das eine `.primary` dieses Screens.
                HLButton("Connect Withings", icon: "link", variant: .primary, isLoading: store.isWorking) {
                    Task { await beginConnect() }
                }
            }

            if let error = store.error {
                Text(error.localizedDescription).foregroundStyle(HLColor.statusBad)
            }
        }
    }

    private func beginConnect() async {
        // Withings-Connect ist browser-only by design (3-leg OAuth, siehe
        // `05-auth-flows.md §4`): wir öffnen `/api/withings/connect` direkt
        // im System-Browser, der Server setzt das `withings_state`-Cookie und
        // 302't zur Withings-Authorize-URL. Kein POST, kein Response-JSON —
        // bleibt daher in der View (kein Repo-Roundtrip), nur der `isWorking`-
        // Spinner wird über den Store getoggelt.
        guard let baseURL = container?.environment.baseURL else { return }
        let connectURL = baseURL.appendingPathComponent("/api/withings/connect")
        await store.openingExternalConnect {
            #if canImport(UIKit)
                if UIApplication.shared.canOpenURL(connectURL) {
                    await UIApplication.shared.open(connectURL)
                }
            #endif
        }
    }
}

/// Mirror der `GET /api/withings/status`-Response (`03-api-contracts §Withings`).
/// `connected` + `lastSyncedAt` reichen für den Settings-Surface; weitere
/// Felder dekodieren wir tolerant (alle optional), damit zusätzliche Server-
/// Felder iOS nicht brechen.
public struct WithingsStatus: Codable, Sendable {
    public let connected: Bool
    public let configured: Bool?
    public let lastSyncedAt: Date?
    public let connectedAt: Date?
    public let tokenExpired: Bool?
    public let tokenRefreshFailed: Bool?
    public let tokenExpiresAt: Date?
    public let scope: String?
    public let hasActivityScope: Bool?
}
