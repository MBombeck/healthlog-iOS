import SwiftUI

/// **v0.12 P2 — HealthLog watchOS companion.**
///
/// A deliberately THIN remote: it renders the glanceable `WatchSnapshot` the
/// iPhone pushes (today's doses + compliance + latest mood) and sends back
/// med-intake / mood actions the phone funnels into its existing server-first
/// store/Outbox pipeline. The watch holds no auth token, no API client, no
/// Outbox — every write is durable via `WCSession.transferUserInfo`.
///
/// **1.4 — the session starts with the app, not with the window.** watchOS
/// launches the app in the background, without any UI, to hand over a new
/// snapshot the phone sent while it was not running. The session used to be
/// activated in `onAppear`, which such a launch never reaches, so the snapshot
/// was neither saved nor shown and the "next dose" complication stayed stale
/// until someone opened the app. It is now activated in `init`, and the
/// `.watchConnectivity` background task keeps the launch alive until the
/// pending content is applied and the complications are reloaded.
@main
struct HealthLogWatchApp: App {
    @State private var client: WatchConnectivityClient

    init() {
        let client = WatchConnectivityClient()
        client.activate()
        _client = State(initialValue: client)
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(client)
        }
        .backgroundTask(.watchConnectivity) { [client] in
            await client.receivePendingContent()
        }
    }
}
