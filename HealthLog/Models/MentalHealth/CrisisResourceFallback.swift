import Foundation

// v1.25 — DEFENSIVE client-bundled crisis-resource fallback for the PHQ-9 item-9
// safety path.
//
// On a positive item-9 the server returns the locale-resolved `crisis` set in the
// POST response — that is the authoritative source and is rendered when present.
// But a positive item-9 must NEVER go unsignposted, so the client ALSO bundles
// the same three sets (verbatim from the server `crisis-resources.ts`, verified
// 2026-06-28 against `release/v1.25.0`) and resolves one when:
//
//   - the upload fails / is offline (no 201 → no server `crisis`), OR
//   - the server returns `item9Flagged == true` but omits `crisis` (deploy skew /
//     older server), OR
//   - a flagged history row is re-opened (history never carries the set).
//
// Region detection mirrors the server's coarse locale-prefix logic EXACTLY
// (`crisisResourcesForLocale`): "de-at"/"at" → AT, "de-ch"/"ch" → CH, any other
// "de*" → the COMBINED DE/AT/CH set, "en-us" / "en_us*" / "us" → US, else
// INTERNATIONAL. iOS sends + resolves the app's display language ("de" / "en"),
// so a German-speaking user always gets TelefonSeelsorge and a plain-"en" user
// gets the international set (NOT US 988) — identical to the web. The NAMES are
// CLIENT i18n (`mentalHealth.crisisResource.<id>.name`); only the contact lines
// + emergency numbers are literal here.
//
// ⚠️ MAINTENANCE: these phone numbers / URLs are a clinical-safety surface. They
// duplicate server-owned data and must be kept in lockstep with
// `crisis-resources.ts`. Stale numbers are a hazard — needs an owner.
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

    /// Resolve a bundled set from a locale string, mirroring the server's coarse
    /// region detection verbatim (`crisisResourcesForLocale`). Always returns
    /// SOMETHING actionable (never `nil`).
    ///
    /// **Parity 1.6b** — the branch order now mirrors `crisisResourcesForLocale`
    /// exactly: region-qualified German tags resolve to their own country set,
    /// and a BARE "de" resolves to the combined DE/AT/CH set rather than
    /// Germany-only. Before this, the offline card contradicted the online one
    /// for every plain-"de" user — precisely the moment where the two surfaces
    /// disagreeing matters most.
    public static func forLocale(_ locale: String?) -> CrisisResourceSet {
        let lc = (locale ?? "").lowercased()
        if lc == "de-at" || lc == "de_at" || lc == "at" { return austria }
        if lc == "de-ch" || lc == "de_ch" || lc == "ch" { return switzerland }
        if lc.hasPrefix("de") { return germanSpeaking }
        if lc == "en-us" || lc.hasPrefix("en_us") || lc == "us" { return unitedStates }
        return international
    }
}
