import Foundation

/// Which Activity an update token belongs to: its ActivityKit id, the
/// medication and the slot it shows (`intakeScheduledFor`).
struct LiveActivityTokenOwner: Sendable, Hashable {
    let activityID: String
    let medicationId: String
    let slot: Date
}

/// **#188 (2) — one update token per running Live Activity.**
///
/// The sink kept `[medicationId: token]`, never removed an entry, and reported
/// `.values.first`: with two medications that was an arbitrary one, often the
/// token of an Activity that had already ended, so the server's `end` reached
/// nothing. The registry keys by Activity, drops a token when its Activity
/// ends or is gone at launch, and picks the token to report by a fixed rule.
struct LiveActivityTokenRegistry: Equatable {
    struct Entry: Equatable {
        let token: String
        let owner: LiveActivityTokenOwner
    }

    private(set) var entries: [String: Entry] = [:]

    /// Records `token` for its Activity. Returns whether anything changed.
    @discardableResult
    mutating func upsert(_ token: String, owner: LiveActivityTokenOwner) -> Bool {
        let entry = Entry(token: token, owner: owner)
        guard entries[owner.activityID] != entry else { return false }
        entries[owner.activityID] = entry
        return true
    }

    /// Drops the token of an ended Activity. Returns whether one was held.
    @discardableResult
    mutating func remove(activityID: String) -> Bool {
        entries.removeValue(forKey: activityID) != nil
    }

    /// Keeps only the Activities still running. Returns whether any went.
    @discardableResult
    mutating func retain(activityIDs: Set<String>) -> Bool {
        let before = entries.count
        entries = entries.filter { activityIDs.contains($0.key) }
        return entries.count != before
    }

    /// The token the single `liveActivityPushToken` field carries: the
    /// running Activity with the earliest slot, which is the dose the plan
    /// surfaces (``MedicationLiveActivityPlan/doseToSurface``, soonest due
    /// first). Ties break on medication and Activity id, so the choice never
    /// depends on dictionary order.
    var primaryToken: String? {
        orderedEntries.first?.token
    }

    /// Every token with its medication and slot, earliest slot first: what
    /// the per-Activity body field will carry once
    /// ``LiveActivityPerActivityTokens`` opens.
    var orderedEntries: [Entry] {
        entries.values.sorted { lhs, rhs in
            if lhs.owner.slot != rhs.owner.slot { return lhs.owner.slot < rhs.owner.slot }
            if lhs.owner.medicationId != rhs.owner.medicationId {
                return lhs.owner.medicationId < rhs.owner.medicationId
            }
            return lhs.owner.activityID < rhs.owner.activityID
        }
    }
}

/// **#188 (2), #191 — one token per Activity on `POST /api/devices`.**
///
/// `liveActivityTokens: [{ token, medicationId, slotInstant }]` is the
/// device's full current list (each call replaces the stored one, an empty
/// list clears it, an omitted field leaves it unchanged). The server ends each
/// Activity with its own push. Sent only behind
/// ``MedicationCapability/liveActivityTokensPerActivity``; the single
/// `liveActivityPushToken` keeps going out for servers without it (1.49.0
/// ignores it when the list is present).
enum LiveActivityPerActivityTokens {
    /// The body field for the token list.
    static let fieldName = "liveActivityTokens"

    static func isAvailable(defaults: UserDefaults? = MedicationCapabilities.appGroupDefaults) -> Bool {
        MedicationCapabilities.isOpen(.liveActivityTokensPerActivity, defaults: defaults)
    }

    /// The wire entries for `registry`, earliest slot first.
    static func wireEntries(_ registry: LiveActivityTokenRegistry) -> [LiveActivityTokenWire] {
        registry.orderedEntries.map {
            LiveActivityTokenWire(token: $0.token, medicationId: $0.owner.medicationId, slotInstant: $0.owner.slot)
        }
    }
}
