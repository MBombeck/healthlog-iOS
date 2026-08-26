import Foundation

/// Platform-agnostic seam for the nutrient daily-totals sync (GH #48, server
/// v1.28). Lives so `AppContainer` can hold a `NutrientDailySyncing?` slot.
/// Single surface: `triggerNutrientSync()`.
public protocol NutrientDailySyncing: AnyObject, Sendable {
    /// Sync the nutrient day-totals for the current + previous local day (30-day
    /// backfill on first enable). Fire-and-forget — the coordinator decides the
    /// lookback window internally and logs the outcome; the caller (sweep hook /
    /// foreground refresh) needs no summary. Self-gates on the opt-in `nutrients`
    /// module (default OFF) + a present auth token, so it is safe to call
    /// unconditionally.
    func triggerNutrientSync() async
}

/// The HK-query dependency the coordinator needs, expressed as a protocol so it
/// can be driven with synthetic ``HealthKitDailyStatRow`` rows in tests (over a
/// real ``APIClient`` + `MockURLProtocol`). ``HealthKitStatisticsService``
/// conforms via its `dailyRows(forNutrientIdentifier:wireUnit:from:to:)` method.
public protocol NutrientDailyRowsProviding: Sendable {
    func dailyRows(
        forNutrientIdentifier identifier: String,
        wireUnit: String,
        from: Date,
        to: Date
    ) async throws -> [HealthKitDailyStatRow]
}

/// Coordinator for the nutrient daily-totals upload path (GH #48, server
/// v1.28.34).
///
/// **What it does:** collects per-day cumulative-sum totals for the 26 catalog
/// `Dietary*` types (24 vitamins/minerals + water + caffeine) via
/// `HKStatisticsCollectionQuery`, day-anchored in the user's current timezone
/// (reusing ``HealthKitStatisticsService`` — the SAME plumbing the `stats:`
/// measurement path uses), and upserts them to `POST /api/nutrients/batch`.
/// Never posts raw samples.
///
/// **Module gate (default OFF):** the whole surface is behind the opt-in
/// `nutrients` module. `sync()` short-circuits when the module is off — so we
/// never run an HK query (and never trigger the read-authorization prompt) for a
/// user who has not switched it on. If the server later disables the module
/// mid-flight it answers `403 module.disabled`; ``APIClient`` throws
/// ``HLError/moduleDisabled(_:)`` and mirrors the key into ``ModuleGate``, so the
/// run STOPS (no retry) and the next run's local gate is already OFF — the
/// existing enable-in-settings hint surfaces via the mirrored gate.
///
/// **Read authorization is unknowable:** HealthKit deliberately refuses to tell
/// an app whether a READ permission was granted — a denied type answers exactly
/// like an empty one (no error, no samples). The coordinator therefore never
/// claims to know: it neither reports "permission denied" nor treats an empty
/// window as a finished backfill. The one-shot 30-day window stays armed until a
/// run genuinely uploads rows, so a permission granted later (Settings → Health)
/// still gets the full history. The read surface says the same thing to the user
/// — the empty state names the condition ("once Apple Health has data") instead
/// of asserting a cause it cannot verify.
///
/// **Upsert contract:** upsert key is `(day, nutrient)`; a re-post REPLACES the
/// stored total and reports `updated` (never `duplicate`). Per-entry `skipped`
/// rows (`unit_mismatch` | `value_out_of_range` | `day_invalid`) are terminal —
/// logged and dropped, never retried.
///
/// `Sendable` actor so the composition-root can inject it into the sweep-hook +
/// foreground-refresh call sites off the main actor.
public actor NutrientDailySyncCoordinator {
    private let statisticsService: NutrientDailyRowsProviding
    private let api: APIClientProtocol
    private let keychain: KeychainStoring
    /// Reads ``ModuleGate/isEnabled(_:)`` for `.nutrients` on the main actor.
    /// Injected as a closure so the actor stays free of the `@MainActor`
    /// `ModuleGate` reference while still honouring the live toggle.
    private let isModuleEnabled: @Sendable () async -> Bool
    private let calendar: Calendar
    private let clock: @Sendable () -> Date
    /// `UserDefaults` is not `Sendable` — injected behind a provider closure
    /// (same pattern as ``HealthKitHRBucketSyncCoordinator``) so the actor's
    /// stored state stays Sendable and tests can pin an isolated suite.
    private let defaultsProvider: @Sendable () -> UserDefaults

    private var defaults: UserDefaults {
        defaultsProvider()
    }

    /// Per-user one-shot "first-enable 30-day backfill done" flag prefix. Only
    /// set once a run has actually UPLOADED day-rows (see `sync()`): an empty
    /// window is ambiguous between "no data" and "read authorization denied",
    /// so it leaves the one-shot armed.
    static let backfillDoneKeyPrefix = "hl.healthkit.nutrientBackfillCompleted."
    /// First-enable backfill window (days). Server contract: 30.
    static let backfillLookbackDays = 30
    /// Steady-state lookback. `1` day back → the day-anchor rounds `from` to
    /// yesterday 00:00, so the query covers the previous + current local day.
    static let incrementalLookbackDays = 1
    /// Server cap — max 500 entries per batch call.
    static let maxEntriesPerBatch = 500

    public init(
        statisticsService: NutrientDailyRowsProviding,
        api: APIClientProtocol,
        keychain: KeychainStoring,
        isModuleEnabled: @escaping @Sendable () async -> Bool,
        calendar: Calendar = .current,
        clock: @escaping @Sendable () -> Date = { Date() },
        defaultsProvider: @escaping @Sendable () -> UserDefaults = { .standard }
    ) {
        self.statisticsService = statisticsService
        self.api = api
        self.keychain = keychain
        self.isModuleEnabled = isModuleEnabled
        self.calendar = calendar
        self.clock = clock
        self.defaultsProvider = defaultsProvider
    }

    /// Runs one sync. Returns a summary of the per-entry outcomes tallied across
    /// all batch chunks; tests assert against the counters + the captured
    /// payloads.
    @discardableResult
    public func sync() async -> NutrientSyncSummary {
        // Gate 1 — auth token: pre-login → nothing to upload.
        guard keychain.getString(forKey: KeychainKey.authToken)?.isEmpty == false else {
            HLLog.healthKit.debug("NUTRIENT sync skipped — no auth token")
            return .zero
        }
        // Gate 2 — module (default OFF): never query HK / prompt for read auth
        // when the opt-in module is off.
        guard await isModuleEnabled() else {
            HLLog.healthKit.debug("NUTRIENT sync skipped — nutrients module OFF")
            return .zero
        }

        let userID = keychain.getString(forKey: KeychainKey.userID)
        let backfillKey = Self.backfillDoneKeyPrefix
            + HealthKitBackfillWindowStore.partitionToken(for: userID)
        let firstEnable = !defaults.bool(forKey: backfillKey)
        let lookback = firstEnable ? Self.backfillLookbackDays : Self.incrementalLookbackDays

        let now = clock()
        let from = calendar.date(byAdding: .day, value: -lookback, to: now) ?? now

        // Collect one entry per (nutrient, day-with-data). A per-type HK query
        // failure is logged + skipped and does not block the other types.
        var entries: [NutrientIntakeEntryDTO] = []
        for item in NutrientCatalog.all {
            do {
                let rows = try await statisticsService.dailyRows(
                    forNutrientIdentifier: item.hkIdentifier,
                    wireUnit: item.unit,
                    from: from,
                    to: now
                )
                for row in rows {
                    entries.append(NutrientIntakeEntryDTO(
                        day: row.dayKey,
                        nutrient: item.code,
                        unit: item.unit,
                        amount: row.value
                    ))
                }
            } catch {
                let code = item.code.rawValue
                HLLog.healthKit
                    .error(
                        "NUTRIENT stats query failed for \(code, privacy: .public): \(error.localizedDescription, privacy: .private)"
                    )
            }
        }

        guard !entries.isEmpty else {
            // No dietary day-rows in the window. HealthKit does NOT tell us
            // whether that means "nothing recorded" or "read authorization
            // denied" — a denied read is indistinguishable from an empty store
            // by design. So we must NOT treat it as a completed backfill: the
            // flag stays armed and the wide 30-day window is retried on the
            // next wake. Otherwise a user who denies the prompt (or grants it
            // later in Settings → Health) would silently lose the 30 days of
            // history the contract asks for, forever.
            //
            // Cost of leaving it armed is near zero: the wide window only
            // enumerates 30 empty day-buckets per type — it is exactly the
            // no-data case in which the query is cheapest.
            HLLog.healthKit.debug("NUTRIENT sync — no dietary day-rows in window (no data or read denied)")
            return .zero
        }

        var summary = NutrientSyncSummary.zero
        var stoppedForModuleDisabled = false
        for chunk in entries.chunked(into: Self.maxEntriesPerBatch) {
            do {
                let response = try await postBatch(chunk)
                summary = summary.adding(response)
            } catch HLError.moduleDisabled {
                // 403 module.disabled — stop syncing, do NOT retry. APIClient
                // already mirrored the key into ModuleGate, so the next run's
                // local gate is OFF and the settings hint surfaces.
                HLLog.healthKit.info("NUTRIENT sync stopped — nutrients module disabled (403)")
                stoppedForModuleDisabled = true
                break
            } catch {
                HLLog.healthKit.error(
                    "NUTRIENT batch upload failed: \(error.localizedDescription, privacy: .private)"
                )
                summary = summary.incrementingFailedBatch()
            }
        }

        // Only mark the one-shot backfill complete once the wide window has
        // actually landed (mirrors the daily-stats M-3 ordering — a module-
        // disabled or failed first sweep re-arms on the next enable).
        if !stoppedForModuleDisabled, summary.failedBatches == 0 {
            markBackfillDone(key: backfillKey)
        }
        return summary
    }

    // MARK: - Wire

    private func postBatch(_ entries: [NutrientIntakeEntryDTO]) async throws -> NutrientBatchResponseDTO {
        let payload = NutrientBatchRequestDTO(entries: entries)
        let req: APIRequest<NutrientBatchResponseDTO> = try .post(
            "/api/nutrients/batch",
            body: payload,
            encoder: .hlDefault,
            idempotencyKey: IdempotencyKey()
        )
        let response = try await api.send(req)
        // Per-entry skips are terminal — log + drop, never retry.
        for skip in response.skipped {
            let index = skip.index
            let reason = skip.reason
            HLLog.healthKit
                .info(
                    "NUTRIENT entry skipped index=\(index, privacy: .public) reason=\(reason, privacy: .public)"
                )
        }
        return response
    }

    // MARK: - First-enable backfill flag

    private func markBackfillDone(key: String) {
        defaults.set(true, forKey: key)
    }
}

extension NutrientDailySyncCoordinator: NutrientDailySyncing {
    public func triggerNutrientSync() async {
        let summary = await sync()
        let inserted = summary.inserted
        let updated = summary.updated
        let skipped = summary.skipped
        let failed = summary.failedBatches
        HLLog.healthKit
            .info(
                """
                NUTRIENT sync done — inserted=\(inserted, privacy: .public) \
                updated=\(updated, privacy: .public) \
                skipped=\(skipped, privacy: .public) \
                failedBatches=\(failed, privacy: .public)
                """
            )
    }
}

/// Tally of a nutrient sync run, aggregated across every batch chunk. `inserted`
/// / `updated` / `skipped` mirror the server's per-entry outcomes; `failedBatches`
/// counts whole-chunk POST failures (network/5xx) that did not land.
public struct NutrientSyncSummary: Sendable, Equatable {
    public let inserted: Int
    public let updated: Int
    public let skipped: Int
    public let failedBatches: Int

    public init(inserted: Int, updated: Int, skipped: Int, failedBatches: Int) {
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.failedBatches = failedBatches
    }

    public static let zero = NutrientSyncSummary(inserted: 0, updated: 0, skipped: 0, failedBatches: 0)

    public var totalUpserted: Int {
        inserted + updated
    }

    func adding(_ response: NutrientBatchResponseDTO) -> NutrientSyncSummary {
        NutrientSyncSummary(
            inserted: inserted + response.inserted,
            updated: updated + response.updated,
            skipped: skipped + response.skipped.count,
            failedBatches: failedBatches
        )
    }

    func incrementingFailedBatch() -> NutrientSyncSummary {
        NutrientSyncSummary(
            inserted: inserted,
            updated: updated,
            skipped: skipped,
            failedBatches: failedBatches + 1
        )
    }
}

// MARK: - Chunking helper

private extension Array {
    /// Splits into consecutive slices of at most `size` (caps the batch to the
    /// server's 500-entry ceiling).
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
