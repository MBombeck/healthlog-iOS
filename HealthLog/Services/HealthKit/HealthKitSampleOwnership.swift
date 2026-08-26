import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// **W-HK-RELIABILITY G-7 — foreign-filter ownership.**
///
/// The HealthKit read pipeline must skip samples *we* wrote (the anti-echo
/// guarantee: a sample HealthLog round-tripped into Apple Health must not be
/// re-uploaded to the server on the next observer wake). The historical filter
/// keyed solely on "does this sample carry *any* `HKMetadataKeyExternalUUID`",
/// which has two correctness holes:
///
///   (a) **False skip** — a *third-party* sample that happens to carry an
///       `HKMetadataKeyExternalUUID` (other apps are free to set it) was
///       silently dropped and never imported, so the user's genuine data
///       from another app never reached the server.
///   (b) **False import** — if one of *our* mirror rows lost its UUID (a
///       stripped/garbled metadata dictionary), it would no longer match and
///       could re-import as a server duplicate.
///
/// The correct predicate is "is this sample **OURS**" — it carries an external
/// UUID **and** it was authored by **this app's own HealthKit source**
/// (`HKSource.default()` is the running app). A foreign sample is authored by
/// a *different* source, so even if it carries an external UUID it flows in.
/// Our own writes always carry both signals, so the anti-echo guarantee stays
/// intact.
///
/// The decision is split into a pure, source-agnostic predicate
/// (``isOwnEcho(externalUUID:isFromThisApp:)``) so the four-quadrant truth
/// table is unit-testable without constructing a foreign-source `HKSample`
/// (HealthKit does not let a unit test forge another app's source revision).
enum HealthKitSampleOwnership {
    /// App-private metadata marker stamped on **every** HealthLog write into
    /// Apple Health (alongside `HKMetadataKeyExternalUUID`). It exists so the
    /// **deletion** path can confirm ownership: `HKDeletedObject` exposes only
    /// `uuid` + `metadata` — never `sourceRevision` — so the read path's
    /// authoring-source check (`HKSource.default()`) is unavailable on delete.
    /// A foreign app can set a colliding `HKMetadataKeyExternalUUID`, but it has
    /// no reason to set *this* private key, so requiring both signals on the
    /// delete path closes BH-final-diff H2 (a foreign deletion must NOT delete
    /// our server row). The value is fixed and non-PII.
    static let appOriginMetadataKey = "dev.healthlog.app.origin"

    /// The marker value written into ``appOriginMetadataKey``. A bare presence
    /// check would suffice, but a stable value keeps the predicate explicit and
    /// future-proofs against an accidental empty stamp.
    static let appOriginMetadataValue = "healthlog"

    /// Whether a deleted sample's preserved metadata confirms it was minted by
    /// THIS app. Requires both the app-origin marker **and** a non-empty
    /// `HKMetadataKeyExternalUUID` (the server-linkage id). Used by the HK→server
    /// delete-propagation path, which cannot see the authoring source.
    static func isAppMintedDeletion(metadata: [String: Any]?) -> Bool {
        guard let metadata else { return false }
        guard let externalUUID = metadata[HKMetadataKeyExternalUUID] as? String,
              !externalUUID.isEmpty else { return false }
        return (metadata[appOriginMetadataKey] as? String) == appOriginMetadataValue
    }

    /// Pure ownership predicate. A sample is **our own echo** (→ skip on read)
    /// iff it carries a non-empty external UUID **and** it was authored by this
    /// app's own HealthKit source.
    ///
    /// Truth table (the four G-7 quadrants):
    ///
    /// | externalUUID present | from this app | verdict      |
    /// |----------------------|---------------|--------------|
    /// | yes                  | yes           | **own echo** → skip |
    /// | yes                  | no            | third-party  → import |
    /// | no                   | yes           | our own non-mirror write without UUID → import (defensive; we always set it) |
    /// | no                   | no            | third-party  → import |
    ///
    /// - Parameters:
    ///   - externalUUID: the `HKMetadataKeyExternalUUID` value, if any.
    ///   - isFromThisApp: whether the sample's source is this app's own
    ///     HealthKit source (`HKSource.default()`).
    /// - Returns: `true` when the sample is our own echo and must be skipped.
    static func isOwnEcho(externalUUID: String?, isFromThisApp: Bool) -> Bool {
        guard let externalUUID, !externalUUID.isEmpty else { return false }
        return isFromThisApp
    }

    #if canImport(HealthKit)
        /// Convenience over a concrete `HKSample`: reads the external UUID from
        /// metadata and compares the authoring source against `HKSource.default()`.
        static func isOwnEcho(_ sample: HKSample) -> Bool {
            let externalUUID = sample.metadata?[HKMetadataKeyExternalUUID] as? String
            let isFromThisApp = sample.sourceRevision.source == HKSource.default()
            return isOwnEcho(externalUUID: externalUUID, isFromThisApp: isFromThisApp)
        }
    #endif
}
