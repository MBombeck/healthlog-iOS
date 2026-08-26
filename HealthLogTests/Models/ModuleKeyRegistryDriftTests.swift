import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// **Drift guard — iOS `ModuleKey` vs. the server module registry.**
///
/// iOS fell behind the server registry twice: three keys (`environment`,
/// `mentalHealth`, `mcp`) were missing entirely and a fourth (`medications`)
/// was still classified as CORE long after the server graduated it to a real
/// user toggle. Both drifts were silent — nothing in the build or the suite
/// noticed, because a missing enum case simply means `ModuleKey.from(wireKey:)`
/// returns `nil` and the surface renders ungated.
///
/// This suite makes the next drift loud. ``ModuleKeyServerRegistryFixture``
/// below is a hand-maintained transcription of the server's advertised module
/// keys; the tests assert the iOS enum equals it exactly, in both directions,
/// so a server-side addition fails here until someone adds the case.
///
/// **When the server adds a module:** add the wire key to the fixture AND the
/// case to ``ModuleKey`` in the same commit. Editing only the fixture to go
/// green defeats the entire point of the guard.
@Suite("ModuleKey — server registry drift guard")
@MainActor
struct ModuleKeyRegistryDriftTests {
    @Test("iOS ModuleKey set == the server's advertised module keys")
    func matchesServerRegistry() {
        let ios = Set(ModuleKey.allCases.map(\.wireKey))
        let server = ModuleKeyServerRegistryFixture.allKeys

        // Reported as two directed differences so a failure names the drift
        // instead of dumping two opaque sets.
        let missingOnIOS = server.subtracting(ios)
        let unknownToServer = ios.subtracting(server)
        #expect(missingOnIOS.isEmpty, "server keys with no iOS case — surfaces will render ungated")
        #expect(unknownToServer.isEmpty, "iOS cases the server no longer advertises — dead toggles")
        #expect(ios == server)
    }

    @Test("Registry fixture size is pinned (a silently shrunk fixture cannot pass)")
    func fixtureSizePinned() {
        // Guards the failure mode where someone "fixes" a drift failure by
        // deleting fixture rows rather than adding the enum case.
        #expect(ModuleKeyServerRegistryFixture.allKeys.count == 18)
        #expect(ModuleKey.allCases.count == 18)
    }

    @Test("Every server key round-trips through ModuleKey.from(wireKey:)")
    func everyServerKeyParses() {
        for key in ModuleKeyServerRegistryFixture.allKeys.sorted() {
            let parsed = ModuleKey.from(wireKey: key)
            #expect(parsed != nil, "unparseable server module key: \(key)")
            #expect(parsed?.wireKey == key)
        }
    }

    @Test("The three keys added in Build 2 / 2.6 exist and carry the right defaults")
    func build2AddedKeys() {
        #expect(ModuleKey.from(wireKey: "environment") == .environment)
        #expect(ModuleKey.from(wireKey: "mentalHealth") == .mentalHealth)
        #expect(ModuleKey.from(wireKey: "mcp") == .mcp)
        // All three are ordinary user toggles — none is delegated or core.
        #expect(ModuleKey.environment.isUserToggleable)
        #expect(ModuleKey.mentalHealth.isUserToggleable)
        #expect(ModuleKey.mcp.isUserToggleable)
        // Default-ON keys resolve ON when the map omits them; the gate is
        // default-on for every key, so an opt-in module reads OFF only when the
        // server actually says `false`.
        let gate = ModuleGate(modules: ["mcp": false])
        #expect(gate.isEnabled(.mcp) == false)
        #expect(gate.isEnabled(.mentalHealth) == true, "absent key → on")
        #expect(gate.isEnabled(.environment) == true, "absent key → on")
    }

    @Test("medications is a real toggle, not a CORE pre-stage")
    func medicationsIsToggleable() {
        // The drift that made the iOS settings screen tell the user medications
        // could not be switched off, ~a year after the server allowed it.
        #expect(ModuleKey.medications.isUserToggleable)
        #expect(!ModuleKey.coreNonToggleable.contains(.medications))
        #expect(ModuleKey.coreNonToggleable.isEmpty)
        #expect(SettingsModulesScreen.offeredKeys.contains(.medications))
        #expect(ModuleGate(modules: ["medications": false]).isEnabled(.medications) == false)
    }

    @Test("Only cycle + coach are withheld from the switchboard")
    func onlyDelegatedWithheld() {
        let offered = Set(SettingsModulesScreen.offeredKeys.map(\.wireKey))
        let withheld = ModuleKeyServerRegistryFixture.allKeys.subtracting(offered)
        #expect(withheld == ["cycle", "coach"], "only DELEGATED keys may be withheld")
    }

    @Test("Every offered toggle has a distinct title and subtitle")
    func everyToggleHasDistinctCopy() {
        // `displayTitle`/`displaySubtitle` are `LocalizedStringKey`: not resolvable
        // to a String outside a SwiftUI render, and Equatable but NOT Hashable —
        // so no Set. Pairwise comparison over ~18 modules is free and still
        // catches the real risk: a copy-pasted row that kept its neighbour's copy.
        //
        // UI-Standard R2/R6 (U5): `displaySubtitle` is now optional — a row
        // whose title already carries the whole statement has none. `nil` is
        // therefore not a duplicate; only two rows sharing the SAME copy are.
        var titles: [LocalizedStringKey] = []
        var subtitles: [LocalizedStringKey] = []
        for key in SettingsModulesScreen.offeredKeys {
            #expect(!titles.contains(key.displayTitle), "duplicate module title on \(key.wireKey)")
            titles.append(key.displayTitle)
            guard let subtitle = key.displaySubtitle else { continue }
            #expect(!subtitles.contains(subtitle), "duplicate module subtitle on \(key.wireKey)")
            subtitles.append(subtitle)
        }
    }

    @Test("Only nutrients + mcp are genuinely opt-in server-side")
    func onlyOptInModulesAreOptIn() {
        // Build 2 / 2.6 fixed iOS subtitles that falsely called `illness` and
        // `inboundDocuments` "off by default" — both are DEFAULT-ON server-side.
        // The corrected copy itself cannot be asserted here (`LocalizedStringKey`
        // does not resolve outside a render), so this pins the SEMANTIC fact the
        // copy has to follow. If this set ever changes, the subtitles must be
        // re-read by hand.
        let optIn: Set<ModuleKey> = [.nutrients, .mcp]
        #expect(!optIn.contains(.illness), "illness is default-on server-side")
        #expect(!optIn.contains(.inboundDocuments), "inboundDocuments is default-on since v1.29.1")
        for key in optIn {
            #expect(SettingsModulesScreen.offeredKeys.contains(key), "\(key.wireKey) must be offered as a toggle")
        }
    }
}

/// Checked-in transcription of the server's advertised module keys.
///
/// Source of truth: `MODULE_KEYS` in the server repo's
/// `src/lib/modules/registry.ts` (verified against the registry on 2026-07-19,
/// server v1.29.1). Order below mirrors the registry's declaration order, which
/// is also its Settings display order.
///
/// The three always-on CORE domains (`weight`, `bloodPressure`, `pulse`) are
/// deliberately **absent** — server-side they are `CORE_DOMAIN_KEYS`, not
/// module keys, they never appear in the `/api/auth/me` `modules` map, and a
/// PATCH naming one is rejected. They must never gain a `ModuleKey` case.
enum ModuleKeyServerRegistryFixture {
    static let orderedKeys: [String] = [
        "cycle",
        "mood",
        "sleep",
        "glucose",
        "workouts",
        "recovery",
        "labs",
        "illness",
        "achievements",
        "coach",
        "insights",
        "medications",
        "doctorReport",
        "environment",
        "mcp",
        "inboundDocuments",
        "mentalHealth",
        "nutrients"
    ]

    static let allKeys: Set<String> = Set(orderedKeys)

    /// Keys the server marks `optIn: true` — shipped OFF until the user turns
    /// them on. Everything else in the registry is default-ON.
    static let optInKeys: Set<String> = ["mcp", "nutrients"]

    /// Keys whose state is owned by another resolver; a PATCH naming one is
    /// `422 modules.invalid`.
    static let delegatedKeys: Set<String> = ["cycle", "coach"]

    /// The server's always-on core domains — asserted NOT to be module keys.
    static let coreDomainKeys: Set<String> = ["weight", "bloodPressure", "pulse"]
}

@Suite("ModuleKey — registry fixture self-consistency")
struct ModuleKeyRegistryFixtureTests {
    @Test("Fixture has no duplicate rows")
    func noDuplicates() {
        #expect(
            ModuleKeyServerRegistryFixture.orderedKeys.count
                == ModuleKeyServerRegistryFixture.allKeys.count
        )
    }

    @Test("Core domains are never module keys")
    func coreDomainsAreNotModules() {
        for core in ModuleKeyServerRegistryFixture.coreDomainKeys.sorted() {
            #expect(ModuleKey.from(wireKey: core) == nil, "\(core) is a CORE domain, not a module")
            #expect(!ModuleKeyServerRegistryFixture.allKeys.contains(core))
        }
    }

    @Test("Delegated + opt-in subsets are drawn from the registry")
    func subsetsAreConsistent() {
        #expect(ModuleKeyServerRegistryFixture.delegatedKeys
            .isSubset(of: ModuleKeyServerRegistryFixture.allKeys))
        #expect(ModuleKeyServerRegistryFixture.optInKeys
            .isSubset(of: ModuleKeyServerRegistryFixture.allKeys))
        // The iOS delegated set must mirror the fixture's.
        #expect(Set(ModuleKey.delegated.map(\.wireKey)) == ModuleKeyServerRegistryFixture.delegatedKeys)
    }
}
