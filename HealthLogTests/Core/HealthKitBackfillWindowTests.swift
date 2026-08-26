import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

@Suite("HealthKitBackfillWindow")
struct HealthKitBackfillWindowTests {
    private static let referenceNow = Date(timeIntervalSince1970: 1_715_673_600) // 2024-05-14T08:00:00Z
    private static let utc = Calendar(identifier: .gregorian).withUTC()

    // MARK: - Lower-Bound-Berechnung pro Option

    @Test(
        "Lower-Bound = now - N (oder distantPast fuer .allTime)",
        arguments: [
            (HealthKitBackfillWindow.sevenDays, -7 * 86400.0),
            (HealthKitBackfillWindow.thirtyDays, -30 * 86400.0),
            (HealthKitBackfillWindow.ninetyDays, -90 * 86400.0)
        ]
    )
    func lowerBoundDayBased(window: HealthKitBackfillWindow, expectedDelta: TimeInterval) {
        let lb = window.lowerBound(now: Self.referenceNow, calendar: Self.utc)
        let delta = lb.timeIntervalSince(Self.referenceNow)
        // Tolerance fuer DST/Calendar-Edge-Cases (UTC ohne DST → 0 Drift, defensive
        // halten wir ±1h damit der Test in Calendar-Implementations-Aenderungen
        // robust bleibt).
        #expect(abs(delta - expectedDelta) < 3600)
    }

    @Test("oneYear → now minus exact 1 calendar year")
    func oneYearWindow() throws {
        let lb = HealthKitBackfillWindow.oneYear.lowerBound(now: Self.referenceNow, calendar: Self.utc)
        // 2024-05-14 minus 1 Jahr ist 2023-05-14 (egal ob 365 oder 366).
        let comps = Self.utc.dateComponents([.year, .month, .day], from: lb)
        let nowComps = Self.utc.dateComponents([.year, .month, .day], from: Self.referenceNow)
        let nowYear = try #require(nowComps.year)
        #expect(comps.year == nowYear - 1)
        #expect(comps.month == nowComps.month)
        #expect(comps.day == nowComps.day)
    }

    @Test("allTime → Date.distantPast (HK-Predicate-Caller wird in dem Fall nil zurueckliefern)")
    func allTimeWindow() {
        let lb = HealthKitBackfillWindow.allTime.lowerBound(now: Self.referenceNow, calendar: Self.utc)
        #expect(lb == .distantPast)
    }

    // MARK: - Defaults + Picker-Order

    @Test("Default ist .allTime (v0.10.0 operator-decided — komplette HK-History)")
    func defaultIsAllTime() {
        #expect(HealthKitBackfillWindow.default == .allTime)
    }

    @Test("Picker-Order = [7d, 30d, 90d, 1y, all]")
    func pickerOrder() {
        #expect(HealthKitBackfillWindow.pickerOrder == [
            .sevenDays, .thirtyDays, .ninetyDays, .oneYear, .allTime
        ])
    }

    @Test("Picker-Order deckt alle CaseIterable-Cases ab")
    func pickerOrderCoverage() {
        #expect(Set(HealthKitBackfillWindow.pickerOrder) == Set(HealthKitBackfillWindow.allCases))
    }

    // MARK: - Codable

    @Test("Roundtrip via JSON")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for window in HealthKitBackfillWindow.allCases {
            let data = try encoder.encode(window)
            let decoded = try decoder.decode(HealthKitBackfillWindow.self, from: data)
            #expect(decoded == window)
        }
    }
}

@Suite("HealthKitBackfillWindowStore persistence")
struct HealthKitBackfillWindowStoreTests {
    /// Frische Test-Suite-UserDefaults pro Aufruf — verhindert Test-Pollution.
    private static func freshDefaults(suite: String = #function) throws -> UserDefaults {
        let defaults = try #require(
            UserDefaults(suiteName: "test.\(suite).\(UUID().uuidString)"),
            "isolated UserDefaults suite must be constructible"
        )
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        return defaults
    }

    @Test("Persist + Load roundtrip mit User-ID")
    func roundtripWithUserId() throws {
        let defaults = try Self.freshDefaults()
        let keychain = InMemoryKeychain()
        try? keychain.setString("user-abc", forKey: KeychainKey.userID)

        HealthKitBackfillWindowStore.persist(.ninetyDays, keychain: keychain, defaults: defaults)
        let loaded = HealthKitBackfillWindowStore.load(keychain: keychain, defaults: defaults)
        #expect(loaded == .ninetyDays)
    }

    @Test("Load ohne persist → nil (Pre-Onboarding)")
    func loadWithoutPersistIsNil() throws {
        let defaults = try Self.freshDefaults()
        let keychain = InMemoryKeychain()
        let loaded = HealthKitBackfillWindowStore.load(keychain: keychain, defaults: defaults)
        #expect(loaded == nil)
    }

    @Test("Per-User-Partition: User A's Wahl bleibt unsichtbar fuer User B")
    func perUserPartition() throws {
        let defaults = try Self.freshDefaults()
        let keychain = InMemoryKeychain()

        try? keychain.setString("user-a", forKey: KeychainKey.userID)
        HealthKitBackfillWindowStore.persist(.oneYear, keychain: keychain, defaults: defaults)

        try? keychain.setString("user-b", forKey: KeychainKey.userID)
        let loadedB = HealthKitBackfillWindowStore.load(keychain: keychain, defaults: defaults)
        #expect(loadedB == nil)

        try? keychain.setString("user-a", forKey: KeychainKey.userID)
        let loadedA = HealthKitBackfillWindowStore.load(keychain: keychain, defaults: defaults)
        #expect(loadedA == .oneYear)
    }

    @Test("Anonymous-Partition: nil/empty userId mappen alle auf '_anonymous'")
    func anonymousPartition() {
        #expect(HealthKitBackfillWindowStore.partitionToken(for: nil) == "_anonymous")
        #expect(HealthKitBackfillWindowStore.partitionToken(for: "") == "_anonymous")
        #expect(HealthKitBackfillWindowStore.partitionToken(for: "   ") == "_anonymous")
    }

    @Test("Disallowed chars im UserId werden gestripped (Key-Shape-Sicherheit, M-6)")
    func dottedUserIdSanitized() {
        // v0.6.2 (M-6): allowlist `[A-Za-z0-9_-]` strips everything else,
        // including dots. Legacy behaviour replaced dots with underscores.
        #expect(HealthKitBackfillWindowStore.partitionToken(for: "a.b.c") == "abc")
    }

    @Test("Clear loescht NUR die Wahl des angegebenen Users")
    func clearScoped() throws {
        let defaults = try Self.freshDefaults()
        let keychain = InMemoryKeychain()

        try? keychain.setString("user-x", forKey: KeychainKey.userID)
        HealthKitBackfillWindowStore.persist(.sevenDays, keychain: keychain, defaults: defaults)

        try? keychain.setString("user-y", forKey: KeychainKey.userID)
        HealthKitBackfillWindowStore.persist(.ninetyDays, keychain: keychain, defaults: defaults)

        HealthKitBackfillWindowStore.clear(for: "user-x", defaults: defaults)

        try? keychain.setString("user-x", forKey: KeychainKey.userID)
        #expect(HealthKitBackfillWindowStore.load(keychain: keychain, defaults: defaults) == nil)

        try? keychain.setString("user-y", forKey: KeychainKey.userID)
        #expect(HealthKitBackfillWindowStore.load(keychain: keychain, defaults: defaults) == .ninetyDays)
    }

    @Test("Key-Prefix ist `hl.healthkit.backfillWindow.` — Bumps brechen Production-Wahlen")
    func keyPrefixLocked() {
        #expect(HealthKitBackfillWindowStore.defaultsKeyPrefix == "hl.healthkit.backfillWindow.")
        #expect(HealthKitBackfillWindowStore.key(for: "abc") == "hl.healthkit.backfillWindow.abc")
        #expect(HealthKitBackfillWindowStore.key(for: nil) == "hl.healthkit.backfillWindow._anonymous")
    }
}

// MARK: - Calendar helper

private extension Calendar {
    func withUTC() -> Calendar {
        var copy = self
        copy.timeZone = TimeZone(identifier: "UTC") ?? copy.timeZone
        return copy
    }
}
