import Foundation
@testable import HealthLog
import Testing

/// **#115 B5 — the account zone and glucose unit reach the widget extension.**
///
/// `ProfileTimeZoneBox` mirrored the account zone into the app's own
/// `UserDefaults.standard`, a domain the widget extension cannot read, so every
/// day key cut there (``ProfileDay``) fell back to the device zone; the glucose
/// unit had no shared copy at all. ``SharedAccountPrefs`` puts both into the App
/// Group, stamped with the signed-in account, and the box seeds from it.
///
/// Every case runs on an isolated suite and a stub user id — never the real App
/// Group, never the Keychain.
@Suite("#115 B5 — account prefs shared with the extension", .mockURLSession)
struct SharedAccountPrefsTests {
    /// Mutable user id the stub Keychain answers with.
    final class User: @unchecked Sendable {
        var id: String?
        init(_ id: String?) {
            self.id = id
        }
    }

    /// Counts the watch re-pushes the wiring triggers.
    final class Counter: @unchecked Sendable {
        var value = 0
    }

    private func suite(_ name: String) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "b5.\(name).\(UUID().uuidString)"))
    }

    private func prefs(_ defaults: UserDefaults, _ user: User) -> SharedAccountPrefs {
        SharedAccountPrefs(defaults: defaults, currentUserID: { user.id })
    }

    private func zone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    // MARK: - The mirror itself

    @Test("a value written for the signed-in account reads back for that account")
    func roundTripForTheSameAccount() throws {
        let shared = try prefs(suite("rt"), User("user-a"))
        let tokyo = try zone("Asia/Tokyo")
        shared.setTimeZone(tokyo)
        shared.setGlucoseUnit(.mmolL)
        #expect(shared.timeZone() == tokyo)
        #expect(shared.glucoseUnit() == .mmolL)
    }

    @Test("another account never reads the previous account's values")
    func otherAccountReadsNothing() throws {
        let defaults = try suite("other")
        let user = User("user-a")
        let shared = prefs(defaults, user)
        try shared.setTimeZone(zone("Asia/Tokyo"))
        shared.setGlucoseUnit(.mmolL)

        user.id = "user-b"
        #expect(shared.timeZone() == nil)
        #expect(shared.glucoseUnit() == nil)

        user.id = nil
        #expect(shared.timeZone() == nil, "signed out reads nothing")
    }

    @Test("the first write of a new account drops the old account's leftovers")
    func newAccountWriteClearsLeftovers() throws {
        let defaults = try suite("restamp")
        let user = User("user-a")
        let shared = prefs(defaults, user)
        try shared.setTimeZone(zone("Asia/Tokyo"))
        shared.setGlucoseUnit(.mmolL)

        user.id = "user-b"
        try shared.setTimeZone(zone("Europe/Berlin"))

        #expect(shared.glucoseUnit() == nil, "re-stamping must not hand A's unit to B")
        #expect(try shared.timeZone() == zone("Europe/Berlin"))
    }

    @Test("without a signed-in account nothing is written")
    func noAccountNoWrite() throws {
        let defaults = try suite("nouser")
        let shared = prefs(defaults, User(nil))
        try shared.setTimeZone(zone("Asia/Tokyo"))
        shared.setGlucoseUnit(.mmolL)
        #expect(defaults.string(forKey: SharedAccountPrefs.timeZoneKey) == nil)
        #expect(defaults.string(forKey: SharedAccountPrefs.glucoseUnitKey) == nil)
    }

    @Test("logout clears every entry")
    func clearRemovesEverything() throws {
        let defaults = try suite("clear")
        let shared = prefs(defaults, User("user-a"))
        try shared.setTimeZone(zone("Asia/Tokyo"))
        shared.setGlucoseUnit(.mmolL)
        shared.clear()
        for key in [SharedAccountPrefs.userIDKey, SharedAccountPrefs.timeZoneKey, SharedAccountPrefs.glucoseUnitKey] {
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    // MARK: - The box in the extension process

    /// The widget extension's view: its own `.standard` is empty, the app never
    /// ran in this process. Before B5 the box answered the device zone here.
    @Test("a box in a process without the app's mirror seeds from the shared account zone")
    func extensionBoxSeedsFromShared() throws {
        let appGroup = try suite("ext-group")
        let user = User("user-a")
        let away = try awayZone()
        prefs(appGroup, user).setTimeZone(away)

        let extensionBox = try ProfileTimeZoneBox(defaults: suite("ext-standard"), sharedPrefs: prefs(appGroup, user))

        #expect(extensionBox.current == away, "the extension must cut the account's days, not the device's")
    }

    @Test("an extension box ignores another account's shared zone")
    func extensionBoxIgnoresOtherAccount() throws {
        let appGroup = try suite("ext-other")
        let writer = User("user-a")
        try prefs(appGroup, writer).setTimeZone(awayZone())

        let extensionBox = try ProfileTimeZoneBox(
            defaults: suite("ext-other-standard"),
            sharedPrefs: prefs(appGroup, User("user-b"))
        )

        #expect(extensionBox.current == .current)
    }

    @Test("the app's box writes every pushed zone into the shared mirror")
    func appBoxMirrorsIntoShared() throws {
        let appGroup = try suite("app-group")
        let user = User("user-a")
        let appBox = try ProfileTimeZoneBox(defaults: suite("app-standard"), sharedPrefs: prefs(appGroup, user))
        let berlin = try zone("Europe/Berlin")

        appBox.update(berlin)

        #expect(prefs(appGroup, user).timeZone() == berlin)
    }

    /// Update path: an install that resolved its zone before this build has it in
    /// the app mirror only. The container copies it across once.
    @Test("an existing install's app mirror is copied into an empty shared entry, never over one")
    func updatePathCopiesAppMirrorOnce() throws {
        let appGroup = try suite("upd-group")
        let appStandard = try suite("upd-standard")
        let user = User("user-a")
        let away = try awayZone()
        appStandard.set(away.identifier, forKey: ProfileTimeZoneBox.defaultsKey)

        ProfileTimeZoneBox(defaults: appStandard, sharedPrefs: prefs(appGroup, user)).mirrorIntoSharedIfUnset()
        #expect(prefs(appGroup, user).timeZone() == away)

        // A shared entry that exists (a later `/me` push) is never overwritten
        // by the older app mirror.
        let berlin = try zone("Europe/Berlin")
        prefs(appGroup, user).setTimeZone(berlin)
        ProfileTimeZoneBox(defaults: appStandard, sharedPrefs: prefs(appGroup, user)).mirrorIntoSharedIfUnset()
        #expect(prefs(appGroup, user).timeZone() == berlin)
    }

    @Test("an install without an app mirror copies nothing")
    func updatePathWithoutMirrorIsNoOp() throws {
        let appGroup = try suite("upd-none")
        let user = User("user-a")
        try ProfileTimeZoneBox(defaults: suite("upd-none-standard"), sharedPrefs: prefs(appGroup, user))
            .mirrorIntoSharedIfUnset()
        #expect(appGroup.string(forKey: SharedAccountPrefs.timeZoneKey) == nil)
    }

    // MARK: - The composition root's glucose wiring

    @MainActor
    @Test("the container copies the current glucose unit and every later change into the shared mirror")
    func wiringMirrorsGlucoseUnit() throws {
        let appGroup = try suite("wire-group")
        let user = User("user-a")
        let shared = prefs(appGroup, user)
        let settings = try SettingsStore(repo: SettingsRepository(api: makeAPIClient()), defaults: suite("wire-settings"))
        settings.glucoseUnit = .mmolL
        let watchPushes = Counter()

        try AppContainer.wireSharedAccountPrefs(
            settingsStore: settings,
            profileTimeZoneBox: ProfileTimeZoneBox(defaults: suite("wire-box"), sharedPrefs: shared),
            sharedPrefs: shared,
            onGlucoseUnitChange: { watchPushes.value += 1 }
        )
        #expect(shared.glucoseUnit() == .mmolL, "the update path: the unit the app shows right now")

        settings.glucoseUnit = .mgdL
        #expect(shared.glucoseUnit() == .mgdL)
        #expect(watchPushes.value == 1, "the watch snapshot is re-pushed with the new unit, once")
    }

    // MARK: - Fixtures

    /// A zone the device is not in, so a pass cannot come from the fallback.
    private func awayZone() throws -> TimeZone {
        try zone(TimeZone.current.identifier == "Asia/Tokyo" ? "America/Los_Angeles" : "Asia/Tokyo")
    }

    private func makeAPIClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "300"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }
}
