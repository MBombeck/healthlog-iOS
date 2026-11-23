#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// #191 — the loser of a concurrent refresh gets `409 auth.refresh.superseded`.
    /// It is not terminal: the app re-reads the stored pair and never offers the
    /// token it sent again (that would be a replay, `401 auth.refresh.reuse`,
    /// which stays terminal).
    @Suite("A superseded refresh adopts the winner's pair", .serialized, .mockURLSession)
    struct RefreshSupersededTests {
        private static let protectedPath = "/api/measurements"
        private static let superseded: RVServer.Answer = { req in
            RVServer.reply(req, 409, #"{"data":null,"error":"Refresh superseded","meta":{"errorCode":"auth.refresh.superseded"}}"#)
        }

        private func protectedRead(_ session: RVSession) async throws {
            let request: APIRequest<EmptyPayload> = .get(Self.protectedPath)
            try await session.api.sendVoid(request)
        }

        @Test("classified on its own, superseded is transient; reuse stays terminal")
        func classification() {
            let superseded = HLError.server(status: 409, code: RefreshOutcome.supersededCode, message: "superseded")
            #expect(RefreshOutcome.isSuperseded(superseded))
            #expect(RefreshOutcome.classify(superseded) == .transient)
            let reuse = HLError.server(status: 401, code: "auth.refresh.reuse", message: "reuse")
            #expect(!RefreshOutcome.isSuperseded(reuse))
            #expect(RefreshOutcome.classify(reuse) == .authFailure)
        }

        @Test("the winner already stored its pair: the request goes out with that bearer, nobody is signed out")
        func adoptsStoredWinner() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            let keychain = session.keychain
            RVServer.install(
                refresh: { req in
                    // The concurrent winner rotates and persists first.
                    try keychain.setString(RVSession.newBearer, forKey: KeychainKey.authToken)
                    try keychain.setString("refresh-winner", forKey: KeychainKey.refreshToken)
                    return try Self.superseded(req)
                },
                wire: wire
            )

            try await protectedRead(session)

            #expect(session.signOuts.value == 0)
            #expect(wire.all.count(where: { $0.path == RVServer.refreshPath }) == 1, "the sent token is never offered again")
            #expect(wire.all.last == .init(path: Self.protectedPath, bearer: RVSession.newBearer))
            #expect(keychain.getString(forKey: KeychainKey.refreshToken) == "refresh-winner")
        }

        @Test("the winner's pair is not there yet: the session stays and the old token is not retried")
        func keepsSessionWithoutWinner() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(refresh: Self.superseded, wire: wire)

            await #expect(throws: HLError.unauthorized) { try await protectedRead(session) }

            #expect(session.stillSignedIn, "superseded is no verdict on the session")
            #expect(wire.all.count(where: { $0.path == RVServer.refreshPath }) == 1)
        }

        @Test("a real replay still signs out")
        func reuseSignsOut() async throws {
            let session = try await RVSession.signedIn()
            let wire = RVWire()
            RVServer.install(
                refresh: { RVServer.reply($0, 401, #"{"data":null,"error":"reuse","meta":{"errorCode":"auth.refresh.reuse"}}"#) },
                wire: wire
            )

            await #expect(throws: HLError.unauthorized) { try await protectedRead(session) }

            #expect(session.signOuts.value >= 1)
        }
    }

#endif
