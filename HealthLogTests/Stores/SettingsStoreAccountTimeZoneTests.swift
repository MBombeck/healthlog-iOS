import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **#115 1.5 — the account zone comes from `/api/auth/me`.**
///
/// From v1.39 `/me` sends the zone the server cuts this account's days in:
/// `isValidTimezone(user.timezone) ? user.timezone : resolveServerDefaultTimezone()`
/// (`src/app/api/auth/me/route.ts`). `/api/user/profile` still returns the raw
/// column. For an account whose stored value the server does not accept, the two
/// differ, and only the `/me` zone matches the server's day keys. The zone rides
/// on the `/me` read the settings hydration already makes — no new request.
@MainActor
@Suite("SettingsStore account zone from /me (#115 1.5)", .serialized)
struct SettingsStoreAccountTimeZoneTests {
    private let session = MockURLProtocolSession()

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ path: String) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    private func makeStore() -> SettingsStore {
        let env = AppEnvironment(
            baseURL: session.baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: session.configuration)
        let defaults = UserDefaults(suiteName: "SettingsStoreAccountTimeZoneTests.\(UUID().uuidString)")!
        return SettingsStore(repo: SettingsRepository(api: api), defaults: defaults)
    }

    /// `/api/user/profile` carries the RAW column (here a bare offset the v1.39
    /// server no longer accepts); `/me` carries the resolved zone.
    private func install(meTimezone: String?, requests: Requests) {
        let profileJSON = """
        {"data":{"username":"anna","displayName":"Anna","email":"anna@example.com",\
        "avatarUrl":null,"dateOfBirth":null,"gender":null,"heightCm":175,\
        "locale":"de","timezone":"+02:00","moodReminderEnabled":false},"error":null}
        """
        session.install { req in
            let path = req.url?.path ?? ""
            requests.record(path)
            func ok(_ body: String) -> (HTTPURLResponse, Data?) {
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            switch path {
            case "/api/user/profile":
                return ok(profileJSON)
            case "/api/integrations/healthkit":
                return ok(#"{"data":{"entries":[],"lastSyncedAt":null},"error":null}"#)
            case "/api/auth/me":
                let zone = meTimezone.map { #","timezone":"\#($0)""# } ?? ""
                return ok(#"{"data":{"id":"u1","username":"anna","avatarUrl":null\#(zone)},"error":null}"#)
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
            }
        }
    }

    @Test("The /me zone wins over the raw profile column and is pushed to the day-key box")
    func adoptsMeZone() async {
        let requests = Requests()
        install(meTimezone: "America/Los_Angeles", requests: requests)
        let store = makeStore()
        let pushed = PushedZones()
        store.onProfileTimeZoneChange = { pushed.append($0) }

        await store.load()

        #expect(store.resolvedProfileTimeZone.identifier == "America/Los_Angeles")
        #expect(pushed.last?.identifier == "America/Los_Angeles")
        // Riding on the hydration's existing round-trips — nothing new.
        #expect(Set(requests.all) == ["/api/user/profile", "/api/integrations/healthkit", "/api/auth/me"])
        #expect(requests.all.count(where: { $0 == "/api/auth/me" }) == 1)
    }

    @Test("An older /me without the field falls back to the profile's zone, then the device's")
    func fallsBack() async {
        install(meTimezone: nil, requests: Requests())
        let store = makeStore()
        await store.load()
        // "+02:00" is not an IANA identifier Foundation resolves by name → device.
        #expect(store.accountTimeZoneIdentifier == nil)
        #expect(store.resolvedProfileTimeZone == (TimeZone(identifier: "+02:00") ?? .current))
    }

    @Test("Logout forgets the account's zone")
    func logoutClears() async {
        install(meTimezone: "Asia/Tokyo", requests: Requests())
        let store = makeStore()
        await store.load()
        #expect(store.accountTimeZoneIdentifier == "Asia/Tokyo")
        store.clearOnLogout()
        #expect(store.accountTimeZoneIdentifier == nil)
    }
}

private final class PushedZones: @unchecked Sendable {
    private let lock = NSLock()
    private var zones: [TimeZone] = []
    func append(_ zone: TimeZone) {
        lock.lock()
        zones.append(zone)
        lock.unlock()
    }

    var last: TimeZone? {
        lock.lock()
        defer { lock.unlock() }
        return zones.last
    }
}

// swiftlint:enable force_unwrapping
