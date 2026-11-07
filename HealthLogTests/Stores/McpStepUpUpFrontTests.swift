// SEC (1.5, #151) — a connector token is never minted without a fresh
// step-up elevation from an account that can give one. POLISH-C (C1, dev
// #163 B1): which accounts that is follows the server's
// `elevation-if-enrolled` rule, never the server version.
//
// Server contract, read at v1.47.0 (`git show origin/main:…`, not invented):
// - `src/app/api/mcp/tokens/route.ts` — `POST` runs
//   `requireRecentProof({ bearer: "token" })`, in place since v1.39.3
//   (`0fc83cb0a fix(auth): ask for a fresh proof before the record or a
//   credential to it leaves`). The Bearer arm takes the token alone and does
//   not read `X-Step-Up` until the app sends one (comment in the route and in
//   `recent-proof-surface-guard.test.ts`).
// - `src/lib/auth/step-up.ts` — `STEP_UP_ELEVATION_TTL_SECONDS = 5 * 60`.
// - `src/lib/auth/second-factor.ts` `recentProofMethods` + `GET /api/auth/me/mfa`
//   `proofMethods` (without `oidc` on a token).
//
// Every value below is a fixture shape, not a real credential.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("SEC: proof before a connector token", .serialized, .mockURLSession)
    struct McpStepUpUpFrontTests {
        private static let elevation = "hle_fixture_elevation_not_a_secret"
        private static let minted = #"{"data":{"token":"hlk_fixture_minted","name":"Claude"},"error":null}"#
        private static let stepUpRequired =
            #"{"data":null,"error":"Step-up authentication required","meta":{"errorCode":"auth.stepup.required"}}"#

        /// Every POST the stub saw, with its `X-Step-Up`.
        private final class Posts: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [String?] = []
            func record(_ req: URLRequest) {
                guard req.httpMethod == "POST" else { return }
                lock.lock()
                defer { lock.unlock() }
                seen.append(req.value(forHTTPHeaderField: "X-Step-Up"))
            }

            var stepUps: [String?] {
                lock.lock()
                defer { lock.unlock() }
                return seen
            }
        }

        /// A clock the test moves by hand.
        private final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var current = Date(timeIntervalSince1970: 1_800_000_000)
            func now() -> Date {
                lock.lock()
                defer { lock.unlock() }
                return current
            }

            func advance(_ seconds: TimeInterval) {
                lock.lock()
                defer { lock.unlock() }
                current = current.addingTimeInterval(seconds)
            }
        }

        private func makeAPI() throws -> APIClient {
            let keychain = InMemoryKeychain()
            try keychain.setString("hlk_fixture_session", forKey: KeychainKey.authToken)
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return APIClient(
                environment: env,
                keychain: keychain,
                sessionConfiguration: .mock(),
                onUnauthorized: {},
                refreshHandler: { .refreshed }
            )
        }

        /// The server mints for any POST unless `refuse` says otherwise.
        private func install(_ posts: Posts, refuse: @escaping @Sendable (URLRequest) -> Bool = { _ in false }) {
            MockURLProtocol.install { req in
                posts.record(req)
                let refused = req.httpMethod == "POST" && refuse(req)
                let (status, body) = req.httpMethod == "POST"
                    ? (refused ? 401 : 201, refused ? Self.stepUpRequired : Self.minted)
                    : (200, #"{"data":[],"error":null}"#)
                return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
        }

        @MainActor
        private func makeStore(clock: Clock = Clock(), upFront: Bool = true) throws -> McpStore {
            try McpStore(repo: McpRepository(api: makeAPI()), proofUpFront: { upFront }, now: clock.now)
        }

        // MARK: - The gate

        @MainActor
        @Test("without an elevation nothing is sent: the proof is asked for, with a clear sentence")
        func noProofNoMint() async throws {
            let posts = Posts()
            install(posts)
            let store = try makeStore()

            #expect(await store.mintToken(name: "Claude", scope: .read) == false)
            #expect(posts.stepUps.isEmpty)
            #expect(store.stepUp.isRequested)
            #expect(store.error == StepUpRetry.requiredMessage)
            #expect(store.freshToken == nil)
            #expect(store.isMinting == false)
        }

        @MainActor
        @Test("with an elevation exactly one mint goes out, carrying it")
        func proofThenExactlyOneMint() async throws {
            let posts = Posts()
            install(posts)
            let store = try makeStore()

            #expect(await store.mintToken(name: "Claude", scope: .readWrite) == false)
            store.stepUp.supply(Self.elevation)
            #expect(await store.mintToken(name: "Claude", scope: .readWrite))
            #expect(posts.stepUps == [Self.elevation])
            #expect(store.freshToken?.token == "hlk_fixture_minted")
            #expect(store.error == nil)
            // Spent: the next mint asks again.
            #expect(await store.mintToken(name: "Second", scope: .read) == false)
            #expect(posts.stepUps.count == 1)
            #expect(store.stepUp.isRequested)
        }

        @MainActor
        @Test("cancel and the swipe-down leave nothing half: no mint, no elevation, the sentence stays")
        func cancelLeavesNothing() async throws {
            let posts = Posts()
            install(posts)
            let store = try makeStore()

            #expect(await store.mintToken(name: "Claude", scope: .read) == false)
            // The sheet's binding is what Cancel and the back/swipe gesture write.
            let presented = StepUpRetry.sheetBinding(store.stepUp)
            #expect(presented.wrappedValue)
            presented.wrappedValue = false
            #expect(store.stepUp.isRequested == false)
            #expect(store.stepUp.take() == nil)
            #expect(store.error == StepUpRetry.requiredMessage)
            #expect(store.freshToken == nil)
            #expect(posts.stepUps.isEmpty)

            // Tapping Create again asks again; still nothing sent.
            #expect(await store.mintToken(name: "Claude", scope: .read) == false)
            #expect(store.stepUp.isRequested)
            #expect(posts.stepUps.isEmpty)
        }

        @MainActor
        @Test("an elevation past four minutes is not sent: the proof is asked for again")
        func expiredProofAsksAgain() async throws {
            let posts = Posts()
            install(posts)
            let clock = Clock()
            let store = try makeStore(clock: clock)

            store.stepUp.supply(Self.elevation)
            clock.advance(StepUpRetry.maximumAge)
            #expect(await store.mintToken(name: "Claude", scope: .read) == false)
            #expect(posts.stepUps.isEmpty)
            #expect(store.stepUp.isRequested)

            store.stepUp.supply(Self.elevation)
            clock.advance(StepUpRetry.maximumAge - 1)
            #expect(await store.mintToken(name: "Claude", scope: .read))
            #expect(posts.stepUps == [Self.elevation])
        }

        @MainActor
        @Test("a sheet that goes away (closed, app switch, privacy shield) takes its proof with it")
        func abandonedSheetDropsProof() async throws {
            let posts = Posts()
            install(posts)
            let store = try makeStore()

            #expect(await store.mintToken(name: "Claude", scope: .read) == false)
            store.stepUp.supply(Self.elevation)
            store.abandonMint()
            #expect(store.error == nil)
            #expect(store.stepUp.isRequested == false)

            #expect(await store.mintToken(name: "Claude", scope: .read) == false)
            #expect(posts.stepUps.isEmpty)
            #expect(store.stepUp.isRequested)
        }

        @MainActor
        @Test("a fresh store (the screen rebuilt behind the shield) holds no proof")
        func rebuiltScreenHoldsNoProof() async throws {
            let posts = Posts()
            install(posts)
            let first = try makeStore()
            first.stepUp.supply(Self.elevation)

            let rebuilt = try makeStore()
            #expect(await rebuilt.mintToken(name: "Claude", scope: .read) == false)
            #expect(posts.stepUps.isEmpty)
        }

        @MainActor
        @Test("a double tap with one proof mints once")
        func doubleTapMintsOnce() async throws {
            let posts = Posts()
            install(posts)
            let store = try makeStore()
            store.stepUp.supply(Self.elevation)

            async let first = store.mintToken(name: "Claude", scope: .read)
            async let second = store.mintToken(name: "Claude", scope: .read)
            let results = await [first, second]
            #expect(results.count(where: { $0 }) == 1)
            #expect(posts.stepUps == [Self.elevation])
        }

        @MainActor
        @Test("an elevation the server refuses is not sent again by itself")
        func refusedProofIsNotResent() async throws {
            let posts = Posts()
            install(posts, refuse: { _ in true })
            let store = try makeStore()
            store.stepUp.supply(Self.elevation)

            #expect(await store.mintToken(name: "Claude", scope: .read) == false)
            #expect(posts.stepUps == [Self.elevation])
            #expect(store.stepUp.isRequested)
            #expect(store.stepUp.take() == nil)
            #expect(store.error == StepUpRetry.requiredMessage)
        }

        // MARK: - Which accounts bring a proof (POLISH-C C1, #163 B1)

        @MainActor
        @Test("an account without factor or passkey mints on the token, and still asks when refused")
        func unenrolledMintsOnToken() async throws {
            let posts = Posts()
            install(posts)
            let store = try makeStore(upFront: false)

            #expect(await store.mintToken(name: "Claude", scope: .read))
            #expect(posts.stepUps == [nil])
            #expect(store.stepUp.isRequested == false)
        }

        private static func status(totp: Bool = false, keys: Int = 0, methods: [String]?) -> AccountSecurityStore.TwoFactorState {
            .loaded(MfaStatus(
                totp: MfaStatus.Totp(enabled: totp),
                recoveryCodesRemaining: 0,
                webauthn: (0 ..< keys).map { MfaStatus.SecurityKey(id: "key-\($0)", name: "Key") },
                passkeyNudgeDismissed: false,
                proofMethods: methods
            ))
        }

        @Test("a second factor, a security key or a passkey asks for the proof; nothing of these does not")
        func enrolmentDecides() {
            #expect(McpStore.accountNeedsProof(Self.status(totp: true, methods: ["totp"])))
            #expect(McpStore.accountNeedsProof(Self.status(keys: 1, methods: ["webauthn"])))
            #expect(McpStore.accountNeedsProof(Self.status(methods: ["password", "passkey"])))
            #expect(McpStore.accountNeedsProof(Self.status(methods: ["password"])) == false)
            // An SSO-only account: the server sends `oidc` or nothing.
            #expect(McpStore.accountNeedsProof(Self.status(methods: [])) == false)
            #expect(McpStore.accountNeedsProof(Self.status(methods: ["oidc"])) == false)
        }

        /// Fail closed: a status the app could not read, a server without the
        /// native status route, and a status without `proofMethods` (a passkey
        /// cannot be ruled out) all ask for the proof.
        @Test("an unknown status asks for the proof", arguments: [
            AccountSecurityStore.TwoFactorState.idle, .loading, .unavailable, .failed("offline")
        ])
        func unknownStatusAsks(_ state: AccountSecurityStore.TwoFactorState) {
            #expect(McpStore.accountNeedsProof(state))
            #expect(McpStore.accountNeedsProof(Self.status(methods: nil)))
        }

        @MainActor
        @Test("a proof the server cannot use (mfa_not_enrolled) is dropped: the mint goes once more on the token")
        func notEnrolledFallsBackToToken() async throws {
            let posts = Posts()
            let notEnrolled = #"{"data":null,"error":"No second factor","meta":{"errorCode":"auth.stepup.mfa_not_enrolled"}}"#
            MockURLProtocol.install { req in
                posts.record(req)
                guard req.httpMethod == "POST" else {
                    return (
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":[],"error":null}"#.utf8)
                    )
                }
                let refused = req.value(forHTTPHeaderField: "X-Step-Up") != nil
                return (
                    HTTPURLResponse(url: req.url!, statusCode: refused ? 401 : 201, httpVersion: nil, headerFields: nil)!,
                    Data((refused ? notEnrolled : Self.minted).utf8)
                )
            }
            let store = try makeStore()
            store.stepUp.supply(Self.elevation)

            #expect(await store.mintToken(name: "Claude", scope: .read))
            #expect(posts.stepUps == [Self.elevation, nil])
            #expect(store.error == nil)
            #expect(store.stepUp.isRequested == false)
        }

        @MainActor
        @Test("a waived proof lets exactly the next mint go on the token")
        func waiverIsSpentOnce() async throws {
            let posts = Posts()
            install(posts)
            let store = try makeStore()

            #expect(await store.mintToken(name: "Claude", scope: .read) == false)
            #expect(store.stepUp.isRequested)
            store.waiveProof()
            #expect(store.stepUp.isRequested == false)
            #expect(store.error == nil)
            #expect(await store.mintToken(name: "Claude", scope: .read))
            #expect(posts.stepUps == [nil])
            #expect(await store.mintToken(name: "Second", scope: .read) == false)
            #expect(posts.stepUps.count == 1)
        }

        @MainActor
        @Test("closing the mint sheet drops a waiver too")
        func abandonDropsWaiver() async throws {
            let posts = Posts()
            install(posts)
            let store = try makeStore()
            store.waiveProof()
            store.abandonMint()
            #expect(await store.mintToken(name: "Claude", scope: .read) == false)
            #expect(posts.stepUps.isEmpty)
        }

        @MainActor
        @Test("a store built without a gate asks for the proof")
        func defaultGateIsClosed() async throws {
            let posts = Posts()
            install(posts)
            let store = try McpStore(repo: McpRepository(api: makeAPI()))
            #expect(await store.mintToken(name: "Claude", scope: .read) == false)
            #expect(posts.stepUps.isEmpty)
            #expect(store.stepUp.isRequested)
        }

        // MARK: - No other way in

        @Test("no deep link or push path reaches the mint", arguments: [
            "healthlog://mcp", "healthlog://mcp/tokens?name=x&scope=read_write",
            "healthlog://settings/mcp", "healthlog://settings/mcp?mint=1",
            "healthlog://settings/mcp/tokens/new?scope=read_write"
        ])
        func noDeepLinkMints(_ raw: String) throws {
            let url = try #require(URL(string: raw))
            #expect(DeepLinkRoute(url: url) == .unknown(url))
        }

        @Test("a push path or universal link for the MCP page opens home at most")
        func noPushOrUniversalLinkMints() throws {
            #expect(DeepLinkRoute.fromPushPath("/settings/mcp?mint=1&scope=read_write") == .dashboard)
            let link = try #require(URL(string: "https://test.healthlog.local/settings/mcp?mint=1"))
            #expect(DeepLinkRoute.universalLink(link, expectedHost: "test.healthlog.local") == nil)
        }
    }

    // MARK: - Which proofs the sheet offers

    @Suite("SEC: step-up arms follow the account's proof methods")
    struct StepUpArmsTests {
        @Test("an older server (no list) keeps the 1.4 choice")
        func olderServer() {
            let open = StepUpArms(requiresFresh: false, hasTotp: false, proofMethods: nil)
            #expect(open == StepUpArms(requiresFresh: false, hasTotp: false, proofMethods: ["password", "passkey"]))
            #expect(open.passkey && open.password && !open.totp)
            let fresh = StepUpArms(requiresFresh: true, hasTotp: true, proofMethods: nil)
            #expect(fresh.passkey && fresh.totp && !fresh.password)
        }

        @Test("only the proofs the account names, never the browser-only ones")
        func narrowedByList() {
            let noPasskey = StepUpArms(requiresFresh: false, hasTotp: false, proofMethods: ["password"])
            #expect(noPasskey.password && !noPasskey.passkey && !noPasskey.totp)
            let secondFactor = StepUpArms(requiresFresh: true, hasTotp: true, proofMethods: ["totp", "webauthn"])
            #expect(secondFactor.totp && !secondFactor.passkey && !secondFactor.password)
            #expect(secondFactor.nothingInApp == false)
        }

        @Test("an account with nothing the app can prove is told so", arguments: [
            [String](), ["webauthn"], ["oidc"]
        ])
        func nothingInApp(_ methods: [String]) {
            let fresh = methods == ["webauthn"]
            let arms = StepUpArms(requiresFresh: fresh, hasTotp: false, proofMethods: methods.filter { $0 != "oidc" })
            #expect(arms.nothingInApp)
        }

        @Test("oidc never reaches the picker, even when a server sends it")
        func oidcNeverOffered() throws {
            let json = #"{"totp":{"enabled":false},"recoveryCodesRemaining":0,"webauthn":[],"#
                + #""passkeyNudgeDismissed":false,"proofMethods":["oidc","password"]}"#
            let status = try JSONDecoder().decode(MfaStatus.self, from: Data(json.utf8))
            #expect(status.offeredProofMethods == ["password"])
        }
    }

#endif
