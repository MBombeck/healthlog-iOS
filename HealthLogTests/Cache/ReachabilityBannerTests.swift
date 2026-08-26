@testable import HealthLog
import SwiftUI
import Testing

/// Locks the bare structural invariants of `ReachabilityBanner`. We avoid
/// pixel snapshots (SDK-fragile across Xcode bumps); the test surface is
/// the `ReachabilityProviding` stream contract the banner consumes.
@Suite("ReachabilityBanner contract")
struct ReachabilityBannerTests {
    @Test("Constructible with a Sendable reachability provider (compile-time contract)")
    @MainActor
    func constructible() {
        // If this compiles, the public API is wired:
        let stub = StubProvider(online: true)
        _ = ReachabilityBanner(reachability: stub)
    }

    @Test("Stub stream yields exactly one value then finishes")
    func stubStreamShape() async {
        let stub = StubProvider(online: false)
        var values: [Bool] = []
        for await v in await stub.isOnlineStream {
            values.append(v)
        }
        #expect(values == [false])
    }

    @Test("isCurrentlyOnline reflects construction value")
    func currentlyOnlineMatches() async {
        let online = StubProvider(online: true)
        let offline = StubProvider(online: false)
        #expect(await online.isCurrentlyOnline())
        #expect(await !(offline.isCurrentlyOnline()))
    }

    private final class StubProvider: ReachabilityProviding, @unchecked Sendable {
        let online: Bool
        init(online: Bool) {
            self.online = online
        }

        var isOnlineStream: AsyncStream<Bool> {
            get async {
                AsyncStream { c in c.yield(online)
                    c.finish()
                }
            }
        }

        func isCurrentlyOnline() async -> Bool {
            online
        }
    }
}
