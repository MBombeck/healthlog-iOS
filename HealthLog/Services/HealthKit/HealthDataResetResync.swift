import Foundation

/// **"Daten zurücksetzen" uploads Apple Health again (1.7).**
///
/// The reset deletes every record on the server, the Apple Health readings
/// included. Until 1.7 the device kept its cursors and its day-total cache,
/// both of which say "already delivered", so after the reset the record held
/// only what arrived from then on. Alex's decision: the record is complete
/// again afterwards.
///
/// The reset arms a one-time marker for the account (a fresh id per reset).
/// The next collection pass drops the committed cursor of every partition the
/// sample collector owns, once per marker (``DurableHealthCursorStore/resetCursorOnce(_:for:requiring:)``),
/// so each partition starts like a fresh one: live from two days back, the
/// history walk backwards in the per-pass budget it always had. There is no
/// burst; the pace is that of a first sync. The marker goes once every
/// partition reset verifies, otherwise the next pass finishes the rest.
///
/// The day totals are forgotten at once by the reset itself
/// (`HealthKitDailyStatsSyncing.forgetUploadedTotals`).
enum HealthDataResetResync {
    static let keyPrefix = "hl.healthkit.dataResetResync."

    static func key(ownerID: String) -> String {
        keyPrefix + HealthKitBackfillWindowStore.partitionToken(for: ownerID)
    }

    /// Arms a re-upload for `ownerID`. A second reset before the first was
    /// applied arms a new id, so every partition resets once more.
    static func arm(ownerID: String, defaults: UserDefaults) {
        defaults.set("data-reset-" + UUID().uuidString.lowercased(), forKey: key(ownerID: ownerID))
    }

    static func pendingResetID(ownerID: String, defaults: UserDefaults) -> String? {
        defaults.string(forKey: key(ownerID: ownerID))
    }

    /// Forgets `resetID` once it is applied, never a newer one.
    static func finish(_ resetID: String, ownerID: String, defaults: UserDefaults) {
        guard pendingResetID(ownerID: ownerID, defaults: defaults) == resetID else { return }
        defaults.removeObject(forKey: key(ownerID: ownerID))
    }
}

#if canImport(HealthKit)
    extension HealthDataResetResync {
        /// Resets every partition of `typeIdentifiers` for the admitted
        /// account while a reset is armed. Returns how many partitions this
        /// call reset.
        @discardableResult
        static func apply(
            store: DurableHealthCursorStore,
            typeIdentifiers: [String],
            requiring lease: HealthSyncAuthenticatedLease,
            defaults: UserDefaults = .standard
        ) async -> Int {
            guard let resetID = pendingResetID(ownerID: lease.ownerID, defaults: defaults) else { return 0 }
            var reset = 0
            var complete = true
            for typeIdentifier in typeIdentifiers {
                guard let key = lease.cursorKey(typeIdentifier: typeIdentifier) else { continue }
                do {
                    if try await store.resetCursorOnce(resetID, for: key, requiring: lease) { reset += 1 }
                } catch {
                    complete = false
                }
            }
            if complete {
                finish(resetID, ownerID: lease.ownerID, defaults: defaults)
            }
            // A count only: no type, no owner.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info("data reset: \(reset, privacy: .public) partition(s) upload their history again")
            return reset
        }
    }
#endif
