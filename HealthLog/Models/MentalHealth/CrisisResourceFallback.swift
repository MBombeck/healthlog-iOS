import Foundation

// DEFENSIVE client-bundled crisis-resource fallback for the PHQ-9 item-9
// safety path.
//
// On a positive item-9 the server returns the locale-resolved `crisis` set in the
// POST response — that is the authoritative source and is rendered when present.
// But a positive item-9 must NEVER go unsignposted, so the client ALSO bundles
// every set of the server's `src/lib/mental-health/crisis-resources.ts`
// (verbatim, server tag v1.46.6) and resolves one when:
//
//   - the upload fails / is offline (no 201 → no server `crisis`), OR
//   - the server fails the request or omits `crisis` despite `item9Flagged`
//     (deploy skew / older server), OR
//   - a flagged history row is re-opened (history never carries the set).
//
// ``forLocale(_:)`` is a line-for-line copy of `crisisResourcesForLocale`,
// including its `replace("_", "-")`, which in JavaScript replaces the FIRST
// underscore only. The store sends and resolves ``AppLanguage/regionTag``
// (`de-AT`, `nl-BE`, `en-US`, `en-PT`), so the fallback lands on the same set
// the server would have sent: 142 in Austria, 1813 in Belgium, 988 in the US,
// the international set for an English interface in Portugal (never the
// Brazilian lines alone). The NAMES are CLIENT i18n
// (`mentalHealth.crisisResource.<id>.name`, de, en and nl from the server's
// `messages/*.json`); only the contact lines + emergency numbers are literal
// here.
//
// ⚠️ MAINTENANCE: these phone numbers / URLs are a clinical-safety surface. They
// duplicate server-owned data and must be kept in lockstep with
// `crisis-resources.ts` (`CrisisResourceFallbackLockstepTests` pins v1.46.6).
// Stale numbers are a hazard.
public enum CrisisResourceFallback {
    /// International fallback (default, incl. plain "en") — emergency 112.
    static let international = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"]),
            CrisisResource(id: "euEmotionalSupport", contacts: ["116 123"])
        ]
    )

    /// Germany ("de*") — TelefonSeelsorge + youth lines. Emergency 112.
    static let germany = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(
                id: "telefonSeelsorge",
                contacts: ["0800 111 0 111", "0800 111 0 222", "telefonseelsorge.de"]
            ),
            CrisisResource(id: "nummerGegenKummer", contacts: ["116 111"]),
            CrisisResource(id: "krisenchat", contacts: ["krisenchat.de"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// Austria ("de-at" / "de_at" / "at") — Telefonseelsorge Österreich (142).
    /// Emergency 112.
    static let austria = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "telefonSeelsorgeAt", contacts: ["142", "telefonseelsorge.at"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// Switzerland ("de-ch" / "de_ch" / "ch") — Die Dargebotene Hand (143).
    /// Emergency 112.
    static let switzerland = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "dargeboteneHand", contacts: ["143", "143.ch"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// **Parity 1.6b — the combined DE/AT/CH set the server serves for a BARE
    /// "de".** `User.locale` is a short code, so a de-AT or de-CH user is
    /// indistinguishable from a de-DE one; serving the German freephone numbers
    /// alone left an Austrian or Swiss user in crisis looking at numbers that do
    /// not connect from their country. Leads with 112 (valid in all three), then
    /// each country's own line, with the worldwide directory exactly once at the
    /// end — byte-for-byte the composition of `DE_AT_CH` in the server's
    /// `crisis-resources.ts`. The two AT/CH resource NAMES exist in
    /// `Localizable.xcstrings` since 3cea342f, so raising the offline fallback
    /// to this set can no longer render raw keys.
    static let germanSpeaking = CrisisResourceSet(
        emergencyNumber: "112",
        resources: germany.resources.filter { $0.id != "findahelpline" }
            + austria.resources.filter { $0.id != "findahelpline" }
            + switzerland.resources.filter { $0.id != "findahelpline" }
            + [CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])]
    )

    /// United States ("en-us" / "en_us*" / "us") — 988 + Crisis Text Line.
    /// Emergency 911.
    static let unitedStates = CrisisResourceSet(
        emergencyNumber: "911",
        resources: [
            CrisisResource(id: "lifeline988", contacts: ["988"]),
            CrisisResource(id: "crisisTextLine", contacts: ["Text HOME to 741741"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// Brazil, reached only by the bare region code "br" — CVV by phone and
    /// chat, SAMU (192) as the emergency number.
    static let brazil = CrisisResourceSet(
        emergencyNumber: "192",
        resources: [
            CrisisResource(id: "cvv", contacts: ["188", "cvv.org.br/chat"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// Portugal ("pt-PT" / "pt_PT") — SNS 24 (option 4) and SOS Voz Amiga.
    /// Emergency 112.
    static let portugal = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "sns24", contacts: ["808 24 24 24"]),
            CrisisResource(id: "sosVozAmiga", contacts: ["213 544 545", "sosvozamiga.org"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// Portuguese with no region signal ("pt", "pt-BR", "pt-AO", …): 112 and
    /// the worldwide directory first, then Brazil's and Portugal's own lines,
    /// each named with its country (server `PT_BR_AMBIGUOUS`).
    static let portugueseSpeaking = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])]
            + brazil.resources.filter { $0.id != "findahelpline" }
            + [CrisisResource(id: "samu", contacts: ["192"])]
            + portugal.resources.filter { $0.id != "findahelpline" }
    )

    /// The Netherlands ("nl-NL" / "nl_NL") — 113 Zelfmoordpreventie. Emergency 112.
    static let netherlands = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "zelfmoordpreventie113", contacts: ["113", "0800-0113", "113.nl"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// Belgium ("nl-BE" / "nl_BE" / "be") — Zelfmoordlijn 1813. Emergency 112.
    static let belgium = CrisisResourceSet(
        emergencyNumber: "112",
        resources: [
            CrisisResource(id: "zelfmoordlijn1813", contacts: ["1813", "zelfmoord1813.be"]),
            CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])
        ]
    )

    /// Dutch with no region signal ("nl", "nl-SR", …): both countries' lines,
    /// then the worldwide directory once (server `NL_BE`).
    static let dutchSpeaking = CrisisResourceSet(
        emergencyNumber: "112",
        resources: netherlands.resources.filter { $0.id != "findahelpline" }
            + belgium.resources.filter { $0.id != "findahelpline" }
            + [CrisisResource(id: "findahelpline", contacts: ["findahelpline.com"])]
    )

    /// Resolve a bundled set from a locale string, line for line the server's
    /// `crisisResourcesForLocale` (v1.46.6). Always returns SOMETHING
    /// actionable (never `nil`).
    public static func forLocale(_ locale: String?) -> CrisisResourceSet {
        var lc = (locale ?? "").lowercased()
        // JavaScript `String.replace("_", "-")` replaces the first match only.
        if let underscore = lc.range(of: "_") {
            lc.replaceSubrange(underscore, with: "-")
        }
        if lc == "de-at" || lc == "at" { return austria }
        if lc == "de-ch" || lc == "ch" { return switzerland }
        if lc.hasPrefix("de") { return germanSpeaking }
        if lc.hasPrefix("en-us") || lc == "us" { return unitedStates }
        if lc == "br" { return brazil }
        if lc == "pt-pt" { return portugal }
        if lc == "pt" || lc.hasPrefix("pt-") { return portugueseSpeaking }
        if lc == "nl-nl" { return netherlands }
        if lc == "nl-be" || lc == "be" { return belgium }
        if lc == "nl" || lc.hasPrefix("nl-") { return dutchSpeaking }
        return international
    }
}
