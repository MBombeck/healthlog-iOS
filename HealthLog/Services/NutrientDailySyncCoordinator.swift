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
/// stored total and reports `updated` (never `duplicate`).
///
/// **Per-entry skips (#115 / 0.3), classified against the server route**
/// (`src/app/api/nutrients/batch/route.ts` at v1.39.0):
///
/// * `unit_mismatch` | `value_out_of_range` | `day_invalid` are validation
///   verdicts on the entry itself — the same row gets the same answer on every
///   re-post. Terminal: the sweep may move past them, but never in silence —
///   each one is written to the per-account refusal register
///   (``NutrientRefusalRegister``) with day, nutrient, amount and reason.
/// * `upsert_failed` is the server's DB write failing for a whole group, not a
///   verdict on the entry. Transient: `lastSweepEnd` and the backfill marker
///   stay put, so the next sweep re-reads and re-posts the day (the upsert makes
///   that harmless). Bounded: after ``maxHeldSweeps`` consecutive held sweeps
///   the rows go into the register and the sweep moves on — a server that
///   never recovers must not pin the window until the day ages out of the
///   30-day catch-up bound unseen.
/// * A reason this build does not know holds like `upsert_failed` (fail-closed,
///   the same rule as `MeasurementBatchAcceptance`).
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
    /// Build 273 (A12) — see `sweepWindowStart`.
    static let lastSweepEndKeyPrefix = "hl.healthkit.nutrientLastSweepEndUTC."
    /// #115 / 0.3 — consecutive sweeps held by a transient per-entry skip.
    static let heldSweepsKeyPrefix = "hl.healthkit.nutrientHeldSweeps."
    /// #115 / 0.3 — how many consecutive sweeps a transient skip may hold the
    /// window before its rows are recorded as refused and the sweep moves on.
    static let maxHeldSweeps = 5
    /// Server skip reasons that are a verdict on the entry itself (see the type
    /// doc). Everything else — `upsert_failed`, an unknown word — is transient.
    static let terminalSkipReasons: Set<String> = ["unit_mismatch", "value_out_of_range", "day_invalid"]
    static let maxCatchUpDays = 30

    /// The sweep's `from`: never narrower than the lookback, and — once a sweep
    /// has completed — never later than one day before that sweep's end,
    /// bounded at ``maxCatchUpDays``. A 1-day incremental lookback otherwise
    /// lost every day of a dormancy longer than a day.
    nonisolated static func sweepWindowStart(
        now: Date,
        lookbackDays: Int,
        lastCompletedSweepEnd: Date?,
        calendar: Calendar
    ) -> Date {
        let lookbackFrom = calendar.date(byAdding: .day, value: -lookbackDays, to: now) ?? now
        guard let lastCompletedSweepEnd else { return lookbackFrom }
        let overlap = calendar.date(byAdding: .day, value: -1, to: lastCompletedSweepEnd) ?? lastCompletedSweepEnd
        let bound = calendar.date(byAdding: .day, value: -maxCatchUpDays, to: now) ?? now
        return min(lookbackFrom, max(overlap, bound))
    }

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
        let partition = HealthKitBackfillWindowStore.partitionToken(for: userID)
        await NutrientRefusalRegister(defaultsProvider: defaultsProvider, userID: userID).migrate(userID: userID)
        let backfillKey = Self.backfillDoneKeyPrefix + partition
        let firstEnable = !defaults.bool(forKey: backfillKey)
        let lookback = firstEnable ? Self.backfillLookbackDays : Self.incrementalLookbackDays

        let now = clock()
        let lastSweepKey = Self.lastSweepEndKeyPrefix + partition
        let from = Self.sweepWindowStart(
            now: now,
            lookbackDays: lookback,
            lastCompletedSweepEnd: defaults.object(forKey: lastSweepKey) as? Date,
            calendar: calendar
        )

        let (entries, queryFailed) = await collectEntries(from: from, to: now)
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

        let run = await upload(entries)
        // INT-A — terminal refusals go into the ONE skip register (per account,
        // listed in Sync Diagnostics, wiped at sign-out). A write that does not
        // verify holds the sweep: the next one posts the day again.
        let recorded = await NutrientRefusalRegister.record(run.refused, userID: userID)

        // Only mark the one-shot backfill complete once the wide window has
        // actually landed (mirrors the daily-stats M-3 ordering — a module-
        // disabled or failed first sweep re-arms on the next enable).
        // A HealthKit query that threw (e.g. protected data while the device is
        // locked) did not read its nutrient; advancing would skip that window.
        guard !run.stoppedForModuleDisabled, run.summary.failedBatches == 0, !queryFailed else { return run.summary }
        guard recorded else { return run.summary.holding(run.refused.count) }
        guard await releaseHeldSkips(run.held, heldKey: Self.heldSweepsKeyPrefix + partition, userID: userID) else {
            return run.summary.holding(run.held.count)
        }
        markBackfillDone(key: backfillKey)
        defaults.set(now, forKey: lastSweepKey)
        return run.summary
    }

    /// Collect one entry per (nutrient, day-with-data). A per-type HK query
    /// failure is logged + skipped and does not block the other types — but it
    /// is reported, so the sweep does not move past the window it never read.
    private func collectEntries(
        from: Date,
        to now: Date
    ) async -> (entries: [NutrientIntakeEntryDTO], queryFailed: Bool) {
        var entries: [NutrientIntakeEntryDTO] = []
        var queryFailed = false
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
                queryFailed = true
                let code = item.code.rawValue
                HLLog.healthKit
                    .error(
                        "NUTRIENT stats query failed for \(code, privacy: .public): \(error.localizedDescription, privacy: .private)"
                    )
            }
        }
        return (entries, queryFailed)
    }

    /// What one upload pass over every chunk proved.
    private struct UploadRun {
        var summary = NutrientSyncSummary.zero
        var stoppedForModuleDisabled = false
        /// Terminal verdicts (see the type doc) — recorded, not retried.
        var refused: [NutrientRefusal] = []
        /// Transient skips — the server did not store these rows.
        var held: [NutrientRefusal] = []
    }

    private func upload(_ entries: [NutrientIntakeEntryDTO]) async -> UploadRun {
        var run = UploadRun()
        for chunk in entries.chunked(into: Self.maxEntriesPerBatch) {
            do {
                let response = try await postBatch(chunk)
                run.summary = run.summary.adding(response)
                let split = Self.classifySkips(response, posted: chunk)
                run.refused += split.terminal
                run.held += split.transient
            } catch HLError.moduleDisabled {
                // 403 module.disabled — stop syncing, do NOT retry. APIClient
                // already mirrored the key into ModuleGate, so the next run's
                // local gate is OFF and the settings hint surfaces.
                HLLog.healthKit.info("NUTRIENT sync stopped — nutrients module disabled (403)")
                run.stoppedForModuleDisabled = true
                break
            } catch HLError.rateLimited {
                // #110 — the batch bucket answered 429. Every further chunk of
                // this sweep would meet the same refusal, so stop sending. The
                // failed batch holds `lastSweepEnd`; nothing is registered. The
                // next sweep re-posts the window (day-keyed upsert).
                HLLog.healthKit.info("NUTRIENT sync paused — rate limited (429), sweep holds")
                run.summary = run.summary.incrementingFailedBatch()
                break
            } catch {
                HLLog.healthKit.error(
                    "NUTRIENT batch upload failed: \(error.localizedDescription, privacy: .private)"
                )
                run.summary = run.summary.incrementingFailedBatch()
            }
        }
        return run
    }

    /// #115 / 0.3 — may the sweep move past this run's transient skips?
    ///
    /// A transient per-entry skip is a row the server did not store. Moving
    /// `lastSweepEnd` past it lost that day for good once the incremental
    /// window no longer reached it. So the window holds — for at most
    /// ``maxHeldSweeps`` consecutive sweeps, after which the rows are recorded
    /// where a person can see them and released. Returns `true` when the sweep
    /// may advance.
    private func releaseHeldSkips(
        _ held: [NutrientRefusal],
        heldKey: String,
        userID: String?
    ) async -> Bool {
        guard !held.isEmpty else {
            defaults.removeObject(forKey: heldKey)
            return true
        }
        let heldSweeps = defaults.integer(forKey: heldKey) + 1
        guard heldSweeps >= Self.maxHeldSweeps else {
            defaults.set(heldSweeps, forKey: heldKey)
            // Two counts — operator-grade, no nutrient, day or amount.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info(
                "NUTRIENT sweep held — \(held.count, privacy: .public) transient skip(s), sweep \(heldSweeps, privacy: .public)"
            )
            return false
        }
        guard await NutrientRefusalRegister.record(held, userID: userID) else { return false }
        defaults.removeObject(forKey: heldKey)
        // Two counts — operator-grade, no nutrient, day or amount.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.error(
            "NUTRIENT sweep released \(held.count, privacy: .public) transient skip(s) after \(heldSweeps, privacy: .public) sweeps — recorded"
        )
        return true
    }

    /// Splits one response's skips into terminal verdicts and transient
    /// failures, each carrying the posted row it names. An index outside the
    /// posted chunk names nothing and is ignored.
    nonisolated static func classifySkips(
        _ response: NutrientBatchResponseDTO,
        posted: [NutrientIntakeEntryDTO]
    ) -> (terminal: [NutrientRefusal], transient: [NutrientRefusal]) {
        var terminal: [NutrientRefusal] = []
        var transient: [NutrientRefusal] = []
        var seen = Set<Int>()
        for skip in response.skipped where posted.indices.contains(skip.index) {
            guard seen.insert(skip.index).inserted else { continue }
            let row = NutrientRefusal(entry: posted[skip.index], reason: skip.reason)
            if terminalSkipReasons.contains(skip.reason) {
                terminal.append(row)
            } else {
                transient.append(row)
            }
        }
        return (terminal, transient)
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
        // Classified by `sync()` (terminal → register, transient → hold); the
        // log line stays for the operator.
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
    /// #115 / 0.3 — transient skips that held the sweep window this run.
    public let heldSkips: Int

    public init(inserted: Int, updated: Int, skipped: Int, failedBatches: Int, heldSkips: Int = 0) {
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.failedBatches = failedBatches
        self.heldSkips = heldSkips
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
            failedBatches: failedBatches,
            heldSkips: heldSkips
        )
    }

    func holding(_ count: Int) -> NutrientSyncSummary {
        NutrientSyncSummary(
            inserted: inserted,
            updated: updated,
            skipped: skipped,
            failedBatches: failedBatches,
            heldSkips: heldSkips + count
        )
    }

    func incrementingFailedBatch() -> NutrientSyncSummary {
        NutrientSyncSummary(
            inserted: inserted,
            updated: updated,
            skipped: skipped,
            failedBatches: failedBatches + 1,
            heldSkips: heldSkips
        )
    }
}

// MARK: - Refusal register (#115 / 0.3)

/// One nutrient day-total the server did not store, with the reason it gave.
/// Carries what a person needs to recognise the row — day, nutrient, amount,
/// unit — and nothing about the account.
public struct NutrientRefusal: Codable, Sendable, Equatable {
    public let day: String
    public let nutrient: String
    public let unit: String
    public let amount: Double
    public let reason: String

    init(entry: NutrientIntakeEntryDTO, reason: String) {
        day = entry.day
        nutrient = entry.nutrient.rawValue
        unit = entry.unit
        amount = entry.amount
        self.reason = reason
    }
}

/// The nutrient side of the ONE skip register (``HealthKitSkippedRowRegister``,
/// INT-A): the rows the sweep moved past without the server storing them.
/// A refusal a person cannot see is data loss; these rows are listed in Sync
/// Diagnostics next to the measurement refusals and wiped at sign-out.
///
/// The UserDefaults list A3 wrote (`hl.healthkit.nutrientRefusals.<token>`,
/// keyed by `(day, nutrient)`) is still read, once, by ``migrate(userID:)``:
/// its rows move into the register and the key is removed.
public struct NutrientRefusalRegister: Sendable {
    static let keyPrefix = "hl.healthkit.nutrientRefusals."
    static let capacity = 400

    private let register: HealthRefusalRegister<NutrientRefusal>

    public init(defaultsProvider: @escaping @Sendable () -> UserDefaults = { .standard }, userID: String?) {
        register = HealthRefusalRegister(
            keyPrefix: Self.keyPrefix,
            userID: userID,
            capacity: Self.capacity,
            defaultsProvider: defaultsProvider
        )
    }

    /// The legacy list's rows (empty once migrated).
    public var entries: [NutrientRefusal] {
        register.entries
    }

    /// Seeds the legacy list (update-path tests only).
    func record(_ refusals: [NutrientRefusal]) {
        register.record(refusals)
    }

    /// Records refusals in the account's skip register. `true` once the write
    /// verified (or there was nothing to write).
    static func record(_ refusals: [NutrientRefusal], userID: String?) async -> Bool {
        guard !refusals.isEmpty else { return true }
        guard let userID else { return false }
        do {
            try await HealthKitSkippedRowRegister.current.record(
                refusals.map { HealthKitSkippedEntry(nutrient: $0.intakeEntry, reason: $0.reason) },
                ownerID: userID,
                build: HealthKitSkipRegisterBuild.current
            )
            return true
        } catch {
            HLLog.healthKit.error("NUTRIENT refusals not recorded — sweep holds")
            return false
        }
    }

    /// Moves the legacy list into the skip register, then drops it. A write
    /// that fails leaves the list for the next sweep.
    func migrate(userID: String?) async {
        let legacy = register.entries
        guard !legacy.isEmpty, await Self.record(legacy, userID: userID) else { return }
        register.clear()
    }
}

extension NutrientRefusal {
    /// The day-total as it was posted (the register keeps the wire row).
    var intakeEntry: NutrientIntakeEntryDTO {
        NutrientIntakeEntryDTO(day: day, nutrient: NutrientCode(tolerant: nutrient), unit: unit, amount: amount)
    }
}

extension NutrientRefusal: HealthRefusalRecord {
    var refusalKey: String {
        day + "|" + nutrient
    }

    var refusalSortKey: String {
        refusalKey
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
