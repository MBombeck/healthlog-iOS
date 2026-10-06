#if canImport(HealthKit)
    import Foundation
    import HealthKit

    /// **#113 / public #7 — the one-time re-read of SpO2 and body fat.**
    ///
    /// Up to 1.0.3 the app sent both percent types pre-multiplied by 100. Servers
    /// before v1.38.25 scaled them a second time, rejected every row as
    /// `value_out_of_range` inside an HTTP 200, and the app treated that refusal
    /// as final: the anchor moved past the reading and never looked back. The
    /// server fix only helps readings that are read again, and the `scale: 1`
    /// change in `HealthKitWireConverter` only helps new ones. What sits behind
    /// the anchor comes back only when the anchor is dropped.
    ///
    /// So each account's two partitions are reset exactly once: the committed
    /// cursor is removed, the next collection walks the partition again from the
    /// backfill window the person chose, and the server answers `duplicate` for
    /// every reading it already holds (`HKSample.uuid` is the `externalId`,
    /// first-write-wins) and `inserted` for the ones it refused before.
    ///
    /// The marker lives beside each partition in the cursor store, so it is per
    /// installation *and* per account, survives a relaunch, and a second account
    /// on the same device gets its own reset.
    enum HealthKitPercentScaleCursorReset {
        /// Versioned so a later, different reset of the same partitions can never
        /// be mistaken for this one.
        static let resetID = "113-percent-scale-v1"

        static var typeIdentifiers: [String] {
            [
                HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
                HKQuantityTypeIdentifier.bodyFatPercentage.rawValue
            ]
        }

        /// Resets whichever of the two partitions have not been reset yet for the
        /// admitted account.
        ///
        /// - Returns: the identifiers reset by *this* call; empty once both
        ///   markers exist. A partition whose reset did not verify is left for
        ///   the next run rather than marked done.
        @discardableResult
        static func apply(
            store: DurableHealthCursorStore,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> [String] {
            var reset: [String] = []
            for typeIdentifier in typeIdentifiers {
                guard let key = lease.cursorKey(typeIdentifier: typeIdentifier) else { continue }
                do {
                    if try await store.resetCursorOnce(resetID, for: key, requiring: lease) {
                        reset.append(typeIdentifier)
                    }
                } catch {
                    // The identifier is a fixed HealthKit constant; no owner, no
                    // value, no anchor. The next run tries again.
                    // swiftlint:disable:next hllog_public_privacy_interpolation
                    HLLog.healthKit.error(
                        "percent-scale cursor reset did not verify [\(typeIdentifier, privacy: .public)] — retried next run"
                    )
                }
            }
            if !reset.isEmpty {
                // A count only.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.info(
                    "percent-scale cursor reset: \(reset.count, privacy: .public) partition(s) will re-read from the backfill window"
                )
            }
            return reset
        }
    }
#endif
