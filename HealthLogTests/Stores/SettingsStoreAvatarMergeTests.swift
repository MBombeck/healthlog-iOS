import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.8.1 WD — avatar-persist fix.**
///
/// Locks the merge that makes an uploaded avatar survive a profile-driven
/// reload. The server returns `avatarUrl` ONLY on `GET /api/auth/me` —
/// `GET /api/user/profile` omits it — so without this merge the photo reverts
/// to the initials monogram on every reload (reads as "save failed").
///
/// Drives the real `APIClient` (not a mock-server) through `MockURLProtocol`
/// so the request-building, envelope-decode, and date-strategy paths are the
/// exact ones production uses — catching schema-drift the way the 0.2.0 audit
/// demands. Routes responses by URL path so `/profile`, `/auth/me`, and
/// `/integrations/healthkit` each answer independently.
@MainActor
@Suite("SettingsStore avatar merge (auth/me)", .serialized)
struct SettingsStoreAvatarMergeTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeStore() -> SettingsStore {
        let repo = SettingsRepository(api: makeClient())
        let suiteName = "SettingsStoreAvatarMergeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // No SWR coordinator → exercises the `loadDirect` path, which fans out
        // profile + hk-config + the /auth/me avatar merge.
        return SettingsStore(repo: repo, defaults: defaults)
    }

    /// Routes a `MockURLProtocol` handler by path. `profileAvatarUrl` is the
    /// `avatarUrl` echoed by `/api/user/profile` (server omits it today → nil);
    /// `meAvatarUrl` is the URL echoed by `/api/auth/me`.
    private func installRouter(profileAvatarUrl: String?, meAvatarUrl: String?) {
        let profileJSON: String = {
            let avatar = profileAvatarUrl.map { "\"\($0)\"" } ?? "null"
            return """
            {"data":{"username":"anna","displayName":"Anna","email":"anna@example.com",\
            "avatarUrl":\(avatar),"dateOfBirth":null,"gender":null,"heightCm":175,\
            "locale":"de","timezone":"Europe/Berlin","moodReminderEnabled":false},"error":null}
            """
        }()
        let meJSON: String = {
            let avatar = meAvatarUrl.map { "\"\($0)\"" } ?? "null"
            return """
            {"data":{"id":"u1","username":"anna","email":"anna@example.com",\
            "avatarUrl":\(avatar)},"error":null}
            """
        }()
        let hkJSON = #"{"data":{"entries":[],"lastSyncedAt":null},"error":null}"#

        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let body: String
            switch path {
            case "/api/user/profile": body = profileJSON
            case "/api/auth/me": body = meJSON
            case "/api/integrations/healthkit": body = hkJSON
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
    }

    @Test("auth/me avatarUrl is merged into the profile when /profile omits it")
    func mergesAvatarFromAuthMe() async {
        installRouter(
            profileAvatarUrl: nil,
            meAvatarUrl: "/api/user/avatar/u1?v=1716800000000"
        )
        let store = makeStore()

        await store.load()

        // /profile gave us a profile WITHOUT avatarUrl; /auth/me supplied it.
        #expect(store.profile != nil)
        #expect(store.profile?.avatarUrl == "/api/user/avatar/u1?v=1716800000000")
        #expect(store.profile?.displayName == "Anna")
        #expect(store.error == nil)
    }

    @Test("Post-upload refresh re-reads auth/me so the avatarUrl persists (does not revert to nil)")
    func refreshPersistsAvatarURL() async {
        // Simulate the post-upload `refreshProfile()` → `load()`: /profile still
        // omits avatarUrl, but /auth/me now carries the freshly-uploaded URL.
        installRouter(
            profileAvatarUrl: nil,
            meAvatarUrl: "/api/user/avatar/u1?v=1716899999999"
        )
        let store = makeStore()

        await store.load()
        #expect(store.profile?.avatarUrl == "/api/user/avatar/u1?v=1716899999999")

        // A second reload (e.g. tab re-mount) must keep the URL, not revert.
        await store.load()
        #expect(store.profile?.avatarUrl == "/api/user/avatar/u1?v=1716899999999")
    }

    @Test("avatarUrl stays nil (initials fallback) when neither source has it")
    func nilWhenNeitherSourceHasIt() async {
        installRouter(profileAvatarUrl: nil, meAvatarUrl: nil)
        let store = makeStore()

        await store.load()

        #expect(store.profile != nil)
        #expect(store.profile?.avatarUrl == nil)
        #expect(store.error == nil)
    }

    @Test("Prefers the /profile avatarUrl when the server starts echoing it (no /me override)")
    func prefersProfileAvatarWhenPresent() async {
        // Future server: /profile echoes avatarUrl. /auth/me carries a STALE one;
        // the merge must NOT clobber the profile's own value.
        installRouter(
            profileAvatarUrl: "/api/user/avatar/u1?v=PROFILE",
            meAvatarUrl: "/api/user/avatar/u1?v=STALE_ME"
        )
        let store = makeStore()

        await store.load()

        #expect(store.profile?.avatarUrl == "/api/user/avatar/u1?v=PROFILE")
    }
}

/// **v0.8.1 WD** — repository-level contract for the new `/auth/me` avatar read.
@Suite("SettingsRepository.authMeAvatarURL", .serialized)
struct SettingsRepositoryAuthMeTests {
    private func makeRepo() -> SettingsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return SettingsRepository(
            api: APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        )
    }

    @Test("GET /api/auth/me decodes avatarUrl from the envelope")
    func decodesAvatarURL() async throws {
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            let json = #"{"data":{"id":"u1","username":"anna","avatarUrl":"/api/user/avatar/u1?v=42"},"error":null}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let repo = makeRepo()
        let url = try await repo.authMeAvatarURL()
        #expect(capturedPath == "/api/auth/me")
        #expect(url == "/api/user/avatar/u1?v=42")
    }

    @Test("GET /api/auth/me tolerates a null avatarUrl (no photo uploaded)")
    func tolerantNullAvatar() async throws {
        MockURLProtocol.handler = { req in
            let json = #"{"data":{"id":"u1","username":"anna","avatarUrl":null},"error":null}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let repo = makeRepo()
        let url = try await repo.authMeAvatarURL()
        #expect(url == nil)
    }

    @Test("GET /api/auth/me tolerates an omitted avatarUrl key (older server)")
    func tolerantMissingKey() async throws {
        MockURLProtocol.handler = { req in
            let json = #"{"data":{"id":"u1","username":"anna"},"error":null}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let repo = makeRepo()
        let url = try await repo.authMeAvatarURL()
        #expect(url == nil)
    }
}

// swiftlint:enable force_unwrapping
