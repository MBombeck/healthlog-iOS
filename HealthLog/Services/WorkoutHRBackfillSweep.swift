import Foundation

/// One page of history the backfill walks over, already mapped to the wire
/// shape. Deliberately platform-free so the sweep's whole progression logic is
/// testable without HealthKit — the HK-backed producer is
/// ``HealthKitWorkoutHistorySource``.
struct WorkoutHRBackfillPage: Sendable, Equatable {
    /// Ready-to-post entries: known workouts that actually CARRY a series.
    /// Shorter than ``fetchedCount`` whenever HealthKit handed out workouts we
    /// drop (our own echoes, degenerate windows, sessions without a single HR
    /// sample — nothing to enrich there).
    let workouts: [WorkoutIngestDTO]

    /// Start date of the oldest workout HealthKit returned for this page —
    /// the anchor for the next cursor. `nil` only when the page is empty.
    let oldestStart: Date?

    /// Stable identifiers for every fetched workout at ``oldestStart``, even
    /// when mapping later drops the row because it has no usable HR series.
    let oldestStartIdentifiers: Set<String>

    /// How many workouts HealthKit actually returned, BEFORE any filtering.
    /// The exhaustion signal: zero means there is no older history left, and
    /// that — not a date horizon — is what ends the sweep.
    let fetchedCount: Int

    init(
        workouts: [WorkoutIngestDTO],
        oldestStart: Date?,
        oldestStartIdentifiers: Set<String> = [],
        fetchedCount: Int
    ) {
        self.workouts = workouts
        self.oldestStart = oldestStart
        self.oldestStartIdentifiers = oldestStartIdentifiers
        self.fetchedCount = fetchedCount
    }
}

/// Typed result of one HealthKit history query. A successful end-of-history
/// signal is intentionally distinct from authorization ambiguity and query
/// failure so only proven exhaustion can latch `isDone`.
enum WorkoutHRBackfillPageOutcome: Sendable, Equatable {
    case page(WorkoutHRBackfillPage)
    case exhausted
    /// HealthKit completed the requested series query but exposed no rows.
    /// Read denial and genuine no-data are indistinguishable, so progression
    /// retains the cursor and reuses the persisted exhaustion probe cooldown.
    case seriesEmpty
    case authorizationPending
    case failed(WorkoutHRBackfillPageFailure)
    case cancelled
}

/// Redacted failure class. The underlying HealthKit error is logged at the
/// source boundary after sanitization and never crosses into persisted state.
enum WorkoutHRBackfillPageFailure: String, Sendable, Equatable {
    case query
    case series
}

/// Test seam over the HealthKit history walk.
protocol WorkoutHRBackfillSourcing: Sendable {
    /// Workouts that started strictly before `before`, newest first, at most
    /// `limit` of them, mapped with their HR series attached.
    func page(before: WorkoutHRBackfillCursor, limit: Int) async -> WorkoutHRBackfillPageOutcome
}

/// **GH #86 — the catch-up pass for workouts that are already on the server
/// without their HR curve.**
///
/// Since #34 we upload heart rate as daily folds only, so every workout
/// synced since then sits server-side with `workout_samples` empty and the web
/// draws nothing. New workouts are fixed at the source (the importer attaches
/// the series on first write); this sweep is for everything that came before.
///
/// It re-posts known workouts WITH their series. That is not a new endpoint
/// and not a new contract: `POST /api/workouts/batch` treats an entry with
/// `samples` on an existing series-less workout as an enrichment — the
/// workout's own fields stay untouched (first-write-wins still holds), and a
/// workout that already has a series is a plain no-op. So the pass is
/// repeatable, and on a server that has not shipped the enrichment path yet it
/// is a silent no-op that changes nothing.
///
/// **How it knows the server can't do it yet.** Only the per-entry status
/// tells us apart: `enriched` means our series landed, `duplicate` means the
/// server ignored it. A batch where every series-bearing entry came back
/// `duplicate` — and nothing was inserted — is the signature of a server
/// without the path. We record that once, rest for a day
/// (``WorkoutHRBackfillState/unsupportedBackoff``), and re-probe with a single
/// chunk later. No retry loop, no exponential storm, and no need for an app
/// update when the server ships.
///
/// **Where it stops.** At the end of the local history — when HealthKit hands
/// out no older workout. The cursor is persisted per user, so the walk resumes
/// across launches instead of restarting.
actor WorkoutHRBackfillSweep {
    /// What one run did — surfaced for tests + the log line.
    enum Outcome: Sendable, Equatable {
        /// Finished earlier, or resting after finding no server support.
        case notDue
        /// The local history is exhausted; a bounded probe cooldown is armed.
        case finished
        /// Walked at least one chunk. `enriched` counts entries the server
        /// reported as `enriched` during this run.
        case progressed(enriched: Int)
        /// The server has no enrichment path yet. Cursor untouched, backoff
        /// armed.
        case serverUnsupported
        /// The upload failed (network / server error). Cursor untouched so
        /// the next run retries the same chunk.
        case failed
        /// Cancellation or an invalidated account lease stopped the pass.
        case cancelled
    }

    private let source: any WorkoutHRBackfillSourcing
    private let repo: any WorkoutBatchUploading
    /// Captured at construction, like the importer's anchor key — the logout
    /// cascade may already have wiped the keychain user-id by the time a
    /// late chunk writes its state back (audit M4 race).
    private let userID: String
    private let leaseIsCurrent: @Sendable () -> Bool
    private let clock: @Sendable () -> Date
    private let maxPageRetries: Int
    private let retryBackoff: @Sendable (Int) async -> Void
    private let defaultsBox: WorkoutDefaultsBox?
    /// `UserDefaults` is not `Sendable`; injected behind a provider closure so
    /// the actor's stored state stays Sendable and tests can pin a suite.
    private let defaultsProvider: @Sendable () -> UserDefaults

    private var defaults: UserDefaults {
        defaultsProvider()
    }

    init(
        source: any WorkoutHRBackfillSourcing,
        repo: any WorkoutBatchUploading,
        userID: String?,
        leaseIsCurrent: @escaping @Sendable () -> Bool = { true },
        clock: @escaping @Sendable () -> Date = Date.init,
        maxPageRetries: Int = 2,
        retryBackoff: @escaping @Sendable (Int) async -> Void = { attempt in
            try? await Task.sleep(for: .milliseconds(250 * attempt))
        },
        defaultsBox: WorkoutDefaultsBox? = nil,
        defaultsProvider: @escaping @Sendable () -> UserDefaults = { .standard }
    ) {
        self.source = source
        self.repo = repo
        self.userID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.leaseIsCurrent = leaseIsCurrent
        self.clock = clock
        self.maxPageRetries = max(0, maxPageRetries)
        self.retryBackoff = retryBackoff
        self.defaultsBox = defaultsBox
        self.defaultsProvider = defaultsProvider
    }

    // 09-08 — the sweep's progression table. Every branch is one transition of
    // one state machine over the persisted backfill cursor; extracting a page
    // of them into helpers would put the transitions in two places and make the
    // "did this pass advance the cursor exactly once" question unanswerable by
    // reading. Its cyclomatic exception below predates Phase 9.
    // function_body_length exception (owner: 09-08): one state machine's single progression table.
    // swiftlint:disable function_body_length
    /// Run one pass: up to `maxChunks` pages of `chunkSize` workouts each,
    /// stopping early on exhaustion, missing server support, or an upload
    /// error. Bounded on purpose — a launch spends a handful of requests on
    /// the backfill and hands the rest to the next launch.
    @discardableResult
    // The switch is the state machine's single progression table.
    // swiftlint:disable:next cyclomatic_complexity
    func run(
        maxChunks: Int = 4,
        chunkSize: Int = WorkoutIngestDTO.maxWorkoutsPerSeriesBatch
    ) async -> Outcome {
        guard hasCurrentLease else { return .cancelled }
        var state = defaultsBox?.loadBackfill(for: userID)
            ?? WorkoutHRBackfillStore.load(for: userID, defaults: defaults)
        guard state.isDue(now: clock()) else {
            await recordDiagnostics(.idle)
            return .notDue
        }
        let source = WorkoutSyncDiagnosticContext.source ?? .foreground
        await MainActor.run {
            HKSyncDiagnostics.shared.recordWorkoutAttempt(source: source)
        }
        await recordDiagnostics(.running)

        var enrichedThisRun = 0
        for _ in 0 ..< max(1, maxChunks) {
            guard hasCurrentLease else { return .cancelled }
            let cursor = state.cursor ?? WorkoutHRBackfillCursor(startDate: clock())
            let pageOutcome = await fetchPage(before: cursor, limit: chunkSize)
            guard hasCurrentLease else { return .cancelled }
            let page: WorkoutHRBackfillPage
            switch pageOutcome {
            case let .page(value):
                page = value
            case .exhausted:
                switch armExhaustionOrRestart(&state) {
                case .restarted:
                    continue
                case .armed:
                    await recordDiagnostics(.finished)
                    return .finished
                case .cancelled:
                    return .cancelled
                }
            case .seriesEmpty:
                switch armExhaustionOrRestart(&state) {
                case .restarted:
                    continue
                case .armed:
                    await recordDiagnostics(.authorizationPending)
                    return .finished
                case .cancelled:
                    return .cancelled
                }
            case .authorizationPending:
                HLLog.healthKit.debug(
                    "workout HR backfill authorization pending — cursor retained"
                )
                await recordDiagnostics(.authorizationPending)
                return .notDue
            case .failed:
                // All bounded attempts failed. Do not mutate the cursor or
                // completion state; the next scheduled pass retries it.
                HLLog.healthKit.error(
                    "workout HR backfill page failed after bounded retries — cursor retained"
                )
                await recordDiagnostics(.failed)
                return .failed
            case .cancelled:
                return .cancelled
            }

            await MainActor.run {
                HKSyncDiagnostics.shared.recordWorkoutFetch(
                    fetched: page.fetchedCount,
                    mapped: page.workouts.count
                )
            }

            // Defensive compatibility for injected/legacy sources that still
            // wrap a successful empty page in `.page`.
            guard page.fetchedCount > 0 else {
                switch armExhaustionOrRestart(&state) {
                case .restarted:
                    continue
                case .armed:
                    await recordDiagnostics(.finished)
                    return .finished
                case .cancelled:
                    return .cancelled
                }
            }

            // Any non-empty query disproves the prior exhaustion candidate.
            // Persist this only with accepted cursor progress below.
            state.isDone = false
            state.nextExhaustionProbeAt = nil

            let nextCursor = WorkoutHRBackfillState.nextCursor(
                after: cursor,
                oldestStart: page.oldestStart,
                oldestStartIdentifiers: page.oldestStartIdentifiers
            )

            // Page held nothing worth posting (echoes only, or no session in
            // it carries HR at all). Still progress: move past it.
            guard !page.workouts.isEmpty else {
                state.cursor = nextCursor
                guard persist(state) else { return .cancelled }
                continue
            }

            let response: WorkoutBatchResponseDTO
            do {
                guard hasCurrentLease else { return .cancelled }
                await MainActor.run {
                    HKSyncDiagnostics.shared.recordWorkoutSend(count: page.workouts.count)
                }
                guard hasCurrentLease else { return .cancelled }
                response = try await repo.uploadBatch(page.workouts, ownerUserID: userID)
                guard hasCurrentLease else { return .cancelled }
                do {
                    try WorkoutBatchAcceptance.validate(postedCount: page.workouts.count, response: response)
                    await recordUploadResponse(response, completeAcceptance: true)
                } catch {
                    await recordUploadResponse(response, completeAcceptance: false)
                    throw error
                }
                guard hasCurrentLease else { return .cancelled }
            } catch {
                guard hasCurrentLease else { return .cancelled }
                // Keep the cursor: the next run retries this exact chunk. The
                // repository already enrolled a retriable failure in the outbox.
                HLLog.healthKit.error(
                    "workout HR backfill upload failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                let failure = uploadFailureClass(for: error)
                await MainActor.run {
                    HKSyncDiagnostics.shared.recordWorkoutFailure(failure)
                }
                await recordDiagnostics(.failed)
                return .failed
            }

            guard applyServerResponse(
                response,
                state: &state,
                enrichedThisRun: &enrichedThisRun
            ) else {
                guard hasCurrentLease else { return .cancelled }
                await recordDiagnostics(.serverUnsupported)
                return .serverUnsupported
            }

            state.cursor = nextCursor
            guard persist(state) else { return .cancelled }
        }

        await recordDiagnostics(.progressed, enriched: enrichedThisRun)
        return .progressed(enriched: enrichedThisRun)
    }

    // swiftlint:enable function_body_length

    private enum ExhaustionResolution {
        case restarted
        case armed
        case cancelled
    }

    /// Both typed exhaustion and the legacy empty-page wrapper use this policy.
    private func armExhaustionOrRestart(
        _ state: inout WorkoutHRBackfillState
    ) -> ExhaustionResolution {
        if state.restartFromNewestAfterCurrentWalk {
            state.cursor = nil
            state.restartFromNewestAfterCurrentWalk = false
            state.isDone = false
            state.nextExhaustionProbeAt = nil
            return persist(state) ? .restarted : .cancelled
        }
        state.isDone = true
        state.nextExhaustionProbeAt = clock().addingTimeInterval(WorkoutHRBackfillState.exhaustionProbeBackoff)
        guard persist(state) else { return .cancelled }
        // Pure row count — operator-grade, no health data.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.info(
            "workout HR backfill exhausted — enriched=\(state.enrichedCount, privacy: .public) total; probing later"
        )
        return .armed
    }

    /// Retries only explicit query failures, always against the same cursor.
    /// Authorization ambiguity and successful exhaustion are terminal for the
    /// current pass and never consume the retry budget.
    private func fetchPage(
        before cursor: WorkoutHRBackfillCursor,
        limit: Int
    ) async -> WorkoutHRBackfillPageOutcome {
        for retry in 0 ... maxPageRetries {
            guard hasCurrentLease else { return .cancelled }
            let outcome = await source.page(before: cursor, limit: limit)
            guard hasCurrentLease else { return .cancelled }
            guard case .failed = outcome, retry < maxPageRetries else {
                return outcome
            }
            let attempt = retry + 1
            // Counts only — no cursor timestamp or workout values in logs.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.warning(
                "workout HR backfill page retry \(attempt, privacy: .public)/\(maxPageRetries, privacy: .public)"
            )
            await retryBackoff(attempt)
            guard hasCurrentLease else { return .cancelled }
        }
        return .failed(.query)
    }

    @discardableResult
    private func persist(_ state: WorkoutHRBackfillState) -> Bool {
        guard hasCurrentLease else { return false }
        if let defaultsBox {
            defaultsBox.saveBackfill(state, for: userID)
        } else {
            WorkoutHRBackfillStore.save(state, for: userID, defaults: defaults)
        }
        return true
    }

    private func applyServerResponse(
        _ response: WorkoutBatchResponseDTO,
        state: inout WorkoutHRBackfillState,
        enrichedThisRun: inout Int
    ) -> Bool {
        let enriched = response.entries.filter { $0.status == .enriched }.count
        let inserted = response.entries.filter { $0.status == .inserted }.count
        if enriched > 0 {
            state.serverSupportsEnrichment = true
            state.enrichedCount += enriched
            enrichedThisRun += enriched
            return true
        }
        guard inserted > 0 || state.serverSupportsEnrichment else {
            // Every series-bearing entry bounced as a duplicate and the
            // server never once reported `enriched`: the path is not live.
            state.lastUnsupportedProbeAt = clock()
            guard persist(state) else { return false }
            HLLog.healthKit.info(
                "workout HR backfill idle — server has no enrichment path yet, re-probing in 24h"
            )
            return false
        }
        return true
    }

    private var hasCurrentLease: Bool {
        !Task.isCancelled && !userID.isEmpty && leaseIsCurrent()
    }

    private func recordUploadResponse(
        _ response: WorkoutBatchResponseDTO,
        completeAcceptance: Bool
    ) async {
        let accepted = response.entries.filter { entry in
            entry.status == .inserted || entry.status == .duplicate || entry.status == .enriched
        }.count
        let skipped = max(0, response.entries.count - accepted)
        await MainActor.run {
            HKSyncDiagnostics.shared.recordWorkoutResponse(
                accepted: accepted,
                skipped: skipped,
                completeAcceptance: completeAcceptance
            )
        }
    }

    private nonisolated func uploadFailureClass(
        for error: any Error
    ) -> HKSyncDiagnostics.WorkoutFailureClass {
        if error is WorkoutBatchAcceptanceError {
            return .serverRejected
        }
        if let error = error as? HLError, case .notPersisted = error {
            return .persistence
        }
        return .transport
    }

    private func recordDiagnostics(
        _ state: HKSyncDiagnostics.WorkoutBackfillState,
        enriched: Int = 0
    ) async {
        await MainActor.run {
            HKSyncDiagnostics.shared.recordWorkoutBackfill(state, enriched: enriched)
        }
    }
}
