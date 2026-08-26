import Foundation

/// **W-HKBACKFILL** — one-shot historical backfill of server-origin
/// measurements into Apple Health.
///
/// **Why this exists.** The b198 latest-page mirror
/// (`HealthKitService.mirrorServerMeasurements`, hooked into the SWR `.fresh`
/// arm of `MeasurementsStore.load`) only ever sees the newest 400-row page.
/// Server-origin history that predates the app install — or that is simply
/// older than the current page (Withings device imports, file imports) — never
/// reaches Apple Health. A user who connects Withings expects their FULL history
/// in Apple Health. This pass walks the server's full per-kind history for the
/// mirror-eligible sources and hands each page to the SAME mirror primitive, so
/// every anti-duplicate / idempotency / share-auth invariant is reused verbatim.
///
/// **Invariants reused from the b198 mirror (no reinvention):**
/// - Source whitelist `.withings` / `.import_` only — via the shared
///   `MeasurementSource.serverMirrorEligible` policy the mirror also reads.
/// - `HKMetadataKeyExternalUUID = measurement.id` on every sample (anti-dup;
///   the read foreign-filter drops it on read-back → no echo loop).
/// - Per-sample `existsInHealth` externalUUID probe (skips what the latest-page
///   mirror — or a prior partial backfill — already wrote).
/// - Per-write-type share-authorization gate (skips unauthorized types, never
///   fails the whole pass).
/// - Suppressed entirely in standalone mode (same guard as the call site).
/// All of the above live INSIDE `mirrorServerMeasurements`; this driver only
/// supplies the full-history input set and the run-once gate.
///
/// **Paint-safety.** Kicked off as retained utility work after the first authed
/// SWR `.fresh` settles; the full-history walk never gates launch or first paint.
public extension MeasurementsStore {
    /// UserDefaults key prefix for the per-user run-once marker. Partitioned by
    /// the same `HealthKitService.partitionToken` shape anchors use, so a logout
    /// + re-login as a different user yields a fresh one-shot. The persisted
    /// value is the completed schema version (an `Int`); a future code change can
    /// bump `historicalBackfillSchemaVersion` to force every user to re-run.
    private static var historicalBackfillKeyPrefix: String {
        "hl.healthkit.historicalBackfill.v."
    }

    /// Schema version of the backfill. The run-once marker stores the version
    /// that last completed; the gate re-runs whenever the stored value is below
    /// this. Bump to force a one-shot re-run (e.g. when a new mirror-writable
    /// kind is added to `MetricKind.serverMirrorWritableKinds`).
    private static var historicalBackfillSchemaVersion: Int {
        1
    }

    /// Builds a marker from the owner captured before the task's first await.
    /// The live user provider is never consulted by suspended backfill work.
    private static func historicalBackfillMarkerKey(ownerID: String) -> String {
        historicalBackfillKeyPrefix + backfillPartitionToken(for: ownerID)
    }

    private func hasCompletedHistoricalBackfill(markerKey: String) -> Bool {
        let stored = backfillDefaults.integer(forKey: markerKey)
        // `integer(forKey:)` returns 0 for an absent key — below v1, so the gate
        // opens on first eligible launch.
        return stored >= Self.historicalBackfillSchemaVersion
    }

    /// **Trigger.** Called from the SWR `.fresh` arm right after the latest-page
    /// mirror, already inside the standalone + HK-present guard. No-ops when the
    /// per-user run-once marker is already set. Otherwise retains exactly one
    /// utility task whose owner, marker key, and lease are immutable.
    func runHistoricalHealthKitBackfillIfNeeded(healthKit: AnyHealthKitWriter) {
        // Standalone suppression — structural, not just call-site discipline.
        // Mirrors the b198 mirror's standalone guard: in offline/standalone mode
        // there is no server history to mirror (and the create-time double-write
        // reasoning applies symmetrically), so the backfill must never run.
        guard isStandalone?() != true else { return }
        guard historicalBackfillTask == nil else { return }
        guard let lease = captureAuthenticatedSessionLease() else { return }
        let markerKey = Self.historicalBackfillMarkerKey(ownerID: lease.ownerID)
        guard !hasCompletedHistoricalBackfill(markerKey: markerKey) else { return }

        let repo = repo
        let taskID = UUID()
        historicalBackfillTaskID = taskID
        historicalBackfillTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let cleanPass = await Self.performHistoricalBackfill(
                repo: repo,
                healthKit: healthKit,
                lease: lease
            )
            finishHistoricalBackfill(
                taskID: taskID,
                markerKey: markerKey,
                lease: lease,
                cleanPass: cleanPass
            )
        }
    }

    /// Test seam — the same gate + full-history walk the production trigger
    /// runs, but `await`-able inline so the suite can observe completion. The
    /// production path remains paint-safe; this awaits the exact retained task.
    func runHistoricalBackfillBodyForTesting(healthKit: AnyHealthKitWriter) async {
        runHistoricalHealthKitBackfillIfNeeded(healthKit: healthKit)
        await historicalBackfillTask?.value
    }

    private func finishHistoricalBackfill(
        taskID: UUID,
        markerKey: String,
        lease: AuthenticatedSessionLease,
        cleanPass: Bool
    ) {
        defer {
            if historicalBackfillTaskID == taskID {
                historicalBackfillTask = nil
                historicalBackfillTaskID = nil
            }
        }
        guard historicalBackfillTaskID == taskID,
              cleanPass,
              authenticatedEffectIsCurrent(lease) else { return }
        backfillDefaults.set(Self.historicalBackfillSchemaVersion, forKey: markerKey)
    }

    /// Idempotently cancels and awaits the exact work handles retained by this
    /// store. Plan 06-05 calls this only after invalidating the shared registry,
    /// so no replacement session can enter while draining.
    func cancelAndDrainAuthenticatedWork() async {
        let hydration = seriesHydrationTask
        let latestMirror = latestPageMirrorTask
        let backfill = historicalBackfillTask

        hydration?.cancel()
        latestMirror?.cancel()
        backfill?.cancel()

        await hydration?.value
        await latestMirror?.value
        await backfill?.value
    }

    /// Walks the full server history for every mirror-writable kind × eligible
    /// source and hands the collected rows to the b198 mirror. Returns `true`
    /// iff the fetch pass completed cleanly (the caller flips the run-once marker
    /// only then); a `false` return leaves the marker unset so the next eligible
    /// launch retries (the mirror is idempotent, so a partial pass is safe).
    /// `nonisolated static` — runs entirely off the main actor on the detached
    /// task; takes no non-Sendable state.
    internal nonisolated static func performHistoricalBackfill(
        repo: MeasurementsRepository,
        healthKit: AnyHealthKitWriter,
        lease: AuthenticatedSessionLease
    ) async -> Bool {
        var history: [Measurement] = []
        var fetchedKindCount = 0
        do {
            for kind in MetricKind.serverMirrorWritableKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                var kindHadRows = false
                for source in MeasurementSource.serverMirrorEligible {
                    try lease.requireCurrent()
                    let rows = try await repo.historyForBackfill(kind: kind, source: source)
                    try lease.requireCurrent()
                    if !rows.isEmpty {
                        history.append(contentsOf: rows)
                        kindHadRows = true
                    }
                }
                if kindHadRows { fetchedKindCount += 1 }
            }
        } catch is CancellationError {
            return false
        } catch {
            guard lease.isCurrent else { return false }
            // A fetch failed — return `false` so the marker stays unset and the
            // next eligible launch retries. The mirror is idempotent, so any rows
            // already written this pass are skipped on the retry. Localized error
            // only, no PHI.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.warning(
                "HK historical-backfill abgebrochen (Server-Fetch): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }

        let eligibleCount = history.count
        // The mirror applies the source whitelist + per-sample externalUUID
        // existence probe + share-auth gate + batched save. It never throws into
        // the caller (logs internally), so a clean fetch pass is the success
        // condition for the run-once flip.
        do {
            try lease.requireCurrent()
            await healthKit.mirrorServerMeasurements(history)
            try lease.requireCurrent()
        } catch {
            return false
        }

        // Counts only — operator-grade, no PHI. (M = eligible historical rows
        // gathered; K = kinds that had ≥1 such row. The actual written count is
        // logged inside the mirror, since it knows the post-probe delta.)
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.info(
            "HK historical-backfill abgeschlossen: \(eligibleCount, privacy: .public) infrage kommende Verlaufs-Messung(en) über \(fetchedKindCount, privacy: .public) Art(en) gespiegelt."
        )
        return true
    }

    /// Per-user partition token for the run-once marker key. Mirrors the
    /// `HealthKitService.partitionToken` shape (strict `[A-Za-z0-9_-]` allowlist,
    /// 64-char cap, `_anonymous` fallback) so the marker partitions exactly like
    /// the HK anchors. Re-implemented platform-free here so the store stays
    /// buildable without the HealthKit framework (tests).
    nonisolated static func backfillPartitionToken(for userId: String?) -> String {
        guard let raw = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "_anonymous"
        }
        let filtered = raw.unicodeScalars.lazy.filter { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || scalar.value == 0x5F // _
                || scalar.value == 0x2D // -
        }
        let sanitized = String(String.UnicodeScalarView(filtered))
        guard !sanitized.isEmpty else { return "_anonymous" }
        return String(sanitized.prefix(64))
    }
}
