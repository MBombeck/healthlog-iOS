import Foundation

/// Single source of truth for the iOS ↔ server HealthKit-type contract:
/// which HK identifiers the HealthLog server currently knows how to map, and
/// the one place to flip when the server lands support for the deferred set.
///
/// **Why this exists (W2 — silent-data-loss fix).** Some HK identifiers are
/// fully wired on iOS (authorized, wire-converted, uploaded) but the server
/// still lists them in its `HK_QUANTITY_TYPE_DEFERRED` set. For those, the
/// batch endpoint returns a per-entry `status:"skipped", reason:"unmappable_
/// identifier"` with **HTTP 200**. The old anchor policy treated any 2xx —
/// including `skipped` — as durably synced and advanced the HK anchor, so the
/// reading was dropped forever with no error and no retry. The server gaining
/// support later does **not** recover the lost samples because the anchor has
/// already moved past them.
///
/// The fix has two layers, both keyed on the constants below so there is
/// exactly one place to re-enable:
///
/// 1. **Registration gate (primary).** `HealthLogSpeziDelegate` only registers
///    a `CollectSamples` observer for an identifier when it is **not** in
///    ``serverUnsupportedIdentifiers``. While an identifier is gated it is
///    **not collected at all** — SpeziHealthKit never arms an
///    `HKObserverQuery` for it, never wakes the app in the background for
///    it, and never advances its per-type anchor. HealthKit retains the
///    samples on-device, so nothing is lost. When the server lands the
///    mapping, remove the identifier from ``serverUnsupportedIdentifiers``:
///    the collector re-registers with `timeRange: .startingAt(backfillCutoff)`
///    and the very first anchored query re-reads the full backfill window from
///    HealthKit's on-device retention — the history syncs in one batch.
///
/// 2. **Anchor-decision defense.** `HealthKitService.uploadAndDecide` treats a
///    `reason:"unmappable_identifier"` skip as **not** durably consumed
///    (`.keepAnchor`) so that even if a deferred type ever reaches the upload
///    path (a new Apple identifier, a future code path, a stale build), its
///    anchor is held until the server can persist it. A `value_out_of_range`
///    skip stays terminal (`.consumed`) — that is a genuinely bad reading that
///    retrying would never change.
///
/// The set is intentionally a plain `Set<String>` of raw HK identifier
/// strings (no `HKQuantityTypeIdentifier` import) so it compiles on the
/// platform-free side and the W2 unit tests can exercise it without a real
/// HealthKit store.
public enum HealthKitServerSupportConfig {
    /// HK identifiers the server returns `unmappable_identifier` for today.
    /// These are fully wired on iOS but absent from the server's
    /// `APPLE_HEALTH_TYPE_MAP`; uploading them is a guaranteed silent skip.
    ///
    /// **W-WALK (server v1.6.0) — gate is now empty.** The server v1.5.5 sync
    /// landed mappings for `respiratoryRate`, `bodyMassIndex`,
    /// `walkingAsymmetryPercentage`, and `walkingDoubleSupportPercentage`; the
    /// v1.6.0 sync then landed the last two operator-requested gait types,
    /// `walkingStepLength` (Prisma `WALKING_STEP_LENGTH`, unit m, range
    /// 0.1–2.0) and `walkingSpeed` (Prisma `WALKING_SPEED`, unit m/s, range
    /// 0.1–3.0) — both in `apple-health-mapping.ts` + the batch validator.
    /// With no HK identifier left unmapped server-side, the set is now empty:
    /// every authorized type collects + uploads + persists. The two-layer
    /// defense (registration gate + anchor-decision) stays wired so a future
    /// gated identifier only needs one line re-added here.
    ///
    /// Raw identifier strings (matching `HKQuantityTypeIdentifier.<case>.raw-
    /// Value`) so this list stays HealthKit-import-free.
    public static let serverUnsupportedIdentifiers: Set<String> = []

    /// `true` when `identifier` is a type the server cannot persist yet. Used
    /// by both the registration gate and the anchor-decision defense.
    public static func isServerUnsupported(_ identifier: String) -> Bool {
        serverUnsupportedIdentifiers.contains(identifier)
    }

    /// Server skip reason for a HK identifier the server mapper does not know.
    /// **Transient** — becomes valid the moment the server adds the mapping, so
    /// the HK anchor must be held (not advanced) when it appears in a batch
    /// response. Mirrors `src/app/api/measurements/batch/route.ts` line 204.
    public static let reasonUnmappableIdentifier = "unmappable_identifier"

    /// Server skip reason for a value outside the plausible range band.
    /// **Terminal** — a bad sensor reading that retrying would never fix, so
    /// the anchor advances past it. Mirrors the batch route line 217.
    public static let reasonValueOutOfRange = "value_out_of_range"

    /// **CU-21 (4)** — server skip reason since v1.32.37 for an `externalId`
    /// the server considers unstable (it would not survive as a dedup key). On
    /// the batch routes this arrives as a **per-entry** skip while the rest of
    /// the batch lands. **Terminal**: the verdict is deterministic — the same
    /// entry re-sent produces the same skip — so the cursor advances past it.
    /// Holding the anchor here would spin forever on one row.
    ///
    /// The constant exists for classification + logging only; ``SkippedEntry``
    /// deliberately keeps `reason` as an open `String`, so an unknown future
    /// reason lands in the same terminal default instead of breaking decoding.
    public static let reasonUnstableExternalId = "unstable_external_id"
}
