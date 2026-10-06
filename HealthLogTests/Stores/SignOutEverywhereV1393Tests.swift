// R2 / #115 A7 — "sign out everywhere" on server v1.39.3+.
//
// Server contract at tag v1.39.6 (`src/app/api/auth/me/sessions/route.ts`):
// `DELETE /api/auth/me/sessions[?keepShareLinks=1]` also revokes AI-assistant
// connections, every API token except the caller's, clinician share links
// (unless kept) and pending invitations, and answers
// `{ sessionsRevoked, accessTokensRevoked, connectorsRevoked, shareLinksRevoked,
//    pendingInvitesRevoked, grantsKept: [{ id, account: { id, username,
//    displayName }, access }] }`.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Sign out everywhere — v1.39.3 reach (R2 / A7)", .serialized, .mockURLSession)
    struct SignOutEverywhereV1393Tests {
        private final class Wire: @unchecked Sendable {
            private let lock = NSLock()
            /// The query of every DELETE (`nil` = none).
            private var deleteQueries: [String?] = []
            func record(_ req: URLRequest) {
                lock.lock()
                defer { lock.unlock() }
                if req.httpMethod == "DELETE" { deleteQueries.append(req.url?.query) }
            }

            var deletes: [String?] {
                lock.lock()
                defer { lock.unlock() }
                return deleteQueries
            }
        }

        private static let v1396Answer = #"""
        {"data":{"sessionsRevoked":2,"accessTokensRevoked":3,"connectorsRevoked":1,"shareLinksRevoked":4,
        "pendingInvitesRevoked":1,"grantsKept":[
        {"id":"g1","account":{"id":"u2","username":"anna","displayName":"Anna Berg"},"access":"read"},
        {"id":"g2","account":{"id":"u3","username":"ben","displayName":null},"access":"read"},
        {"id":"g3","account":"not-an-object","access":"read"},
        {"account":{"id":"u4","username":"nobody"}}
        ]},"error":null}
        """#

        private func makeAPI() -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        }

        private func install(_ wire: Wire, deleteAnswer: String = v1396Answer) {
            MockURLProtocol.install { req in
                wire.record(req)
                let json = req.httpMethod == "DELETE" ? deleteAnswer : #"{"data":{"sessions":[]},"error":null}"#
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
        }

        @MainActor
        private func makeStore(version: String) -> SessionsStore {
            SessionsStore(
                repo: SessionsRepository(api: makeAPI()),
                serverVersion: { ServerVersionInfo(version: version) }
            )
        }

        // MARK: - Decode

        @Test("the v1.39.6 answer decodes, a malformed grant row is dropped, not fatal")
        func decodesFullAnswer() throws {
            let envelope = try JSONDecoder.hlDefault.decode(
                APIEnvelope<SessionRevokeOthersResponse>.self,
                from: Data(Self.v1396Answer.utf8)
            )
            let answer = try #require(envelope.data)
            #expect(answer.sessionsRevoked == 2)
            #expect(answer.accessTokensRevoked == 3)
            #expect(answer.connectorsRevoked == 1)
            #expect(answer.shareLinksRevoked == 4)
            #expect(answer.pendingInvitesRevoked == 1)
            // g3 keeps its id (account unreadable → no name), the id-less row goes.
            #expect(answer.grantsKept.map(\.id) == ["g1", "g2", "g3"])
            #expect(answer.grantsKept.map(\.label) == ["Anna Berg", "ben", nil])
        }

        @Test("an older server's { sessionsRevoked } still decodes")
        func decodesOldAnswer() throws {
            let envelope = try JSONDecoder.hlDefault.decode(
                APIEnvelope<SessionRevokeOthersResponse>.self,
                from: Data(#"{"data":{"sessionsRevoked":1},"error":null}"#.utf8)
            )
            let answer = try #require(envelope.data)
            #expect(answer.sessionsRevoked == 1)
            #expect(answer.connectorsRevoked == nil)
            #expect(answer.grantsKept.isEmpty)
        }

        // MARK: - Version gate

        @Test("assistants, tokens and links end from v1.39.3 on")
        func versionGate() {
            #expect(SignOutEverywhereElse.endsConnectionsAndLinks(on: ServerVersionInfo(version: "1.39.3")))
            #expect(SignOutEverywhereElse.endsConnectionsAndLinks(on: ServerVersionInfo(version: "1.39.6")))
            #expect(SignOutEverywhereElse.endsConnectionsAndLinks(on: ServerVersionInfo(version: "1.39.2")) == false)
            #expect(SignOutEverywhereElse.endsConnectionsAndLinks(on: ServerVersionInfo(version: "garbage")) == false)
        }

        // MARK: - Store + wire

        @MainActor
        @Test("default: no query — the server's safe default ends the share links too")
        func defaultEndsLinks() async {
            let wire = Wire()
            install(wire)
            let store = makeStore(version: "1.39.6")
            await store.load()
            #expect(store.endsConnectionsAndLinks)
            await store.revokeOthers()
            #expect(wire.deletes == [nil])
            #expect(store.lastRevokedOthersCount == 2)
            #expect(store.lastRevokeOthersResult?.connectorsRevoked == 1)
            #expect(store.keptGrantNames == ["Anna Berg", "ben"])
        }

        @MainActor
        @Test("keep doctor links: the switch sends ?keepShareLinks=1")
        func keepLinksSendsQuery() async {
            let wire = Wire()
            install(wire)
            let store = makeStore(version: "1.39.6")
            await store.load()
            store.keepShareLinks = true
            await store.revokeOthers()
            #expect(wire.deletes == ["keepShareLinks=1"])
        }

        @MainActor
        @Test("below v1.39.3 the switch means nothing and is not sent")
        func oldServerIgnoresSwitch() async {
            let wire = Wire()
            install(wire, deleteAnswer: #"{"data":{"sessionsRevoked":0},"error":null}"#)
            let store = makeStore(version: "1.38.11")
            await store.load()
            #expect(store.endsConnectionsAndLinks == false)
            #expect(store.sparesThisDevice)
            store.keepShareLinks = true
            await store.revokeOthers()
            #expect(wire.deletes == [nil])
            #expect(store.keptGrantNames.isEmpty)
        }

        @MainActor
        @Test("sign-out clears the result, the switch and the verdict")
        func clearOnLogout() async {
            let wire = Wire()
            install(wire)
            let store = makeStore(version: "1.39.6")
            await store.load()
            store.keepShareLinks = true
            await store.revokeOthers()
            store.clearOnLogout()
            #expect(store.lastRevokeOthersResult == nil)
            #expect(store.keepShareLinks == false)
            #expect(store.endsConnectionsAndLinks == false)
        }

        @Test("the v1.39.3 confirmation says assistants, tokens and doctor links end — in both languages")
        func confirmationCopy() throws {
            let catalog = try ParityCatalog.load()
            let all = try #require(catalog.strings["sessions.signOutAll.everything.confirmBody"])
            let keep = try #require(catalog.strings["sessions.signOutAll.everything.keepLinks.confirmBody"])
            for (language, words) in [
                ("en", ["assistants", "tokens", "doctor share links", "stays signed in"]),
                ("de", ["Assistenten", "Tokens", "Arzt-Links", "bleibt angemeldet"])
            ] {
                let allText = try #require(ParityCatalog.value(all, language: language))
                let keepText = try #require(ParityCatalog.value(keep, language: language))
                for word in words {
                    #expect(allText.contains(word), "\(language): \(word)")
                }
                #expect(keepText != allText)
            }
        }
    }

#endif
