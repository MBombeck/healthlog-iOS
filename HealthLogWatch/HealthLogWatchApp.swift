import SwiftUI

/// **v0.12 P2 — HealthLog watchOS companion.**
///
/// A deliberately THIN remote: it renders the glanceable `WatchSnapshot` the
/// iPhone pushes (today's doses + compliance + latest mood) and sends back
/// med-intake / mood actions the phone funnels into its existing server-first
/// store/Outbox pipeline. The watch holds no auth token, no API client, no
/// Outbox — every write is durable via `WCSession.transferUserInfo`.
@main
struct HealthLogWatchApp: App {
    @State private var client = WatchConnectivityClient()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(client)
                .onAppear { client.activate() }
        }
    }
}
