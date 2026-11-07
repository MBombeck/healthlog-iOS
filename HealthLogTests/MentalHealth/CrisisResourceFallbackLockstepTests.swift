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
/// pinned copy of the server data (tag `v1.46.6`, re-pinned 2026-11-04 for
/// L10N-MH: Brazil, Portugal, the Netherlands, Belgium and the two combined
/// sets for a Portuguese or Dutch reader without a region). Every
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
@Suite("Crisis-resource fallback lockstep (server v1.46.6)")
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

    /// Brazil (bare "br" only) — CVV + SAMU as emergency number.
    private static let expectedBrazil = CrisisResourceSet(
        emergencyNumber: "192",
        resources: [
            CrisisResource(id: "cvv", contacts: ["188", "cvv.org.br/chat"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// Portugal ("pt-PT") — SNS 24 + SOS Voz Amiga. Emergency 112.
    private static let expectedPortugal = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "sns24", contacts: ["808 24 24 24"]),
            CrisisResource(id: "sosVozAmiga", contacts: ["213 544 545", "sosvozamiga.org"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// Portuguese without a region (`PT_BR_AMBIGUOUS`): 112 and the directory
    /// first, then both countries' lines.
    private static let expectedPortugueseSpeaking = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"]),
            CrisisResource(id: "cvv", contacts: ["188", "cvv.org.br/chat"]),
            CrisisResource(id: "samu", contacts: ["192"]),
            CrisisResource(id: "sns24", contacts: ["808 24 24 24"]),
            CrisisResource(id: "sosVozAmiga", contacts: ["213 544 545", "sosvozamiga.org"])
        ]
    )

    /// The Netherlands ("nl-NL") — 113 Zelfmoordpreventie. Emergency 112.
    private static let expectedNetherlands = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "zelfmoordpreventie113", contacts: ["113", "0800-0113", "113.nl"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// Belgium ("nl-BE" / "be") — Zelfmoordlijn 1813. Emergency 112.
    private static let expectedBelgium = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "zelfmoordlijn1813", contacts: ["1813", "zelfmoord1813.be"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// Dutch without a region (`NL_BE`): both lines, the directory once at the end.
    private static let expectedDutchSpeaking = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "zelfmoordpreventie113", contacts: ["113", "0800-0113", "113.nl"]),
            CrisisResource(id: "zelfmoordlijn1813", contacts: ["1813", "zelfmoord1813.be"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    // MARK: - Full-set lockstep (every number pinned, every region)

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
        "en", "en-GB", "en-CA", "en-AU", "en-PT", "en-BR", "en-BE", "en-NL", "fr", "fr-FR", "fr-BE", "es", "",
        "  ", "xx", "german", "brazil", "nlx"
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

    // MARK: - v1.46.6 regions

    @Test("Brazil, Portugal and Portuguese without a region match the pinned fixtures")
    func portugueseSetsInLockstep() {
        #expect(CrisisResourceFallback.forLocale("br") == Self.expectedBrazil)
        #expect(CrisisResourceFallback.forLocale("BR") == Self.expectedBrazil)
        for tag in ["pt-PT", "pt_PT", "pt-pt", "PT-PT"] {
            #expect(CrisisResourceFallback.forLocale(tag) == Self.expectedPortugal, "\(tag)")
        }
        for tag in ["pt", "pt-BR", "pt_BR", "pt-AO", "pt-MZ"] {
            #expect(CrisisResourceFallback.forLocale(tag) == Self.expectedPortugueseSpeaking, "\(tag)")
        }
    }

    @Test("The Netherlands, Belgium and Dutch without a region match the pinned fixtures")
    func dutchSetsInLockstep() {
        for tag in ["nl-NL", "nl_NL", "NL-nl"] {
            #expect(CrisisResourceFallback.forLocale(tag) == Self.expectedNetherlands, "\(tag)")
        }
        for tag in ["nl-BE", "nl_BE", "be", "BE"] {
            #expect(CrisisResourceFallback.forLocale(tag) == Self.expectedBelgium, "\(tag)")
        }
        for tag in ["nl", "NL", "nl-SR", "nl-DE", "nl_AW"] {
            #expect(CrisisResourceFallback.forLocale(tag) == Self.expectedDutchSpeaking, "\(tag)")
        }
    }

    /// The server's `replace("_", "-")` touches the first underscore only;
    /// the copy does the same, so `en_US_POSIX` stays US.
    @Test("Only the first underscore becomes a hyphen, as in JavaScript")
    func firstUnderscoreOnly() {
        #expect(CrisisResourceFallback.forLocale("en_US_POSIX") == Self.expectedUnitedStates)
        #expect(CrisisResourceFallback.forLocale("nl_BE_x") == Self.expectedDutchSpeaking)
        #expect(CrisisResourceFallback.forLocale("pt_PT_x") == Self.expectedPortugueseSpeaking)
    }

    /// Acceptance (e): what each reader gets through the tag the app sends
    /// (``AppLanguage/regionTag``), online from the server and offline from
    /// this copy alike.
    struct RegionCase: Sendable, CustomTestStringConvertible {
        let language: AppLanguage
        let region: String?
        let mustReach: [String]

        var testDescription: String {
            language.regionTag(region: region)
        }
    }

    @Test("The region tag the app sends picks the reader's country", arguments: [
        RegionCase(language: .nl, region: "BE", mustReach: ["1813"]),
        RegionCase(language: .nl, region: "NL", mustReach: ["113"]),
        RegionCase(language: .nl, region: nil, mustReach: ["113", "1813"]),
        RegionCase(language: .de, region: "AT", mustReach: ["142"]),
        RegionCase(language: .de, region: "DE", mustReach: ["0800 111 0 111", "142", "143"]),
        RegionCase(language: .en, region: "US", mustReach: ["988"]),
        RegionCase(language: .en, region: "PT", mustReach: ["116 123"])
    ])
    func regionTagPicksTheCountry(_ probe: RegionCase) {
        let (language, region, mustReach) = (probe.language, probe.region, probe.mustReach)
        let set = CrisisResourceFallback.forLocale(language.regionTag(region: region))
        let contacts = set.resources.flatMap(\.contacts)
        for line in mustReach {
            #expect(contacts.contains(line), "\(language.regionTag(region: region)) lacks \(line)")
        }
        if language == .nl, region == "BE" { #expect(!contacts.contains("113")) }
        if language == .nl, region == "NL" { #expect(!contacts.contains("1813")) }
        if language == .de, region == "AT" { #expect(!contacts.contains("0800 111 0 111")) }
        if language == .en, region == "PT" { #expect(set == Self.expectedInternational) }
    }

    /// #150: a Portuguese phone must never get the Brazilian lines alone,
    /// whatever the interface language.
    @Test("A Portuguese device never sees only Brazilian numbers", arguments: AppLanguage.allCases)
    func portugueseDeviceNeverBrazilOnly(language: AppLanguage) {
        let set = CrisisResourceFallback.forLocale(language.regionTag(region: "PT"))
        #expect(set != Self.expectedBrazil)
        #expect(set.emergencyNumber == "112")
        #expect(set.resources.contains { $0.id == "findahelpline" })
    }

    @Test("every bundled region set is one of the canonical fixtures (no extra path)")
    func onlyCanonicalSets() {
        let canonical = [
            Self.expectedInternational, Self.expectedGermanSpeaking, Self.expectedUnitedStates,
            Self.expectedBrazil, Self.expectedPortugal, Self.expectedPortugueseSpeaking,
            Self.expectedNetherlands, Self.expectedBelgium, Self.expectedDutchSpeaking
        ]
        let probes = [
            "de", "de-AT", "de-CH", "en-US", "en", "br", "pt-PT", "pt", "nl-NL", "nl-BE", "nl",
            "", "xx", "fr-CH", "en-GB"
        ]
        for probe in probes {
            let set = CrisisResourceFallback.forLocale(probe)
            let isCanonical = canonical.contains(set)
                || set.resources.map(\.id) == ["telefonSeelsorgeAt", "findahelpline"]
                || set.resources.map(\.id) == ["dargeboteneHand", "findahelpline"]
            #expect(isCanonical, "\(probe)")
        }
    }
}
