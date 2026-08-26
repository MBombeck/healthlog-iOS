import Foundation

/// Wire-shape of `GET /api/mood/tags` (server v1.8.5 — structured mood-tag
/// taxonomy). The server returns the **already filtered + ordered**
/// `isActive` Category → Tag tree (`MoodTagCategory → MoodTag`); iOS renders
/// it as the Daylio-style tagging grid. Global reference data (one shared
/// catalog per deployment), so the read carries no per-user filter and no
/// encryption — cached SWR-style with a daily TTL like the other catalog
/// repos (`MeasurementCategoriesRepository`).
///
/// **Icons:** the server gives **Lucide** icon names (`Heart`, `Smile`,
/// `Dumbbell`, …) which are NOT SF Symbols. iOS maps each via
/// ``MoodTagSFSymbol`` (the research Lucide→SF-Symbol table) before render.
///
/// **Labels:** `labelKey` is an i18n key (`mood.tag.happy`,
/// `mood.tagCategory.feelings`) resolved client-side against
/// `Localizable.xcstrings` — the same key scheme the web app ships in its
/// `messages/{de,en}.json`, ported into iOS in this wave.
public struct MoodTagCatalog: Codable, Sendable, Equatable {
    public let categories: [MoodTagCategoryDTO]

    public init(categories: [MoodTagCategoryDTO]) {
        self.categories = categories
    }

    /// True when the catalog has no categories — the picker falls back to the
    /// bundled set so the surface never renders empty.
    public var isEmpty: Bool {
        categories.isEmpty || categories.allSatisfy(\.tags.isEmpty)
    }

    /// Flat lookup: tag-key → its localized label, across every category.
    /// Used by read-back chips so a stored `tagKey` renders its display text
    /// without re-walking the tree per chip.
    public func label(forTagKey key: String) -> String? {
        for category in categories {
            if let tag = category.tags.first(where: { $0.key == key }) {
                return tag.localizedLabel
            }
        }
        return nil
    }

    /// True iff `key` is a known structured-tag key in this catalog. Lets the
    /// read-back surface tell a structured tag (render as a catalog chip with
    /// an icon) from a legacy free-text tag.
    public func containsTag(_ key: String) -> Bool {
        categories.contains { cat in cat.tags.contains { $0.key == key } }
    }

    /// v1.13.0 — the dedicated server category key under which per-user custom
    /// tags arrive (`labelKey: mood.tagCategory.custom`, icon `Tag`).
    public static let customCategoryKey = "custom"

    /// The icon allow-list the server validates `POST/PATCH .../custom` against
    /// (Lucide names). Surfaced to the management create/edit UI as the icon
    /// picker's set; every entry resolves in ``MoodTagSFSymbol``. Default is
    /// `Tag`. Kept in server order so the picker reads predictably.
    ///
    /// v0.14.x (#21) — expanded from the original 22 to the **full** server
    /// catalog (`src/lib/mood/icon-catalog.ts`, 74 Lucide names, grouped
    /// emotions → activities → health → food → weather → places → misc). A web
    /// tag could already store any of these; the picker now offers them all and
    /// each maps to an SF Symbol via ``MoodTagSFSymbol``. Reconciled name-by-name
    /// against the server's published catalog (#21) — the list is exactly the
    /// 74 canonical names, no extras (`Gamepad2` was a client-only addition the
    /// server never validates against and was removed to match the catalog).
    public static let customIconAllowList: [String] = [
        // emotions
        "Smile", "Laugh", "Meh", "Frown", "Angry", "Heart", "HandHeart",
        "PartyPopper", "ThumbsUp", "CheckCircle", "AlertTriangle", "HelpCircle",
        "Swords", "Flame", "Zap", "Star", "Gift",
        // activities
        "Dumbbell", "Activity", "Footprints", "Bike", "Music", "Headphones",
        "Film", "BookOpen", "Book", "Briefcase", "GraduationCap",
        "Palette", "Camera", "Trees", "Mountain", "Plane", "Car", "ShoppingCart",
        "Phone", "Users", "User", "LogOut", "Banknote", "Clock",
        "SlidersHorizontal",
        // health
        "Pill", "Stethoscope", "Syringe", "Thermometer", "HeartPulse", "Brain",
        "Bath", "Bed", "BedDouble", "Moon", "MoonStar", "Cigarette",
        "CigaretteOff", "Baby",
        // food
        "Apple", "Pizza", "UtensilsCrossed", "Coffee", "Wine", "GlassWater",
        "CandyOff",
        // weather
        "Sun", "CloudSun", "Cloud", "CloudRain", "CloudMoon", "Leaf",
        // places
        "House", "Home",
        // misc
        "Tag", "Cat", "Dog"
    ]

    // v1.13.0 §★ — the interim client-side hide-sets are RETIRED. The server
    // effective `GET /api/mood/tags` (v1.13.0 LIVE) now returns the per-user set
    // (catalogue − hidden + customs) and omits hidden/inactive tags itself, so a
    // second client-side hide would double-hide. The picker no longer applies any
    // curated hide layer; the management screen's `?include=hidden` read + the
    // `PUT .../hidden` write are the single source of truth.

    /// v0.14.7 B3 — canonical xcstrings label key per RATED factor `key`. Used
    /// as a defensive fallback by ``MoodTagDTO/localizedLabel`` so a factor still
    /// renders its proper localized word (e.g. `factor_sadness` → "Traurigkeit")
    /// even when the server's `labelKey` for that factor doesn't match a ported
    /// key. The server `labelKey` still takes precedence whenever it resolves.
    public static let ratedFactorLabelKey: [String: String] = [
        "factor_work": "mood.tag.factorWork",
        "factor_sleep_quality": "mood.tag.factorSleepQuality",
        "factor_sadness": "mood.tag.factorSadness",
        "factor_stress": "mood.tag.factorStress",
        "factor_social": "mood.tag.factorSocial",
        "factor_conflict": "mood.tag.factorConflict"
    ]

    /// A RATED factor renders as a slider iff it is rated. v1.13.0 — the interim
    /// client-side rated-factor hide-set is retired; the effective server GET
    /// already omits the factors the operator trimmed, so any rated factor the
    /// server still emits is meant to render.
    public static func isVisibleRated(_ tag: MoodTagDTO) -> Bool {
        tag.isRated
    }

    /// Project a selection set into a stable, catalog-ordered key array
    /// (category order → tag order) so persisted `tagKeys` are deterministic
    /// and read-back chips render in a sensible sequence. Selected keys the
    /// catalog no longer lists (e.g. a tag deactivated server-side between
    /// pick + save) are appended at the end rather than dropped.
    public func orderedKeys(from selection: Set<String>) -> [String] {
        var ordered: [String] = []
        for category in categories {
            for tag in category.tags where selection.contains(tag.key) {
                ordered.append(tag.key)
            }
        }
        for key in selection where !ordered.contains(key) {
            ordered.append(key)
        }
        return ordered
    }
}

public struct MoodTagCategoryDTO: Codable, Sendable, Equatable, Identifiable {
    /// Stable category key (`feelings`, `customcat:<uuid>`).
    public let key: String
    /// i18n key for seeded categories. Custom groups carry `null`.
    public let labelKey: String?
    /// Decrypted user-authored label for a custom group.
    public let label: String?
    /// Lucide icon name (`Heart`). Optional — the server column is nullable.
    public let icon: String?
    /// Whether this category is owned by the current user.
    public let custom: Bool
    public let tags: [MoodTagDTO]

    public var id: String {
        key
    }

    public init(
        key: String,
        labelKey: String?,
        label: String? = nil,
        icon: String?,
        custom: Bool = false,
        tags: [MoodTagDTO]
    ) {
        self.key = key
        self.labelKey = labelKey
        self.label = label
        self.icon = icon
        self.custom = custom
        self.tags = tags
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        labelKey = try c.decodeIfPresent(String.self, forKey: .labelKey)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        custom = try c.decodeIfPresent(Bool.self, forKey: .custom) ?? false
        tags = try c.decodeIfPresent([MoodTagDTO].self, forKey: .tags) ?? []
    }

    /// Resolved category title for the section header.
    public var localizedLabel: String {
        if custom, let label, !label.isEmpty {
            return label
        }
        if let labelKey, !labelKey.isEmpty {
            return MoodTagCatalogL10n.resolve(labelKey)
        }
        return label ?? key
    }

    /// SF Symbol for the category header (Lucide name mapped). Falls back to a
    /// neutral tag glyph when the server icon is unknown / nil.
    public var sfSymbol: String {
        MoodTagSFSymbol.symbol(forLucide: icon) ?? "tag"
    }
}

/// Tag kind (server v1.12.0 Mood v2 — rated factors). `binary` = the present /
/// absent toggle chip every tag already renders; `rated` = a factor the user
/// scores per entry (a `scaleMin…scaleMax` slider / segmented control).
/// Defaults to `binary` so a catalog that predates the field decodes unchanged.
public enum MoodTagKind: String, Codable, Sendable, Equatable {
    case binary = "BINARY"
    case rated = "RATED"
}

public struct MoodTagDTO: Codable, Sendable, Equatable, Identifiable {
    /// Stable tag key persisted in `tagKeys` (`happy`, `worked_out`).
    public let key: String
    /// i18n key (`mood.tag.happy`).
    public let labelKey: String
    /// Lucide icon name (`Smile`). Optional.
    public let icon: String?
    /// v1.12.0 Mood v2 — `BINARY` (default) | `RATED`. Additive + optional;
    /// absent ⇒ `.binary` (every pre-v2 tag behaves exactly as before).
    public let kind: MoodTagKind
    /// Inclusive lower bound of a RATED factor's scale (most `1`, `factor_conflict` `1`).
    public let scaleMin: Int
    /// Inclusive upper bound of a RATED factor's scale (most `5`, `factor_conflict` `2`).
    public let scaleMax: Int
    /// `true` ⇒ a higher score means a WORSE day (stress, conflict) — used only
    /// for a directional UI hint; the value captured stays literal.
    public let inverse: Bool
    /// v1.13.0 — `true` ⇒ a per-user custom tag (key `custom:<uuid>`). The
    /// display name lives in ``label`` (not ``labelKey``); render `label` for
    /// customs, keep resolving `labelKey` for catalogue tags.
    public let custom: Bool
    /// v1.13.0 — the user-authored display name for a custom tag (server stores
    /// it encrypted-at-rest, F4). `nil` for catalogue tags (those resolve via
    /// ``labelKey``). Non-nil only when ``custom`` is `true`.
    public let label: String?
    /// v1.13.0 — `true` ⇒ a catalogue tag the user has hidden, returned ONLY by
    /// the management read (`GET /api/mood/tags?include=hidden`). The default
    /// picker read omits hidden tags entirely, so this is `false` there. Custom
    /// tags never carry a `hidden` flag.
    public let hidden: Bool
    /// `true` for an inactive custom tag included by the management read.
    /// Archived tags remain resolvable in history but are omitted from capture.
    public let archived: Bool
    /// How many of the user's live mood entries link this tag. Present only
    /// when the read asks for `include=usage`.
    public let usageCount: Int?

    public var id: String {
        key
    }

    public init(
        key: String,
        labelKey: String,
        icon: String?,
        kind: MoodTagKind = .binary,
        scaleMin: Int = 1,
        scaleMax: Int = 5,
        inverse: Bool = false,
        custom: Bool = false,
        label: String? = nil,
        hidden: Bool = false,
        archived: Bool = false,
        usageCount: Int? = nil
    ) {
        self.key = key
        self.labelKey = labelKey
        self.icon = icon
        self.kind = kind
        self.scaleMin = scaleMin
        self.scaleMax = scaleMax
        self.inverse = inverse
        self.custom = custom
        self.label = label
        self.hidden = hidden
        self.archived = archived
        self.usageCount = usageCount
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        // v1.13.0 — a custom tag carries its name in `label`, not `labelKey`;
        // the created-tag response may send `labelKey: null`. Tolerate a missing
        // / null labelKey (it's only consulted for catalogue tags).
        labelKey = try c.decodeIfPresent(String.self, forKey: .labelKey) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        // Additive Mood v2 fields — tolerate a catalog that omits them.
        kind = try c.decodeIfPresent(MoodTagKind.self, forKey: .kind) ?? .binary
        scaleMin = try c.decodeIfPresent(Int.self, forKey: .scaleMin) ?? 1
        scaleMax = try c.decodeIfPresent(Int.self, forKey: .scaleMax) ?? 5
        inverse = try c.decodeIfPresent(Bool.self, forKey: .inverse) ?? false
        // v1.13.0 custom-tag fields — additive + optional (a pre-v1.13.0 server
        // omits them, so a catalogue tag decodes exactly as before).
        custom = try c.decodeIfPresent(Bool.self, forKey: .custom) ?? false
        label = try c.decodeIfPresent(String.self, forKey: .label)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        usageCount = try c.decodeIfPresent(Int.self, forKey: .usageCount)
    }

    /// A RATED factor exposes a scoring scale; BINARY tags ignore the bounds.
    public var isRated: Bool {
        kind == .rated
    }

    /// Resolved short tile label.
    ///
    /// v0.14.7 B3 — RATED factor keys carry a per-KEY canonical label fallback
    /// so a proper localized word renders even if the server's `labelKey` for a
    /// factor doesn't match a ported xcstrings key (the `factor_sadness`
    /// regression: a non-matching key humanized to "Factor sadness" instead of
    /// "Traurigkeit"). The server `labelKey` still wins when it resolves; the
    /// key-override only kicks in for known rated factors when it doesn't.
    public var localizedLabel: String {
        // v1.13.0 — a custom tag renders its user-authored `label` verbatim
        // (it is not an i18n key). Fall through to the labelKey path only if a
        // custom tag is missing its label (defensive — server always sends it).
        if custom, let label, !label.isEmpty {
            return label
        }
        if isRated, let canonicalKey = MoodTagCatalog.ratedFactorLabelKey[key] {
            let viaLabelKey = MoodTagCatalogL10n.resolve(labelKey)
            // `resolve` echoes the raw labelKey when it's absent from the
            // catalog (un-ported server key) — prefer the canonical key then.
            if viaLabelKey != labelKey, !viaLabelKey.contains(".") {
                return viaLabelKey
            }
            return MoodTagCatalogL10n.resolve(canonicalKey)
        }
        return MoodTagCatalogL10n.resolve(labelKey)
    }

    /// SF Symbol for the tile (Lucide name mapped). Falls back to a neutral
    /// tag glyph when the server icon is unknown / nil.
    public var sfSymbol: String {
        MoodTagSFSymbol.symbol(forLucide: icon) ?? "tag"
    }
}

// MARK: - i18n resolution

/// Resolves the server's `labelKey` strings against `Localizable.xcstrings`.
/// The keys are ported 1:1 from the web app's `messages/{de,en}.json`
/// (`mood.tag.*`, `mood.tagCategory.*`) so the catalog resolves with no
/// per-key switch — `String(localized:)` over the key itself.
enum MoodTagCatalogL10n {
    static func resolve(_ key: String) -> String {
        // v1.13.0 — a custom-tag key (`custom:<uuid>`) is NOT an i18n key. A
        // present custom resolves via its `label` upstream (`localizedLabel` /
        // `label(forTagKey:)`); this fallback only fires for a custom key whose
        // tag is no longer in the catalog (e.g. purged) — render a neutral word
        // rather than echoing the raw `custom:uuid`.
        if key.hasPrefix("custom:") {
            return String(localized: "mood.tag.customFallback")
        }
        let resolved = String(localized: String.LocalizationValue(key))
        // `String(localized:)` echoes the key back verbatim when it is not in
        // the catalog — fall through to a humanized last path component so an
        // un-ported future server key still reads as words, not `mood.tag.x`.
        if resolved == key {
            return key
                .split(separator: ".")
                .last
                .map { $0.replacingOccurrences(of: "_", with: " ") }
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                ?? key
        }
        return resolved
    }
}

// MARK: - Lucide → SF Symbol mapping

/// Maps the server's **Lucide** icon names (the web app's icon set) onto
/// **SF Symbols** for native render. Lucide names are NOT SF Symbols, so a
/// raw `Image(systemName:)` of the server string would render a blank tile.
/// Table sourced from the research doc
/// (`.planning/v014-walk/FUTURE-mood-tagging-daylio-research.md` §3).
/// Monochrome by design — no `.fill` variants picked for color, selection is
/// conveyed by tile state, not glyph color.
enum MoodTagSFSymbol {
    /// Lucide name (as the server stores it) → SF Symbol. Case-insensitive
    /// lookup so a future server casing change (`heart` vs `Heart`) still hits.
    ///
    /// v0.14.x (#21) — covers the **full** server icon catalog
    /// (`src/lib/mood/icon-catalog.ts`, 74 Lucide names across emotions /
    /// activities / health / food / weather / places / misc). Before this the
    /// table only held the original ~22 names, so a web-created custom tag using
    /// any newer icon rendered blank on iOS. Reconciled name-by-name against the
    /// server's published catalog (#21): every one of the 74 names resolves to a
    /// REAL system symbol — the earlier `face.frowning` / `face.angry` entries
    /// were invalid SF Symbol names (only face.smiling / face.dashed /
    /// face.smiling.inverse exist) and rendered blank; they now map to
    /// `hand.thumbsdown` / `cloud.bolt`. Any name still missing falls back to a
    /// neutral `tag` glyph via the callers below (the blank path is closed).
    /// Process rule (catalog header): extend THIS map before the server extends
    /// the catalog.
    private static let table: [String: String] = [
        // ── emotions ──────────────────────────────────────────────────────
        "smile": "face.smiling",
        "laugh": "face.smiling.inverse",
        "meh": "face.dashed",
        // `face.frowning` / `face.angry` are NOT real SF Symbols (only
        // face.smiling / face.dashed / face.smiling.inverse exist) — they
        // rendered blank, which is the #21 bug. Substitute real glyphs that
        // still read as the emotion: a downturned thumb for an unhappy/frown
        // tag, a storm-bolt cloud for an angry one. Both ship since iOS 13.
        "frown": "hand.thumbsdown",
        "angry": "cloud.bolt",
        "heart": "heart",
        "handheart": "hands.and.sparkles",
        "partypopper": "party.popper",
        "thumbsup": "hand.thumbsup",
        "checkcircle": "checkmark.circle",
        "alerttriangle": "exclamationmark.triangle",
        "helpcircle": "questionmark.circle",
        "swords": "exclamationmark.bubble",
        "flame": "flame",
        "zap": "bolt",
        "star": "star",
        "gift": "gift",
        // ── activities ────────────────────────────────────────────────────
        "dumbbell": "dumbbell",
        "activity": "waveform.path.ecg",
        "footprints": "figure.walk",
        "bike": "bicycle",
        "music": "music.note",
        "headphones": "headphones",
        "gamepad2": "gamecontroller",
        "film": "film",
        "bookopen": "book",
        "book": "book.closed",
        "briefcase": "briefcase",
        "graduationcap": "graduationcap",
        "palette": "paintpalette",
        "camera": "camera",
        "trees": "tree",
        "mountain": "mountain.2",
        "plane": "airplane",
        "car": "car",
        "shoppingcart": "cart",
        "phone": "phone",
        "users": "person.2",
        "user": "person",
        "logout": "rectangle.portrait.and.arrow.right",
        "banknote": "banknote",
        "clock": "clock",
        "slidershorizontal": "slider.horizontal.3",
        // ── health ────────────────────────────────────────────────────────
        "pill": "pills",
        "stethoscope": "stethoscope",
        "syringe": "syringe",
        "thermometer": "thermometer.medium",
        "heartpulse": "heart.text.square",
        "brain": "brain.head.profile",
        "bath": "bathtub",
        "bed": "bed.double",
        "beddouble": "bed.double",
        "moon": "moon.zzz",
        "moonstar": "moon.stars",
        "cigarette": "smoke",
        "cigaretteoff": "nosign",
        "baby": "figure.child",
        // ── food ──────────────────────────────────────────────────────────
        "apple": "fork.knife",
        "pizza": "fork.knife.circle",
        "utensilscrossed": "fork.knife",
        "coffee": "cup.and.saucer",
        "wine": "wineglass",
        "glasswater": "drop",
        "candyoff": "minus.circle",
        // ── weather ───────────────────────────────────────────────────────
        "sun": "sun.max",
        "cloudsun": "cloud.sun",
        "cloud": "cloud",
        "cloudrain": "cloud.rain",
        "cloudmoon": "cloud.moon",
        "leaf": "leaf",
        // ── places ────────────────────────────────────────────────────────
        "house": "house",
        "home": "house",
        // ── misc ──────────────────────────────────────────────────────────
        "tag": "tag",
        "cat": "cat",
        "dog": "dog",
        // ── non-catalog legacy / category glyph kept for back-compat ───────
        "clockalert": "clock.badge.exclamationmark"
    ]

    /// Per-tag-key override for the handful of cases where one Lucide glyph is
    /// reused across categories but the research table wants a category-aware
    /// SF Symbol (e.g. `family` → `house`, `party` → `figure.dance`). Keyed by
    /// the tag's stable `key`, checked first.
    private static let tagKeyOverrides: [String: String] = [
        "slept_well": "moon.stars",
        "slept_ok": "cloud.moon",
        "slept_poorly": "moon",
        "early_night": "clock",
        "family": "house",
        "friends": "person.2",
        "party": "figure.dance",
        "alone": "person",
        "productive": "checkmark.circle",
        "overtime": "clock.badge.exclamationmark",
        "day_off": "figure.walk.departure",
        "travel": "airplane",
        "sick_day": "thermometer.medium",
        "walked": "figure.walk"
    ]

    /// SF Symbol for a Lucide name. `nil` when unmapped — callers substitute a
    /// neutral `tag` glyph so an un-mapped future server icon still renders.
    static func symbol(forLucide lucide: String?) -> String? {
        guard let lucide, !lucide.isEmpty else { return nil }
        return table[lucide.lowercased()]
    }

    /// SF Symbol for a tag, preferring the per-key override (category-aware)
    /// and falling back to the Lucide-name mapping, then a neutral glyph.
    static func symbol(forTag tag: MoodTagDTO) -> String {
        if let override = tagKeyOverrides[tag.key] { return override }
        return symbol(forLucide: tag.icon) ?? "tag"
    }

    /// v1.13.0 — SF Symbol for a custom-tag icon allow-list name, always
    /// resolving (defaults to the neutral `tag` glyph). Used by the management
    /// icon picker so every allow-list option renders a real glyph.
    static func symbolForAllowListIcon(_ name: String) -> String {
        symbol(forLucide: name) ?? "tag"
    }
}
