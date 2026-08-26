import Foundation
@testable import HealthLog
import Testing

/// **SAFETY — CRISIS-RESOURCE DRIFT TRIPWIRE (audit C1 / RELIABILITY M4).**
///
/// `CrisisResourceFallback` bundles the PHQ-9 item-9 crisis hotlines VERBATIM from
/// the server `crisis-resources.ts` (`crisisResourcesForLocale`). They are a
/// clinical-safety surface: an offline / deploy-skewed client renders these exact
/// numbers to someone who just flagged item-9, so a silent drift = a wrong or dead
/// number with NO other test failing.
///
/// This suite is the lockstep guard. The canonical expected sets below are the
/// pinned copy of the server data (`release/v1.25.0`, verified 2026-06-28). Every
/// bundled emergency number, resource id, and contact line is asserted by FULL
/// structural equality (`CrisisResourceSet: Equatable`) — so editing ANY digit,
/// url, id, or ordering fails here loudly. It also pins the coarse locale→region
/// mapping EXACTLY as the server computes it, and proves `forLocale` is total
/// (always returns an actionable set, never an empty / nil one).
///
/// ⚠️ If this fails after an intentional server change: re-verify these fixtures
/// against `crisis-resources.ts` at the current `release/vX`, update BOTH the
/// production `CrisisResourceFallback` and the expectations below, and bump the
/// verification date in the header comment. Do NOT relax the assertions.
///
/// Pure (no network, no global `MockURLProtocol` handler) → no `.serialized`
/// needed and immune to the cross-suite handler-stomping flakiness landmine.
@Suite("Crisis-resource fallback lockstep (v1.25, verified 2026-06-28)")
struct CrisisResourceFallbackLockstepTests {
    // MARK: - Canonical expected fixtures (pinned copy of server `crisis-resources.ts`)

    /// International (default, incl. plain "en") — emergency 112.
    private static let expectedInternational = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"]),
            CrisisResource(id: "euEmotionalSupport", contacts: ["116 123"])
        ]
    )

    /// German-speaking ("de*") — the server's combined **DE/AT/CH** set. Emergency 112.
    ///
    /// **2026-07-19 (Parity 1.6b):** this used to pin the Germany-only four. The
    /// server returns the combined set for a bare `de` code, because `User.locale`
    /// carries no region — a Swiss or Austrian user was otherwise handed German
    /// freephone numbers that do not connect from their country
    /// (`src/lib/mental-health/crisis-resources.ts`, `DE_AT_CH`). iOS now mirrors
    /// that, so the offline fallback matches what the server would have sent.
    ///
    /// Composition is the server's verbatim: each country's own lines first
    /// (their individual `findahelpline` dropped), then the worldwide directory
    /// exactly once at the end.
    private static let expectedGermanSpeaking = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(
                id: "telefonSeelsorge",
                contacts: ["0800 111 0 111", "0800 111 0 222", "telefonseelsorge.de"]
            ),
            CrisisResource(id: "nummerGegenKummer", contacts: ["116 111"]),
            CrisisResource(id: "krisenchat", contacts: ["krisenchat.de"]),
            CrisisResource(id: "telefonSeelsorgeAt", contacts: ["142", "telefonseelsorge.at"]),
            CrisisResource(id: "dargeboteneHand", contacts: ["143", "143.ch"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// United States ("en-us" / "en_us*" / "us") — 988 + Crisis Text Line. Emergency 911.
    private static let expectedUnitedStates = CrisisResourceSet(
        emergencyNumber: "911",
        resources: [
            CrisisResource(id: "lifeline988", contacts: ["988"]),
            CrisisResource(id: "crisisTextLine", contacts: ["Text HOME to 741741"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    // MARK: - Full-set lockstep (every number pinned, all three regions)

    @Test("International set matches the pinned server fixture byte-for-byte")
    func internationalSetInLockstep() {
        #expect(CrisisResourceFallback.forLocale("en") == Self.expectedInternational)
        #expect(CrisisResourceFallback.forLocale(nil) == Self.expectedInternational)
        // Spot-pin the individual literals so a diff names the drifted number.
        let intl = CrisisResourceFallback.forLocale("en")
        #expect(intl.emergencyNumber == "112")
        #expect(intl.resources.map(\.id) == ["findahelpline", "euEmotionalSupport"])
        #expect(intl.resources.first { $0.id == "euEmotionalSupport" }?.contacts == ["116 123"])
        #expect(intl.resources.first { $0.id == "findahelpline" }?.contacts == ["findahelpline.com"])
    }

    @Test("German-speaking (DE/AT/CH) set matches the pinned server fixture byte-for-byte")
    func germanySetInLockstep() {
        #expect(CrisisResourceFallback.forLocale("de") == Self.expectedGermanSpeaking)
        let de = CrisisResourceFallback.forLocale("de")
        #expect(de.emergencyNumber == "112")
        #expect(de.resources.map(\.id) == [
            "telefonSeelsorge", "nummerGegenKummer", "krisenchat",
            "telefonSeelsorgeAt", "dargeboteneHand", "findahelpline"
        ])
        // TelefonSeelsorge — the two national lines + the web address, in order.
        #expect(de.resources.first { $0.id == "telefonSeelsorge" }?.contacts
            == ["0800 111 0 111", "0800 111 0 222", "telefonseelsorge.de"])
        // Nummer gegen Kummer youth line.
        #expect(de.resources.first { $0.id == "nummerGegenKummer" }?.contacts == ["116 111"])
        #expect(de.resources.first { $0.id == "krisenchat" }?.contacts == ["krisenchat.de"])
        // AT + CH lines — the reason the combined set exists. A German-speaking
        // user outside Germany must reach a number that connects from their country.
        #expect(de.resources.first { $0.id == "telefonSeelsorgeAt" }?.contacts == ["142", "telefonseelsorge.at"])
        #expect(de.resources.first { $0.id == "dargeboteneHand" }?.contacts == ["143", "143.ch"])
    }

    @Test("United States set matches the pinned server fixture byte-for-byte")
    func unitedStatesSetInLockstep() {
        #expect(CrisisResourceFallback.forLocale("en-US") == Self.expectedUnitedStates)
        let us = CrisisResourceFallback.forLocale("en-US")
        #expect(us.emergencyNumber == "911")
        #expect(us.resources.map(\.id) == ["lifeline988", "crisisTextLine", "findahelpline"])
        #expect(us.resources.first { $0.id == "lifeline988" }?.contacts == ["988"])
        #expect(us.resources.first { $0.id == "crisisTextLine" }?.contacts == ["Text HOME to 741741"])
    }

    // MARK: - Coarse locale→region mapping (mirrors `crisisResourcesForLocale` EXACTLY)

    /// 2026-07-19 (Parity 1.6b): `de-AT` / `de_CH` moved OUT of this list. The
    /// resolver now mirrors the server's five branches exactly, and an explicit
    /// region hint resolves to that country's own set — only a REGIONLESS `de*`
    /// falls through to the combined DE/AT/CH set. Covered below.
    @Test("regionless de* → German-speaking DE/AT/CH set (case-insensitive)", arguments: [
        "de", "DE", "de-DE", "de_DE", "de-de"
    ])
    func mapsGermanPrefixes(_ locale: String) {
        #expect(CrisisResourceFallback.forLocale(locale) == Self.expectedGermanSpeaking)
    }

    @Test("explicit Austrian locale → Austria only (142 connects, 0800-numbers do not)", arguments: [
        "de-AT", "de_AT", "at", "AT", "DE-AT"
    ])
    func mapsAustrianLocales(_ locale: String) {
        let at = CrisisResourceFallback.forLocale(locale)
        #expect(at.emergencyNumber == "112")
        #expect(at.resources.map(\.id) == ["telefonSeelsorgeAt", "findahelpline"])
        #expect(at.resources.first { $0.id == "telefonSeelsorgeAt" }?.contacts == ["142", "telefonseelsorge.at"])
    }

    @Test("explicit Swiss locale → Switzerland only (143 connects)", arguments: [
        "de-CH", "de_CH", "ch", "CH", "DE-CH"
    ])
    func mapsSwissLocales(_ locale: String) {
        let ch = CrisisResourceFallback.forLocale(locale)
        #expect(ch.emergencyNumber == "112")
        #expect(ch.resources.map(\.id) == ["dargeboteneHand", "findahelpline"])
        #expect(ch.resources.first { $0.id == "dargeboteneHand" }?.contacts == ["143", "143.ch"])
    }

    @Test("en-us / en_us* / us → United States (case-insensitive)", arguments: [
        "en-us", "en-US", "en_us", "en_US", "en_US_POSIX", "us", "US"
    ])
    func mapsUnitedStatesLocales(_ locale: String) {
        #expect(CrisisResourceFallback.forLocale(locale) == Self.expectedUnitedStates)
    }

    @Test("everything else → International (incl. plain en, en-GB, other langs, empty, nil)", arguments: [
        "en", "en-GB", "en-CA", "en-AU", "fr", "fr-FR", "es", "pt-BR", "", "  ", "xx", "german"
    ])
    func mapsOtherLocalesToInternational(_ locale: String) {
        #expect(CrisisResourceFallback.forLocale(locale) == Self.expectedInternational)
    }

    @Test("nil locale → International")
    func nilLocaleIsInternational() {
        #expect(CrisisResourceFallback.forLocale(nil) == Self.expectedInternational)
    }

    // MARK: - Totality: `forLocale` always returns something actionable

    @Test("forLocale is total — every input yields a non-empty, actionable set", arguments: [
        "de", "en", "en-US", "us", "fr", "", "  ", "xx", "de-DE", "en_us", "🚑", "123"
    ])
    func forLocaleAlwaysActionable(_ locale: String) {
        let set = CrisisResourceFallback.forLocale(locale)
        // Non-optional by type; assert it is genuinely actionable, not an empty shell.
        #expect(!set.emergencyNumber.isEmpty)
        #expect(!set.resources.isEmpty)
        // Every resource carries at least one concrete contact line.
        for resource in set.resources {
            #expect(!resource.id.isEmpty)
            #expect(!resource.contacts.isEmpty)
            #expect(resource.contacts.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        }
    }

    @Test("every bundled region set is one of the three canonical fixtures (no fourth path)")
    func onlyThreeCanonicalSets() {
        let all = [
            CrisisResourceFallback.forLocale("de"),
            CrisisResourceFallback.forLocale("en-US"),
            CrisisResourceFallback.forLocale("en")
        ]
        #expect(Set([Self.expectedGermanSpeaking, Self.expectedUnitedStates, Self.expectedInternational].map(\.emergencyNumber))
            == ["112", "911"])
        #expect(all == [Self.expectedGermanSpeaking, Self.expectedUnitedStates, Self.expectedInternational])
    }
}
