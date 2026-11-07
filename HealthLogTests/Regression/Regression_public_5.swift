import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **REG (1.5) — public #5 (MBombeck): a forced sign-in every morning.**
///
/// The table's case end to end: two requests leave with the same expired
/// bearer, both get 401, and the refresh token is rotated exactly once. The
/// rotation goes through the production `RefreshCoordinator` with its
/// shipped grace window, wired into `APIClient` the way
/// `AppContainer+CoreInfra` wires it. The seams on their own are pinned by
/// `RefreshCoordinatorGraceTests` and `APIClientRotationRaceTests`.
///
/// No sleep decides the outcome: the rotation waits until the server has
/// seen BOTH requests carry the old bearer, so the two 401s are concurrent
/// by construction, not by timing.
@Suite("REG public #5: two 401s at once rotate the refresh token once", .timeLimit(.minutes(1)))
struct Regression_public_5 {
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var bearers: [String] = []
        private var rotations = 0
        private var logouts = 0

        func saw(_ bearer: String) {
            lock.withLock { bearers.append(bearer) }
        }

        func rotated() {
            lock.withLock { rotations += 1 }
        }

        func loggedOut() {
            lock.withLock { logouts += 1 }
        }

        var sent: [String] {
            lock.withLock { bearers }
        }

        var rotationCount: Int {
            lock.withLock { rotations }
        }

        var logoutCount: Int {
            lock.withLock { logouts }
        }
    }

    @Test("both requests succeed, one rotation, no sign-out")
    func concurrentUnauthorizedRotatesOnce() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let keychain = InMemoryKeychain()
        try keychain.setString("A", forKey: KeychainKey.authToken)
        let server = Server()

        let coordinator = RefreshCoordinator(refresh: { @Sendable in
            // Rotate only once the server has answered BOTH old-bearer
            // requests: the second 401 cannot be a straggler of a finished
            // rotation, it is concurrent.
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while server.sent.filter({ $0 == "A" }).count < 2, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            server.rotated()
            try? keychain.setString("B", forKey: KeychainKey.authToken)
            return .refreshed
        })
        let api = APIClient(
            environment: AppEnvironment(
                baseURL: session.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "1.5.0",
                buildNumber: "300"
            ),
            keychain: keychain,
            sessionConfiguration: session.configuration,
            onUnauthorized: { @Sendable in server.loggedOut() },
            refreshHandler: { await coordinator.attemptRefresh() }
        )
        session.install { request in
            let bearer = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? "<none>"
            server.saw(bearer)
            let ok = bearer == "B"
            let body = ok ? #"{"data":null,"error":null}"# : #"{"data":null,"error":"Invalid token"}"#
            return (
                HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 401, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        async let first: Void = api.sendVoid(APIRequest<EmptyPayload>(method: .get, path: "/api/measurements"))
        async let second: Void = api.sendVoid(APIRequest<EmptyPayload>(method: .get, path: "/api/dashboard"))
        try await first
        try await second

        #expect(server.sent.filter { $0 == "A" }.count == 2, "both requests left with the expired bearer: \(server.sent)")
        #expect(server.sent.filter { $0 == "B" }.count == 2, "both were replayed with the new one: \(server.sent)")
        #expect(server.rotationCount == 1, "two 401s rotated the refresh token \(server.rotationCount) times")
        #expect(server.logoutCount == 0)
    }
}
