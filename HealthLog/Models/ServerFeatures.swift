import Foundation

/// #126 P2 (server v1.42.0, #116 item 18) — `features` on
/// `GET /api/auth/me`: what this server understands, for a client released
/// apart from it. Constant across accounts. A flag that is absent or `false`
/// means the server does not have the feature; the app checks for `true`
/// before it relies on one.
///
/// Only the flags this build acts on are read. `features.trackIntake` (always
/// `true` from v1.42.0) lets the add sheet offer "track intake" on an account
/// with no medication yet, where no served row could tell (#126 P2).
/// `features.biomarkerMerge` (v1.43) gates merging lab markers (#130).
/// `cumulativeHourBuckets` and `syncTriggerBackfill` (v1.43, #138) gate
/// the hourly stats rows and the `backfill` trigger; ``ModuleGate`` hands
/// them to ``KnownServerVersion`` (see `ServerFeatures+KnownServerVersion`).
/// `lifeCircumstances` (v1.43, #132) opens "Life circumstances" under
/// "About me".
/// This is the one reader of the block: every flag the app acts on lives here.
public struct ServerFeatures: Decodable, Sendable, Equatable {
    public let trackIntake: Bool
    public let biomarkerMerge: Bool
    /// Hourly `stats:<HK>:<YYYY-MM-DD>T<HH>` rows for steps, active energy,
    /// walking and running distance and flights climbed.
    public let cumulativeHourBuckets: Bool
    /// `syncTrigger: "backfill"` on the measurement batch.
    public let syncTriggerBackfill: Bool
    /// The life-circumstance routes (`/api/anamnesis/life-circumstances`).
    public let lifeCircumstances: Bool

    public init(
        trackIntake: Bool = false,
        biomarkerMerge: Bool = false,
        cumulativeHourBuckets: Bool = false,
        syncTriggerBackfill: Bool = false,
        lifeCircumstances: Bool = false
    ) {
        self.trackIntake = trackIntake
        self.biomarkerMerge = biomarkerMerge
        self.cumulativeHourBuckets = cumulativeHourBuckets
        self.syncTriggerBackfill = syncTriggerBackfill
        self.lifeCircumstances = lifeCircumstances
    }

    private enum CodingKeys: String, CodingKey {
        case trackIntake, biomarkerMerge, cumulativeHourBuckets, syncTriggerBackfill, lifeCircumstances
    }

    /// Each flag on its own: a mistyped one reads as `false`, never costs the
    /// other.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackIntake = (try? c.decodeIfPresent(Bool.self, forKey: .trackIntake)) == true
        biomarkerMerge = (try? c.decodeIfPresent(Bool.self, forKey: .biomarkerMerge)) == true
        cumulativeHourBuckets = (try? c.decodeIfPresent(Bool.self, forKey: .cumulativeHourBuckets)) == true
        syncTriggerBackfill = (try? c.decodeIfPresent(Bool.self, forKey: .syncTriggerBackfill)) == true
        lifeCircumstances = (try? c.decodeIfPresent(Bool.self, forKey: .lifeCircumstances)) == true
    }
}

/// The last `features` block `/api/auth/me` delivered, readable from the
/// model layer (the add sheet's `trackIntake` decision lives on `Medication`).
/// Written by `ModuleGate.load()` on every `/me` load; reset on logout. The
/// flags describe the server, not the account, so nothing personal is held.
public final class ServerFeatureMirror: @unchecked Sendable {
    public static let shared = ServerFeatureMirror()

    private let lock = NSLock()
    private var stored: ServerFeatures?

    public init() {}

    public var current: ServerFeatures? {
        lock.withLock { stored }
    }

    public func store(_ features: ServerFeatures?) {
        lock.withLock { stored = features }
    }
}
