import Foundation
@testable import HealthLog
import Testing

/// **Audit B-7 — a background wake has nobody to push the profile zone.**
///
/// `ProfileTimeZoneBox` is fed from `SettingsStore.profile.didSet`, which only
/// fires once a screen has loaded a profile. A HealthKit background delivery
/// (`AppOwnedHealthCollection.install`) runs a whole sync pass before that: the
/// process was launched into the background, nothing mounted, no
/// `/api/user/profile` fetched. Seeded from `.current`, that pass cut a
/// travelling user's day rows in the DEVICE zone — the one path the rest of the
/// B-7 work could not reach, because there was no zone to reach for.
///
/// The box now mirrors the last resolved identifier into `UserDefaults` and
/// reads it back at construction. These cases pin both directions plus the
/// fallback, on an isolated suite (never the process store).
@Suite("Audit B-7 — the profile zone survives into a background wake")
struct ProfileTimeZoneSeedTests {
    private func suite(_ name: String) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "b7.\(name).\(UUID().uuidString)"))
    }

    private func zone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    // MARK: - The seeding rule

    @Test("a stored identifier this device can resolve seeds the box")
    func storedIdentifierSeeds() throws {
        let berlin = try zone("Europe/Berlin")
        #expect(ProfileTimeZoneBox.seedZone(identifier: "Europe/Berlin") == berlin)
    }

    @Test("an absent or unresolvable identifier falls back to the device zone")
    func invalidIdentifierFallsBack() {
        // Absent: a fresh install, or a launch before the first profile ever
        // loaded. Unresolvable: a stored identifier the system database has
        // since renamed away, or a corrupted value. Both mean the same thing —
        // this build knows no profile zone — and `.current` is what the box
        // has always answered in that case.
        #expect(ProfileTimeZoneBox.seedZone(identifier: nil) == .current)
        #expect(ProfileTimeZoneBox.seedZone(identifier: "") == .current)
        #expect(ProfileTimeZoneBox.seedZone(identifier: "Nowhere/Atlantis") == .current)
    }

    // MARK: - The box, end to end

    @Test("a fresh box over a seeded default resolves the profile zone before any profile load")
    func freshBoxResolvesSeededZone() throws {
        // This is the background-wake case: nothing has called `update` in this
        // process and nothing will before the sync pass reads the box.
        let defaults = try suite("seeded")
        let tokyo = try zone("Asia/Tokyo")
        defaults.set("Asia/Tokyo", forKey: ProfileTimeZoneBox.defaultsKey)

        let box = ProfileTimeZoneBox(defaults: defaults)

        #expect(box.current == tokyo, "the wake must cut its day rows in the profile zone, not the device's")
    }

    @Test("a fresh box over an unseeded default answers the device zone")
    func freshBoxWithoutSeedIsCurrent() throws {
        let defaults = try suite("empty")
        #expect(ProfileTimeZoneBox(defaults: defaults).current == .current)
    }

    @Test("a fresh box over a corrupt default answers the device zone")
    func freshBoxWithCorruptSeedIsCurrent() throws {
        let defaults = try suite("corrupt")
        defaults.set("Nowhere/Atlantis", forKey: ProfileTimeZoneBox.defaultsKey)
        #expect(ProfileTimeZoneBox(defaults: defaults).current == .current)
    }

    @Test("an update mirrors the identifier so the next launch starts on it")
    func updateMirrorsForTheNextLaunch() throws {
        let defaults = try suite("mirror")
        let berlin = try zone("Europe/Berlin")
        let box = ProfileTimeZoneBox(defaults: defaults)
        #expect(box.current == .current)

        box.update(berlin)

        #expect(box.current == berlin)
        #expect(defaults.string(forKey: ProfileTimeZoneBox.defaultsKey) == "Europe/Berlin")
        // A NEW box — the next launch, including one that never loads a profile.
        #expect(ProfileTimeZoneBox(defaults: defaults).current == berlin)
    }

    @Test("the first real profile emission overwrites a stale mirror")
    func profileEmissionWinsOverTheMirror() throws {
        // The mirror is a cache of the server's answer, not a second source of
        // truth: a user who moved home must not be pinned to last week's zone.
        let defaults = try suite("stale")
        defaults.set("Asia/Tokyo", forKey: ProfileTimeZoneBox.defaultsKey)
        let box = ProfileTimeZoneBox(defaults: defaults)
        let berlin = try zone("Europe/Berlin")

        box.update(berlin)

        #expect(box.current == berlin)
        #expect(defaults.string(forKey: ProfileTimeZoneBox.defaultsKey) == "Europe/Berlin")
    }

    // MARK: - The composition root's own seed (fix round 1)

    /// **The seed the container actually performs.** Every case above builds the
    /// box directly; none goes through the wiring entry point
    /// `AppContainer.init` uses, which is where the mirror was being destroyed.
    ///
    /// `wireMedicationDueTimeZone` runs inside the designated init, long before
    /// any `/api/user/profile` has landed — `SettingsStore.profile` is `nil`, so
    /// `resolvedProfileTimeZone` answers `.current`. Pushing that answer is not
    /// a statement about the user's zone; it is the absence of one, and it
    /// overwrote both the seeded box AND the `UserDefaults` mirror with the
    /// device zone on every single launch, including the background wake the
    /// mirror exists for.
    @MainActor
    @Test("the container's wiring seed leaves the mirrored zone alone while the profile is silent")
    func wiringSeedKeepsTheMirroredZone() throws {
        let defaults = try suite("wiring")
        // Whichever of the two this device is NOT, so the assertion cannot pass
        // by the mirror and the device zone happening to agree.
        let awayID = TimeZone.current.identifier == "Asia/Tokyo" ? "Europe/Berlin" : "Asia/Tokyo"
        let away = try zone(awayID)
        defaults.set(awayID, forKey: ProfileTimeZoneBox.defaultsKey)
        let box = ProfileTimeZoneBox(defaults: defaults)
        let settings = try makeSettingsStore()
        #expect(settings.profile == nil, "the container wires before the first profile load")

        try wire(settingsStore: settings, box: box)

        #expect(box.current == away, "a silent profile must not replace the mirrored zone with the device's")
        #expect(
            defaults.string(forKey: ProfileTimeZoneBox.defaultsKey) == awayID,
            "and it must not rewrite the mirror the NEXT wake reads"
        )
    }

    /// The other half of the same rule: a REAL profile emission is a genuine
    /// server statement and still lands, mirror included. The wiring installs
    /// that closure unconditionally, which is why the guard belongs on the seed
    /// and not on the push.
    @MainActor
    @Test("a real profile emission still pushes through the wiring, mirror included")
    func profileEmissionStillPushes() throws {
        let defaults = try suite("wiring-push")
        let box = ProfileTimeZoneBox(defaults: defaults)
        let settings = try makeSettingsStore()
        let berlin = try zone("Europe/Berlin")

        try wire(settingsStore: settings, box: box)
        settings.onProfileTimeZoneChange?(berlin)

        #expect(box.current == berlin)
        #expect(defaults.string(forKey: ProfileTimeZoneBox.defaultsKey) == "Europe/Berlin")
    }

    // MARK: - Wiring fixtures

    @MainActor
    private func makeSettingsStore() throws -> SettingsStore {
        try SettingsStore(repo: SettingsRepository(api: makeAPIClient()), defaults: suite("settings"))
    }

    /// The exact entry point `AppContainer.init` calls (`AppContainer.swift`
    /// → `configureRuntimeWiring` → here), with throwaway stores for the four
    /// consumers this case says nothing about.
    @MainActor
    private func wire(settingsStore: SettingsStore, box: ProfileTimeZoneBox) throws {
        let api = makeAPIClient()
        try AppContainer.wireMedicationDueTimeZone(
            medicationsStore: MedicationsStore(
                repo: MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            ),
            dashboardStore: DashboardStore(repo: DashboardRepository(api: api)),
            dailyBriefingStore: DailyBriefingStore(repo: InsightsRepository(api: api)),
            settingsStore: settingsStore,
            measurementsRepo: MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true)),
            profileTimeZoneBox: box
        )
    }

    private func makeAPIClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "1.0.2",
            buildNumber: "276"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }
}
