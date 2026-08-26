// Diese Suite ruft HealthKit-Symbole — bleibt aus dem SPM-Test-Build raus.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    @Suite("HealthKitService anchor partition")
    struct HealthKitAnchorPartitionTests {
        // MARK: - partitionToken-Heuristik

        @Test("Leerer / nil User-ID -> _anonymous Token")
        func nilUserIDToAnonymous() {
            #expect(HealthKitService.partitionToken(for: nil) == "_anonymous")
            #expect(HealthKitService.partitionToken(for: "") == "_anonymous")
            #expect(HealthKitService.partitionToken(for: "  ") == "_anonymous")
        }

        @Test("UUID-Format wird unverändert verwendet")
        func uuidUserIDPassthrough() {
            let uuid = "11111111-2222-3333-4444-555555555555"
            #expect(HealthKitService.partitionToken(for: uuid) == uuid)
        }

        @Test("Punkte im User-ID werden gestripped (sonst Key-Suffix-Kollision)")
        func userIDDotStripping() {
            // M-6 (v0.6.2): allowlist `[A-Za-z0-9_-]` drops every disallowed
            // character. Dots are not in the allowlist, so they vanish (the
            // legacy behaviour replaced them with underscores; we drop now to
            // make the partition determined purely by the surviving-safe
            // chars and avoid aliasing two distinct ids that differ only in
            // their punctuation pattern).
            #expect(HealthKitService.partitionToken(for: "user.with.dots") == "userwithdots")
        }

        // MARK: - clearAnchors per Partition

        @Test("clearAnchors löscht NUR Schlüssel des angegebenen Users")
        func clearAnchorsScopedToUser() throws {
            let suiteName = "HKAnchorPartitionTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let token = HealthKitService.partitionToken(for: "userA")
            let otherToken = HealthKitService.partitionToken(for: "userB")
            let prefix = HealthKitService.anchorDefaultsKeyPrefix

            // Persist eine "Anchor"-Repraesentation pro User.
            defaults.set(Data([0xAA]), forKey: prefix + token + ".HKQuantityTypeIdentifierBodyMass")
            defaults.set(Data([0xBB]), forKey: prefix + token + ".HKQuantityTypeIdentifierHeartRate")
            defaults.set(Data([0xCC]), forKey: prefix + otherToken + ".HKQuantityTypeIdentifierBodyMass")

            HealthKitService.clearAnchors(for: "userA", in: defaults)

            #expect(defaults.data(forKey: prefix + token + ".HKQuantityTypeIdentifierBodyMass") == nil)
            #expect(defaults.data(forKey: prefix + token + ".HKQuantityTypeIdentifierHeartRate") == nil)
            // userB-Anchor bleibt unangetastet.
            #expect(defaults.data(forKey: prefix + otherToken + ".HKQuantityTypeIdentifierBodyMass") != nil)
        }

        @Test("clearAnchors mit nil User-ID löscht nur die _anonymous-Partition")
        func clearAnchorsAnonymous() throws {
            let suiteName = "HKAnchorPartitionTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let prefix = HealthKitService.anchorDefaultsKeyPrefix
            let anonKey = prefix + "_anonymous.HKQuantityTypeIdentifierStepCount"
            let userKey = prefix + "usr_realuser.HKQuantityTypeIdentifierStepCount"
            defaults.set(Data([0x11]), forKey: anonKey)
            defaults.set(Data([0x22]), forKey: userKey)

            HealthKitService.clearAnchors(for: nil, in: defaults)

            #expect(defaults.data(forKey: anonKey) == nil)
            #expect(defaults.data(forKey: userKey) != nil)
        }

        // MARK: - Defensive — anchorKey-Format bleibt stabil

        @Test("Anchor-Key Prefix ist `hl.healthkit.anchor.` — Bumps brechen Production-Anchors")
        func keyPrefixIsLocked() {
            // Drift hier würde alle existierenden Anchors auf User-Geräten stranden
            // lassen (sie würden unter dem alten Prefix ungelesen bleiben). Bewusst
            // hard-coded.
            #expect(HealthKitService.anchorDefaultsKeyPrefix == "hl.healthkit.anchor.")
        }
    }

#endif
