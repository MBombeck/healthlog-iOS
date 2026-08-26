import Foundation

// CU-34 (Brief C6) — the Today-hero-item slice of the widgets layout. Its own
// file (file-length discipline, and it keeps the score-ring slice untouched);
// the wire field itself lives on `DashboardWidgetLayout` with the contract
// doc-comment.

public extension DashboardWidgetLayout {
    /// **CU-34 — set which item kinds may appear in the Today hero rail.**
    ///
    /// Returns a layout that SENDS `enabledHeroItemKinds`, i.e. the one path
    /// that actually changes the server's stored choice; every other helper
    /// leaves the field `nil` so an unrelated save omits it and the server
    /// preserves what is stored. Widgets, version and the ring fields ride
    /// through untouched (they carry their own preserve-when-absent contract).
    ///
    /// Passing an **empty array is meaningful and is not the same as not
    /// calling this at all**: it produces a layout whose encoded body carries
    /// `"enabledHeroItemKinds": []`, which the server reads as "no kind may
    /// appear" — the rail stays empty. "Leave it alone" is expressed by simply
    /// not going through this helper.
    ///
    /// Deduped and re-ordered into the canonical ``HeroItemKind/allCases``
    /// sequence, mirroring the server's `coerceEnabledHeroItemKinds`
    /// (`dashboard-layout.ts:559-566`) so the optimistic local layout is
    /// byte-equal to what the next GET echoes.
    func settingEnabledHeroItemKinds(_ kinds: [HeroItemKind]) -> DashboardWidgetLayout {
        let enabled = Set(kinds)
        return DashboardWidgetLayout(
            version: version,
            widgets: widgets,
            enabledHeroItemKinds: HeroItemKind.allCases
                .filter(enabled.contains)
                .map(\.rawValue)
        )
    }

    /// The kinds currently allowed in the Today hero rail, parsed back into the
    /// closed set (unknown/future tokens ignored) and canonically ordered.
    ///
    /// A `nil` field resolves to **every** kind, not to none: the server's own
    /// resolver treats missing legacy data as "all current kinds enabled"
    /// (`dashboard-layout.ts:559-560`), and a client that guessed "none" would
    /// paint an empty picker for a user whose rail is in fact fully on. An
    /// explicitly stored `[]` stays `[]` — that is the user's "all off".
    var resolvedEnabledHeroItemKinds: [HeroItemKind] {
        guard let enabledHeroItemKinds else { return HeroItemKind.allCases }
        let enabled = Set(enabledHeroItemKinds.compactMap(HeroItemKind.init(rawValue:)))
        return HeroItemKind.allCases.filter(enabled.contains)
    }

    /// True when the layout carries an explicit choice, as opposed to a server
    /// too old to know the field. Lets a surface tell "the user switched
    /// everything off" apart from "we have no idea" without inspecting the raw
    /// optional at the call site.
    var hasExplicitHeroItemKindSelection: Bool {
        enabledHeroItemKinds != nil
    }
}
