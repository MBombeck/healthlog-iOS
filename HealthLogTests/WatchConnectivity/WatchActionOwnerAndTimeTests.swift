import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// #9 — a watch action records the tap time and lands only in the account it
/// was tapped for. D3 #10 — a dose the phone cannot find is not answered
/// "saved".
@Suite("Watch actions: tap time, owner, missing dose (#9)", .serialized, .mockURLSession)
@MainActor
struct WatchActionOwnerAndTimeTests {
    static let tappedAt = Date(timeIntervalSince1970: 1_790_000_000)
    static let baseURL = URL(string: "https://test.healthlog.local")!

    @Test("an action carries the tap time to the store, not the delivery time")
    func tapTimeReachesTheStore() async {
        let coordinator = WatchSessionCoordinator()
        let owner = WatchOwnerHash.of(userID: "account-a")
        coordinator.ownerHashProvider = { owner }
        let seen = Mutex<[Date]>([])
        coordinator.onLogMood = { _, at in
            seen.withLock { $0.append(at) }
            return .saved
        }
        coordinator.onLogMeasurement = { _, _, _, at in
            seen.withLock { $0.append(at) }
            return .saved
        }
        coordinator.onMarkIntake = { _, _, at in
            seen.withLock { $0.append(at) }
            return .saved
        }

        _ = await coordinator.outcome(of: WatchAction(kind: .logMood(score: 4, at: Self.tappedAt), ownerHash: owner))
        _ = await coordinator.outcome(of: WatchAction(
            kind: .logMeasurement(kind: .weight, value: 72, secondary: nil, at: Self.tappedAt),
            ownerHash: owner
        ))
        _ = await coordinator.outcome(of: WatchAction(
            kind: .markIntake(intakeId: "i-1", status: .taken, at: Self.tappedAt),
            ownerHash: owner
        ))

        #expect(seen.withLock { $0 } == [Self.tappedAt, Self.tappedAt, Self.tappedAt])
    }

    @Test("an action tapped on another account's snapshot is dropped")
    func foreignActionIsDropped() async {
        let coordinator = WatchSessionCoordinator()
        coordinator.ownerHashProvider = { WatchOwnerHash.of(userID: "account-b") }
        let calls = Mutex(0)
        coordinator.onLogMood = { _, _ in
            calls.withLock { $0 += 1 }
            return .saved
        }

        let outcome = await coordinator.outcome(of: WatchAction(
            kind: .logMood(score: 2, at: Self.tappedAt),
            ownerHash: WatchOwnerHash.of(userID: "account-a")
        ))

        #expect(outcome == .failed)
        #expect(calls.withLock { $0 } == 0, "A's mood never reaches B's record")
    }

    @Test("an action from an older watch build (no owner) still goes through")
    func legacyActionIsAccepted() async throws {
        let coordinator = WatchSessionCoordinator()
        coordinator.ownerHashProvider = { WatchOwnerHash.of(userID: "account-a") }
        coordinator.onLogMood = { _, _ in .saved }
        let legacy = try #require(WatchTransport.decodeAction(WatchTransport.encode(action: WatchAction(
            kind: .logMood(score: 3, at: Self.tappedAt)
        ))))

        #expect(legacy.ownerHash == nil)
        #expect(await coordinator.outcome(of: legacy) == .saved)
    }

    @Test("the owner hash travels in the snapshot and in the action, and differs per account")
    func ownerHashRoundTrips() throws {
        let hashA = try #require(WatchOwnerHash.of(userID: "account-a"))
        #expect(hashA != WatchOwnerHash.of(userID: "account-b"))
        #expect(!hashA.contains("account"), "the watch never holds the id itself")
        #expect(WatchOwnerHash.of(userID: "  ") == nil)

        let snapshot = WatchSnapshot(
            doses: [], scheduledCount: 0, takenCount: 0, recentMoodScore: nil,
            signedIn: true, generatedAt: Self.tappedAt, ownerHash: hashA
        )
        let decoded = try JSONDecoder().decode(WatchSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.ownerHash == hashA)

        let action = WatchAction(kind: .logMood(score: 1, at: Self.tappedAt), ownerHash: hashA)
        let back = try #require(WatchTransport.decodeAction(WatchTransport.encode(action: action)))
        #expect(back.ownerHash == hashA)
        #expect(back.tappedAt == Self.tappedAt)
    }

    // MARK: - D3 #10

    private final class OnlineReach: ReachabilityProviding, @unchecked Sendable {
        var isOnlineStream: AsyncStream<Bool> {
            get async { AsyncStream { continuation in
                continuation.yield(true)
                continuation.finish()
            } }
        }

        func isCurrentlyOnline() async -> Bool {
            true
        }
    }

    @Test("a real dose id missing from today's list, also after a reload, is answered failed, and nothing is written")
    func missingDoseIsNotSaved() async throws {
        let writes = Mutex(0)
        MockURLProtocol.install { req in
            let path = req.url?.path ?? ""
            if req.httpMethod != "GET" { writes.withLock { $0 += 1 } }
            let body = path.hasPrefix("/api/medications") ? #"{"data":[]}"# : #"{"data":null}"#
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(
            environment: AppEnvironment(
                baseURL: Self.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "1.7.0",
                buildNumber: "1"
            ),
            keychain: keychain,
            sessionConfiguration: .mock()
        )
        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let swr = SWRCoordinator(cache: cache, reachability: OnlineReach())
        let outbox = try OutboxQueue(inMemory: true)
        let store = MedicationsStore(repo: MedicationsRepository(api: api, outbox: outbox), swr: swr)

        let outcome = await AppContainer.markWatchIntake(intakeId: "intake-9", status: .taken, at: Self.tappedAt, in: store)

        #expect(outcome.watchAckOutcome == .failed, "the wrist must not show a check the server never got")
        #expect(writes.withLock { $0 } == 0)
    }
}

// swiftlint:enable force_unwrapping
