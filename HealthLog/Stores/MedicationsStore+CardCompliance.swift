import Foundation

/// **v0.6.1.2 Y4 / v0.6.1.4 Y4.2 — per-medication 7- and 30-day compliance.**
///
/// **Y4 (original):** local-only port of the web's `calculateCompliance()`
/// (`src/lib/analytics/compliance.ts:130-203`) — `complianceSnapshot` runs
/// against the in-memory intake window the store has hydrated.
///
/// **Y4.2 (this revision):** the store grows a server-fetched snapshot
/// cache (`complianceCardSnapshots`) wired to
/// `GET /api/medications/[id]/compliance`. The card stack consumes
/// `cardComplianceSnapshot(for:)` which prefers the server value and
/// falls back to the local algorithm when the network round-trip
/// hasn't landed yet (cold cache / offline / first paint). The local
/// port stays in place as the fallback path so the card never reads
/// `nil` rates on a fresh device — the operator sees a number that
/// converges towards the server canonical value within one revalidate
/// tick.
///
/// Why server-canonical: the local algorithm only sees
/// `todayIntakes` (one day's worth of events). A 7- or 30-day window
/// divided against effectively zero history reads pessimistically
/// (e.g. Trulicity weekly med showing 14% / 11% on a fresh paint).
/// The server applies the same `calculateCompliance` against the
/// medication's full event history, so the numbers agree with the
/// web app at all times.
///
/// **Algorithm (web parity):**
///
/// 1. `effectiveDays = min(days, ceil((now − earliestSeenScheduledFor) / day))`
///    — never count days before the medication had any data. Web uses
///    `medication.createdAt`; iOS doesn't carry that field on the wire,
///    so we approximate via the earliest `scheduledFor` we know about
///    in the today + history intakes the store has hydrated. For a
///    fresh medication the earliest seen date is "today" and the
///    effective-days clamp keeps the rate at 100% instead of
///    pessimistically dividing by 30 against 0 taken events.
/// 2. `totalExpected = schedules.length × effectiveDays` (web mirror).
/// 3. `taken = events where takenAt != nil && !skipped` within the
///    `[now − days × 24h, now]` window.
/// 4. `rate = totalExpected == 0 ? 100 : min(100, round(taken / totalExpected × 100))`
///    — schedule-less (PRN) medications always read 100% so the card
///    bar fills cleanly without confusing the operator.
///
/// **Input scope:** the store consumes the same `todayIntakes` (which
/// only covers today) plus a second window-load helper (see below) that
/// fetches the trailing 30-day history per medication on demand. The
/// `complianceSnapshot(for:)` accessor expects the caller to pass a
/// merged window of intake events — `MedicationCard` resolves this from
/// the per-medication compliance fetch on render.
public extension MedicationsStore {
    /// Snapshot consumed by the medication card. Two rates +
    /// per-medication day count so the UI knows whether to clamp
    /// against the medication's own short lifespan (e.g. 3-day-old
    /// drug → 7-day rate divides by 3, not 7).
    struct ComplianceCardSnapshot: Sendable, Equatable {
        /// 0-100 rate over the trailing 7 days (or the medication's
        /// lifespan, whichever is shorter). `nil` when the medication
        /// has no schedules configured at all (PRN/on-demand).
        public let rate7: Int?
        /// 0-100 rate over the trailing 30 days. Same nil semantics.
        public let rate30: Int?

        /// **v0.14.1 #127 — server cadence-scaled display windows.** Populated
        /// from the server `complianceDisplay` block (daily med → 7/30; weekly
        /// med → 30/90). When present the card renders these two rows with the
        /// server-supplied day counts as labels; nil on local-fallback / old
        /// server, where the card falls back to the fixed 7/30 rows above.
        public let displayShortDays: Int?
        public let displayShortRate: Int?
        public let displayLongDays: Int?
        public let displayLongRate: Int?

        public init(
            rate7: Int?,
            rate30: Int?,
            displayShortDays: Int? = nil,
            displayShortRate: Int? = nil,
            displayLongDays: Int? = nil,
            displayLongRate: Int? = nil
        ) {
            self.rate7 = rate7
            self.rate30 = rate30
            self.displayShortDays = displayShortDays
            self.displayShortRate = displayShortRate
            self.displayLongDays = displayLongDays
            self.displayLongRate = displayLongRate
        }

        /// The two `(days, rate)` rows the card paints. Prefers the server
        /// cadence-scaled `complianceDisplay` windows; falls back to the fixed
        /// 7/30 windows (local algorithm / pre-2026-06-01 server) so a card
        /// never reads blank.
        public var displayRows: [(days: Int, rate: Int)] {
            if let sd = displayShortDays, let sr = displayShortRate,
               let ld = displayLongDays, let lr = displayLongRate
            {
                return [(sd, sr), (ld, lr)]
            }
            var rows: [(days: Int, rate: Int)] = []
            if let rate7 { rows.append((7, rate7)) }
            if let rate30 { rows.append((30, rate30)) }
            return rows
        }
    }

    /// Resolves the compliance snapshot for a given medication from the
    /// supplied intake window. `windowIntakes` is the union of
    /// today-intakes + the per-medication history fetched by the card.
    /// Pure function — no I/O, exposed so the store + tests share the
    /// exact same math the card paints.
    ///
    /// Web parity: this method is the iOS port of `calculateCompliance`
    /// applied at the two windows the web card surfaces (7 + 30 days).
    /// The numbers therefore agree with `/api/medications/[id]/compliance`
    /// modulo the `createdAt` approximation noted in the file header.
    ///
    /// `nonisolated` so the View renderer + the unit tests can call it
    /// off the MainActor without dragging the store's default isolation
    /// into the call-site ceremony.
    /// **AUD-3 D-2 — profile-TZ fallback.** `timeZone` defaults to `.current`
    /// (tests / pre-settings-hydration) but the `@MainActor`
    /// `cardComplianceSnapshot` fallback threads the SERVER-PROFILE zone
    /// (`profileTimeZone`) through, so the offline recompute buckets days on the
    /// SAME boundary the server (and the online ledger) use. Without this a dose
    /// taken at 23:00 Berlin on a US-located device bucketed on the wrong day, so
    /// the fallback rate / display windows visibly jumped the moment the
    /// authoritative server value landed.
    nonisolated static func complianceSnapshot(
        for medication: Medication,
        windowIntakes: [MedicationIntake],
        now: Date = .now,
        timeZone: TimeZone = .current
    ) -> ComplianceCardSnapshot {
        guard !medication.schedule.entries.isEmpty,
              medication.schedule.entries.contains(where: { !$0.effectiveTimes.isEmpty }) else
        {
            return ComplianceCardSnapshot(rate7: nil, rate30: nil)
        }
        let medicationIntakes = windowIntakes.filter { $0.medicationId == medication.id }
        let rate7 = computeRate(
            medication: medication,
            intakes: medicationIntakes,
            days: 7,
            now: now,
            timeZone: timeZone
        )
        let rate30 = computeRate(
            medication: medication,
            intakes: medicationIntakes,
            days: 30,
            now: now,
            timeZone: timeZone
        )
        // **v0.14.1 #2 — cadence-scaled display windows on the in-memory
        // fallback.** The fallback used to always emit the fixed 7/30 rows, so
        // a weekly med flashed 7/30 for ~200-600 ms before the server's
        // cadence-scaled 30/90 block landed. We now pick the SAME ladder rung
        // the standalone path uses (`MedicationsRepository.complianceDisplay`):
        // walk densest → sparsest, take the first rung where both windows hold
        // ≥ `minStableDoses` expected occurrences. Populating the display block
        // here means `displayRows` reads 30/90 for a weekly med immediately, so
        // there is no flicker when the server value confirms the same windows.
        let chosen = chooseDisplayWindows(medication: medication, now: now, timeZone: timeZone)
        return ComplianceCardSnapshot(
            rate7: rate7,
            rate30: rate30,
            displayShortDays: chosen.short,
            displayShortRate: computeRate(
                medication: medication,
                intakes: medicationIntakes,
                days: chosen.short,
                now: now,
                timeZone: timeZone
            ),
            displayLongDays: chosen.long,
            displayLongRate: computeRate(
                medication: medication,
                intakes: medicationIntakes,
                days: chosen.long,
                now: now,
                timeZone: timeZone
            )
        )
    }

    /// Cadence ladder mirrored from `MedicationsRepository+Standalone`
    /// (`complianceWindowLadder`) so the in-memory fallback and the standalone
    /// path agree dose-for-dose on which two windows the card paints.
    private nonisolated static let displayWindowLadder: [(short: Int, long: Int)] = [
        (7, 30), (30, 90), (90, 365)
    ]

    /// Server-canonical density floor (`MIN_STABLE_DOSES`).
    private nonisolated static let minStableDisplayDoses = 4

    /// Picks the densest ladder rung whose BOTH windows clear the stable-dose
    /// floor; falls back to the widest rung otherwise. Matches the server +
    /// standalone selection so the fallback never flickers a different window
    /// pair than the value that eventually confirms it.
    nonisolated static func chooseDisplayWindows(
        medication: Medication,
        now: Date,
        timeZone: TimeZone = .current
    ) -> (short: Int, long: Int) {
        let context = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: timeZone,
            now: now
        )
        func expected(days: Int) -> Int {
            let periodStart = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
            var total = 0
            for entry in medication.schedule.entries {
                total += MedicationRecurrenceEngine.occurrences(
                    in: periodStart ... now,
                    entry: entry,
                    context: context
                ).count
            }
            return total
        }
        for rung in displayWindowLadder
            where expected(days: rung.short) >= minStableDisplayDoses
            && expected(days: rung.long) >= minStableDisplayDoses
        {
            return rung
        }
        return displayWindowLadder[displayWindowLadder.count - 1]
    }

    /// **v0.10 R1 §3.9 — cadence-correct compliance rate via the engine.**
    ///
    /// The prior version computed `totalExpected = schedulesPerDay ×
    /// effectiveDays`, which over-counts rolling / monthly / yearly meds (they
    /// don't fire daily) — a 30-day rolling med read `totalExpected = 30`
    /// instead of `1`, pinning the rate near 0%. The denominator is now the
    /// engine's actual occurrence count over the window, so the card % is
    /// correct for every cadence (risk 6: the iOS engine denominator wins for
    /// rolling/monthly/yearly until the server's `calculateCompliance` becomes
    /// cadence-canonical — SB-SCHED-2).
    ///
    /// Returns `Int` 0-100 to match the web's `Math.round(taken /
    /// totalExpected × 100)`.
    nonisolated static func computeRate(
        medication: Medication,
        intakes: [MedicationIntake],
        days: Int,
        now: Date,
        timeZone: TimeZone = .current
    ) -> Int {
        guard days > 0 else { return 100 }
        let day: TimeInterval = 24 * 60 * 60
        let periodStart = now.addingTimeInterval(-Double(days) * day)
        // Clamp the window to the medication's known lifespan (web uses
        // createdAt; we use the earliest known intake's scheduledFor as a
        // proxy when it is more recent than the period start) so a fresh med
        // isn't penalised against a full 30-day grid it never had.
        let effectiveStart: Date = if let earliestSeen = intakes.map(\.scheduledAt).min(),
                                      earliestSeen > periodStart
        {
            min(earliestSeen, now)
        } else {
            periodStart
        }

        let context = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: timeZone,
            now: now
        )
        var totalExpected = 0
        for entry in medication.schedule.entries {
            totalExpected += MedicationRecurrenceEngine.occurrences(
                in: effectiveStart ... now,
                entry: entry,
                context: context
            ).count
        }
        guard totalExpected > 0 else { return 100 }

        // A360-5 C-3 — numerator + denominator MUST share the SAME window.
        // The denominator (`totalExpected`) is computed over `effectiveStart …
        // now` (narrowed to a fresh med's first-seen intake). Counting the
        // numerator over the WIDER `periodStart … now` inflated the rate for a
        // med younger than the 7/30-day window (more taken doses than the
        // narrowed denominator could expect → silently capped at 100, diverging
        // from the server ledger which PROJECT_GUIDE.md mandates is authoritative). The
        // numerator now filters on `effectiveStart` too, so the local fallback
        // matches the server-ledger semantics dose-for-dose.
        let takenCount = intakes.lazy
            .filter { $0.scheduledAt >= effectiveStart && $0.scheduledAt <= now }
            .filter { $0.status == .taken && $0.takenAt != nil }
            .count
        let rate = Double(takenCount) / Double(totalExpected) * 100
        return min(100, Int(rate.rounded()))
    }
}

// MARK: - v0.6.1.4 Y4.2 — server-canonical snapshot wiring

@MainActor
public extension MedicationsStore {
    /// Snapshot the card should render for `medication`, or `nil` while the
    /// server-canonical fetch is still pending (caller paints a skeleton).
    ///
    /// **W-COMPLIANCE-INV — server value is the ONLY painted source.** The
    /// pre-fix accessor returned the local-algorithm approximation whenever
    /// the cache was cold, so every app-launch painted a local interim value
    /// for ~200-600 ms and then JUMPED to the server number (operator-reported
    /// 100→60→50 flicker). Now:
    ///   1. cached server value → paint it (also covers the optimistic-mark
    ///      window: the last server value stays painted until the post-mark
    ///      refresh overwrites it — stale-but-stable, no jump),
    ///   2. fetch known-failed (offline / 5xx) → the local algorithm runs as
    ///      the clearly-marked offline fallback,
    ///   3. otherwise (fetch not yet settled) → `nil` → skeleton.
    func cardComplianceSnapshot(
        for medication: Medication,
        windowIntakes: [MedicationIntake]
    ) -> ComplianceCardSnapshot? {
        if let cached = complianceCardSnapshots[medication.id] { return cached }
        guard failedComplianceFetchIDs.contains(medication.id) else { return nil }
        // AUD-3 D-2 — bucket the offline recompute on the SERVER-PROFILE day
        // boundary (not the device TZ), so the fallback agrees with the server
        // ledger and doesn't flicker for TZ-mismatched users.
        return Self.complianceSnapshot(
            for: medication,
            windowIntakes: windowIntakes,
            timeZone: profileTimeZone
        )
    }

    /// Fan-out: refresh the per-medication snapshot for every active
    /// medication in `medications`.
    ///
    /// **v0.14.2 H4 — bounded + deduped.** The fan-out used an UNCAPPED
    /// `withTaskGroup` (a 20-med catalog opened 20 sockets at once) and had no
    /// in-flight dedup (two overlapping runs double-fetched each med). Now:
    /// (1) concurrency is capped at `complianceFanoutConcurrency` (≈4 in flight)
    /// via a sliding-window task group, and (2) each med-id is claimed in
    /// `inFlightComplianceFetchIDs` before its fetch and released after, so the
    /// same med is never fetched twice concurrently. Writes into the
    /// `complianceCardSnapshots` dict still serialise on the MainActor; only the
    /// URL fetches overlap. Failures are swallowed by the inner call so one bad
    /// route does not block the rest.
    func refreshAllCardComplianceSnapshots() async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        await refreshAllCardComplianceSnapshots(sessionLease: sessionLease)
    }

    internal func refreshAllCardComplianceSnapshots(sessionLease: AuthenticatedSessionLease) async {
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        let active = medications.filter(\.active).map(\.id)
        guard !active.isEmpty else { return }
        // Build 6.3 — one batched round trip (`GET /api/medications/compliance`)
        // warms every scheduled card, replacing the per-card N-request fan-out.
        // Only the ids the batch did NOT cover — PRN meds (excluded server-side
        // as they carry no compliance entry), or, on a batch failure (offline /
        // standalone / pre-batch server), all of them — fall through to the
        // bounded per-med fan-out below.
        let covered = await refreshCardComplianceViaBatch(sessionLease: sessionLease)
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        let remaining = active.filter { !covered.contains($0) }
        // Drop ids already being fetched (an overlapping fan-out / single-med
        // refresh). The per-med `refreshCardComplianceSnapshot` owns the actual
        // in-flight claim, so we only PRE-filter here — claiming is NOT done in
        // this method to avoid double-claiming the same id.
        let toFetch = remaining.filter { !inFlightComplianceFetchIDs.contains($0) }
        guard !toFetch.isEmpty else { return }

        let cap = Self.complianceFanoutConcurrency
        var iterator = toFetch.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            // Prime the window with up to `cap` tasks…
            var running = 0
            while running < cap, let medicationID = iterator.next() {
                group.addTask { [weak self] in
                    await self?.refreshCardComplianceSnapshot(for: medicationID, sessionLease: sessionLease)
                }
                running += 1
            }
            // …then add one fresh task each time one finishes, so at most `cap`
            // requests are ever in flight.
            while await group.next() != nil {
                if let medicationID = iterator.next() {
                    group.addTask { [weak self] in
                        await self?.refreshCardComplianceSnapshot(for: medicationID, sessionLease: sessionLease)
                    }
                }
            }
        }
    }

    /// **v0.14.2 H4 — coalesced fan-out for the SWR `.fresh` re-emit.** The
    /// medications SWR stream emits `.cached` then `.fresh` and re-emits
    /// identical rows on every revalidate; firing the full N-request fan-out on
    /// each is pure radio-wake waste because compliance doesn't change just
    /// because the list re-emitted the same rows. This no-ops when the active
    /// med-id set is unchanged from the last fan-out AND that fan-out is inside
    /// the throttle window; a NEW/removed med (post-create / unarchive) changes
    /// the set and forces a refresh through.
    func refreshAllCardComplianceSnapshotsThrottled(now: Date = .now) async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        await refreshAllCardComplianceSnapshotsThrottled(now: now, sessionLease: sessionLease)
    }

    internal func refreshAllCardComplianceSnapshotsThrottled(
        now: Date = .now,
        sessionLease: AuthenticatedSessionLease
    ) async {
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        let active = Set(medications.filter(\.active).map(\.id))
        if active == lastComplianceFanoutIDs,
           let last = lastComplianceFanoutAt,
           now.timeIntervalSince(last) < Self.complianceFanoutThrottle
        {
            return
        }
        lastComplianceFanoutIDs = active
        lastComplianceFanoutAt = now
        await refreshAllCardComplianceSnapshots(sessionLease: sessionLease)
    }
}
