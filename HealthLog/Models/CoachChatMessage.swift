import Foundation
import SwiftData

/// **v0.5.7 G.5** — SwiftData `@Model` row for one persisted Coach chat
/// turn. Hydrates the `CoachConversationStore.chat` array on app launch
/// and survives the process death between AskCoach sheet visits.
///
/// **Why a dedicated `@Model` instead of re-using `OutboxOperation`?**
/// Each SwiftData container in the app is
/// purpose-scoped (Outbox = pending writes,
/// SWR-cache = repository snapshots, GLP-1 = local titration ledger).
/// Adding chat to one of those mixed-purpose stores would tangle
/// schema-migration risk across surfaces. The chat transcript also
/// has its own retention semantics (cleared on logout AND via a
/// dedicated Settings affordance) that doesn't map onto any existing
/// store's lifecycle.
///
/// **Partition key — `userID`:** every read filters by the current
/// `keychain.getString(KeychainKey.userID)` so a second account
/// signed in on the same device never sees the previous operator's
/// transcript. The HK-anchor + backfill-window stores follow the
/// same per-user-partition pattern; we mirror it for chat hygiene.
/// `userID` is non-optional so cold-launch standalone-mode turns can
/// still partition under a stable sentinel — `CoachChatMessage.standaloneUserID`
/// supplies the value when no Keychain user is present.
///
/// **What lands on disk:** only the raw user text + the assistant
/// response — never the privacy-first composed prompt (G.4 invariant,
/// re-affirmed by G.5). The composed prompt is rebuilt on every send
/// from the live `HealthSnapshot`; persisting it would freeze stale
/// snapshot data into the transcript replay.
///
/// **Privacy posture:** `cloudKitDatabase: .none` on the container so
/// the transcript never roams to an iCloud account that might not
/// match the logged-in HealthLog user. File-protection
/// `.completeUntilFirstUserAuthentication` mirrors the other local
/// stores so background hydration after first unlock still works.
@Model
public final class CoachChatMessage {
    /// Unique row id. Generated client-side on insertion; the value is
    /// stable across replays so the transcript order is deterministic
    /// even when two messages share the same `createdAt` timestamp
    /// (rare, but possible when the user fires a chip immediately
    /// after the assistant turn lands).
    @Attribute(.unique) public var id: UUID

    /// Partition key — the keychain `userID` at write time. Reads filter
    /// by `==` so a second-account sign-in on the same device sees an
    /// empty transcript and never the previous user's chat.
    public var userID: String

    /// Stored as the raw enum string (`"user"` / `"assistant"`) for
    /// forward-compat. `CoachChatRole` exposes the typed accessor via
    /// `role` so call-sites stay enum-driven.
    public var roleRaw: String

    /// The persisted text — user's raw input on the `.user` rows, the
    /// rendered `CoachInsight` markdown on the `.assistant` rows.
    public var text: String

    /// Wall-clock at insertion. Reads order by this descending so the
    /// SpeziChat transcript hydrates oldest-first by reversing client-
    /// side. Defaults to `.now` so a hand-rolled init in tests can omit.
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        userID: String,
        role: CoachChatRole,
        text: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.userID = userID
        roleRaw = role.rawValue
        self.text = text
        self.createdAt = createdAt
    }

    /// Typed accessor for the `roleRaw` storage. Falls back to
    /// `.assistant` on an unrecognized value — schema-forward branch
    /// when a future `CoachChatRole.system` lands and an older binary
    /// replays the row.
    public var role: CoachChatRole {
        get { CoachChatRole(rawValue: roleRaw) ?? .assistant }
        set { roleRaw = newValue.rawValue }
    }
}

/// Author of a chat turn. Mirrors `SpeziChat.ChatEntity.Role` but lives
/// in HealthLog-only space so the persistence model doesn't drag a
/// SpeziChat link into `HealthLogCore` for downstream consumers.
public enum CoachChatRole: String, Codable, Sendable {
    case user
    case assistant
}

public extension CoachChatMessage {
    /// Sentinel partition value used when no keychain user is present
    /// (standalone-mode + pre-auth). Distinct from any UUID-shaped user
    /// id so a future paired login can't accidentally collide. The
    /// transcript under this key clears on `clearOnLogout` the same way
    /// authenticated transcripts do.
    static let standaloneUserID: String = "__standalone__"
}

// MARK: - Versioned schema

/// Versioned schema for the coach-chat store. Pinned at V1 today. Add
/// a `V2` + a `MigrationPlan` when shape changes; mirrors
/// `OutboxSchemaV1` / `CacheSchemaV1`.
public enum CoachChatSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        .init(1, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
        [CoachChatMessage.self]
    }
}
