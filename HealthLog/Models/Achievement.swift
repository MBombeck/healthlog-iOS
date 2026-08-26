import Foundation

/// Server-emitted achievement (shape `format=ios`). Mirror of `IosAchievement`
/// in `<server-repo>/src/app/api/gamification/achievements/route.ts`
/// (the `format=ios` map).
///
/// **v0.16 Build 7 / item 7.4 — parity fields.** As of server v1.18.0 B5 the
/// `format=ios` payload carries the same grouping + progress fields the web
/// surface already renders: `category`, `points`, `target`, `current`,
/// `isHidden`. Older servers (pre-B5) omitted some of them, so every added
/// field decodes **tolerantly** — a missing or malformed value falls back to
/// `nil` / a safe default rather than breaking the whole list decode.
///
/// `points` stays `Optional<Int>`: it is now emitted by the server, but a
/// pre-B5 deploy sends `null`, in which case `resolvingPoints()` hydrates it
/// from the static `AchievementPoints` table. The optionality keeps the decoder
/// forward- and backward-compatible.
///
/// `format` (`count` / `days` / `percent`) is NOT emitted by the current ios
/// map — it is decoded tolerantly so a future server that adds it lights up the
/// absolute-progress copy ("12 / 30 days") without an app update; until then it
/// resolves to `nil`.
public struct Achievement: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let key: String
    public let title: String
    public let description: String
    public let iconName: String?
    public let unlocked: Bool
    public let unlockedAt: Date?
    public let progress: Double // 0...1
    public let points: Int?
    /// Server badge category (`vitals`, `medications`, `engagement`, `hidden`,
    /// …). Raw string so a new server category never breaks decoding.
    public let category: String?
    /// Absolute progress toward the badge (`current` of `target`), e.g. 12 of
    /// 30 logged days. Server-canonical numbers; the UI formats per `format`.
    public let current: Double?
    public let target: Double?
    /// How `current`/`target` should read. `nil` until the server adds the
    /// field to the ios map (tolerant).
    public let format: AchievementFormat?
    /// `true` for the opaque "mysterious achievement" card the server hides
    /// until unlocked. Defaults `false` when the field is absent.
    public let isHidden: Bool

    public init(
        id: String,
        key: String,
        title: String,
        description: String,
        iconName: String? = nil,
        unlocked: Bool,
        unlockedAt: Date? = nil,
        progress: Double = 0,
        points: Int? = nil,
        category: String? = nil,
        current: Double? = nil,
        target: Double? = nil,
        format: AchievementFormat? = nil,
        isHidden: Bool = false
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.description = description
        self.iconName = iconName
        self.unlocked = unlocked
        self.unlockedAt = unlockedAt
        self.progress = max(0, min(1, progress))
        self.points = points
        self.category = category
        self.current = current
        self.target = target
        self.format = format
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case id, key, title, description, iconName, unlocked, unlockedAt, progress, points
        case category, current, target, format, isHidden
    }

    /// Tolerant decoder — only `id` is required (a list element with no id is
    /// genuinely broken). Every other field is defended with `try?` /
    /// `decodeIfPresent` so a single malformed value (wrong type, unknown
    /// `format` token, a null where a scalar was expected) degrades that field
    /// to its default instead of throwing the whole achievements list away.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is the one hard requirement. `try? c.decode(...)` returns nil for
        // a missing key, an explicit null, OR a wrong-typed value — the single
        // tolerant primitive used for every remaining field.
        id = try c.decode(String.self, forKey: .id)
        key = (try? c.decode(String.self, forKey: .key)) ?? id
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        iconName = try? c.decode(String.self, forKey: .iconName)
        unlocked = (try? c.decode(Bool.self, forKey: .unlocked)) ?? false
        unlockedAt = try? c.decode(Date.self, forKey: .unlockedAt)
        let rawProgress = (try? c.decode(Double.self, forKey: .progress)) ?? 0
        progress = max(0, min(1, rawProgress))
        points = try? c.decode(Int.self, forKey: .points)
        category = try? c.decode(String.self, forKey: .category)
        current = try? c.decode(Double.self, forKey: .current)
        target = try? c.decode(Double.self, forKey: .target)
        // Unknown `format` token → `decode` throws → `try?` → nil (tolerant).
        format = try? c.decode(AchievementFormat.self, forKey: .format)
        isHidden = (try? c.decode(Bool.self, forKey: .isHidden)) ?? false
    }
}

/// How an achievement's `current`/`target` pair reads. Wire tokens mirror the
/// server's `AchievementDefinition.format` (`src/lib/gamification/achievements.ts`).
public enum AchievementFormat: String, Codable, Sendable {
    case count
    case days
    case percent
}

public extension Achievement {
    /// Returns a copy of the achievement with `points` resolved via the
    /// `AchievementPoints` static lookup. Used by the repository transition
    /// path: a pre-v1.18.0-B5 server emits no points, so we hydrate them
    /// client-side. On a current server (points present) this is a no-op.
    func resolvingPoints() -> Achievement {
        guard points == nil else { return self }
        guard let pts = AchievementPoints.value(for: id) else { return self }
        return Achievement(
            id: id,
            key: key,
            title: title,
            description: description,
            iconName: iconName,
            unlocked: unlocked,
            unlockedAt: unlockedAt,
            progress: progress,
            points: pts,
            category: category,
            current: current,
            target: target,
            format: format,
            isHidden: isHidden
        )
    }

    /// True iff this is the server's hidden-card placeholder. Prefers the
    /// explicit `isHidden` field (server v1.18.0 B5); falls back to the
    /// `HelpCircle` icon sentinel the pre-B5 hidden-card path forwarded
    /// (`route.ts:916`), so a pre-B5 server still renders the opaque card. The
    /// screen renders these cells with an opaque "Geheimnisvoller Erfolg"
    /// placeholder while still locked.
    var isHiddenPlaceholder: Bool {
        if isHidden { return true }
        // Pre-B5 fallback: the hidden-card path forwarded `iconName: "HelpCircle"`
        // — the stable cross-locale signal before `isHidden` was on the wire.
        return iconName?.lowercased() == "helpcircle"
    }
}
