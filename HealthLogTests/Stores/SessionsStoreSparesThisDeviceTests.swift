import Foundation
@testable import HealthLog
import Testing

/// **v1.38.11 — the sessions screen has to know which server it is talking to.**
///
/// `SignOutEverywhereElseGateTests` pins the threshold as a pure function. What
/// this suite pins is the part that would actually mislead a user: whether the
/// verdict reaches `SessionsStore.sparesThisDevice`, and what happens when the
/// version probe fails. A probe miss must not swap in the friendlier wording —
/// and must not cost the user the session list either.
@Suite("v1.38.11 — SessionsStore löst die Server-Version für die Copy auf")
struct SessionsStoreSparesThisDeviceTests {
    // MARK: - Stub

    /// Answers the one route the store's `load()` reaches — `GET
    /// /api/auth/me/sessions`. The version read is injected as a closure, so
    /// the stub never has to serve `/api/version`.
    private final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
        let sessions: [SessionEntry]

        init(sessions: [SessionEntry]) {
            self.sessions = sessions
        }

        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            guard let typed = SessionListResponse(sessions: sessions) as? T else {
                throw HLError.unknown("unexpected request shape: \(T.self)")
            }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    private static func entry() -> SessionEntry {
        SessionEntry(
            id: "sess-1",
            device: "Safari on macOS",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @MainActor
    private static func makeStore(
        serverVersion: @escaping @Sendable () async throws -> ServerVersionInfo
    ) -> SessionsStore {
        let repo = SessionsRepository(api: StubAPIClient(sessions: [entry()]))
        return SessionsStore(repo: repo, serverVersion: serverVersion)
    }

    // MARK: - Verdict

    @Test("ein Server ≥ 1.38.11 verschont dieses Gerät — die Copy darf das sagen")
    @MainActor
    func modernServerSparesThisDevice() async {
        let store = Self.makeStore(serverVersion: { ServerVersionInfo(version: "1.38.11") })
        #expect(store.sparesThisDevice == false, "vor load() ist nichts bekannt")
        await store.load()
        #expect(store.sparesThisDevice)
        #expect(store.sessions.count == 1)
    }

    @Test("ein Server < 1.38.11 meldet dieses Gerät mit ab — die alte Copy bleibt")
    @MainActor
    func olderServerKeepsHonestCopy() async {
        let store = Self.makeStore(serverVersion: { ServerVersionInfo(version: "1.38.10") })
        await store.load()
        #expect(store.sparesThisDevice == false)
        #expect(store.sessions.count == 1)
    }

    /// The version read is best-effort: it is a cosmetic input to the copy, not
    /// a precondition for the screen. A throwing probe leaves the conservative
    /// verdict AND still lists the sessions — the list is the security surface.
    @Test("eine fehlgeschlagene Versionsabfrage bleibt konservativ und kostet die Liste nicht")
    @MainActor
    func failedVersionProbeStaysConservative() async {
        let store = Self.makeStore(serverVersion: { throw HLError.unknown("offline") })
        await store.load()
        #expect(store.sparesThisDevice == false)
        #expect(store.sessions.count == 1, "die Sitzungsliste muss trotz Versions-Miss stehen")
        #expect(store.error == nil, "ein Versions-Miss ist kein Fehler, den der Nutzer sieht")
    }

    /// A newer server that later answers as an older one (host switch) must be
    /// able to take the friendlier wording away again.
    @Test("ein Wechsel auf einen älteren Server nimmt die freundlichere Copy zurück")
    @MainActor
    func verdictIsRecomputedOnEveryLoad() async {
        let version = VersionBox()
        let store = Self.makeStore(serverVersion: { await version.value() })
        await version.set("1.39.0")
        await store.load()
        #expect(store.sparesThisDevice)
        await version.set("1.38.10")
        await store.load()
        #expect(store.sparesThisDevice == false)
    }

    /// `clearOnLogout` has to drop the verdict with everything else — the next
    /// account may sit on a different server.
    @Test("clearOnLogout setzt das Server-Urteil zurück")
    @MainActor
    func logoutClearsVerdict() async {
        let store = Self.makeStore(serverVersion: { ServerVersionInfo(version: "1.39.0") })
        await store.load()
        #expect(store.sparesThisDevice)
        store.clearOnLogout()
        #expect(store.sparesThisDevice == false)
    }

    /// Mutable version source the injected closure reads through.
    private actor VersionBox {
        private var version = "1.38.11"

        func set(_ value: String) {
            version = value
        }

        func value() -> ServerVersionInfo {
            ServerVersionInfo(version: version)
        }
    }
}
