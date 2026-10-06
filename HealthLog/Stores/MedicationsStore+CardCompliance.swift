import Foundation

/// **v0.6.1.2 Y4 / v0.6.1.4 Y4.2 — per-medication 7- and 30-day compliance.**
///
/// The card stack consumes `cardComplianceSnapshot(for:)`, which paints the
/// server value from `GET /api/medications/compliance` (batched) or
/// `GET /api/medications/[id]/compliance` (per medication) and nothing else.
///
/// **#115 B7 — no device-computed rate any more.** Until B7 a failed fetch
/// (offline, 5xx) unlocked a local port of the web's `calculateCompliance`
/// that divided the intakes this device happened to hold by an engine
/// occurrence count. Its window approximated `createdAt` by the earliest
/// intake seen, so the number it printed was an estimate dressed as the
/// server's figure. A failed fetch now reads "adherence unknown"
/// (`ComplianceCardSnapshot.unavailable`); the only local fact left is
/// whether the medication has a schedule at all (a PRN card says "as needed").
/// Standalone mode is unaffected: its repository answers the compliance
/// routes itself, so the fetch does not fail there.
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
        /// #115 · 1.3 — the server's `applicable`. `false` (NO_LOCAL_SCHEDULE)
        /// means the rates are all-zero compatibility placeholders; no row is
        /// painted and no aggregate counts them.
        public let applicable: Bool
        /// v1.39.1 — the server's `notApplicableReason`, when it sent one.
        /// `.intakeNotTracked` makes the card say "not tracked" instead of
        /// painting an empty slot.
        public let notApplicableReason: ComplianceNotApplicableReason?
        /// #115 B7 — the server was asked and did not answer (offline, 5xx),
        /// and no earlier answer is cached. The card says "unknown" instead of
        /// painting a number the device worked out itself.
        public let serverUnavailable: Bool

        /// A scheduled medication whose adherence the server could not give.
        public static let unavailable = ComplianceCardSnapshot(rate7: nil, rate30: nil, serverUnavailable: true)

        public init(
            rate7: Int?,
            rate30: Int?,
            displayShortDays: Int? = nil,
            displayShortRate: Int? = nil,
            displayLongDays: Int? = nil,
            displayLongRate: Int? = nil,
            applicable: Bool = true,
            notApplicableReason: ComplianceNotApplicableReason? = nil,
            serverUnavailable: Bool = false
        ) {
            self.rate7 = rate7
            self.rate30 = rate30
            self.displayShortDays = displayShortDays
            self.displayShortRate = displayShortRate
            self.displayLongDays = displayLongDays
            self.displayLongRate = displayLongRate
            self.applicable = applicable
            self.notApplicableReason = notApplicableReason
            self.serverUnavailable = serverUnavailable
        }

        /// The two `(days, rate)` rows the card paints. Prefers the server
        /// cadence-scaled `complianceDisplay` windows; falls back to the fixed
        /// 7/30 windows (pre-2026-06-01 server). Empty for a PRN medication
        /// and for ``serverUnavailable``.
        public var displayRows: [(days: Int, rate: Int)] {
            guard applicable, !serverUnavailable else { return [] }
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

    /// **#115 B7 — what the card shows when the server gave no answer.**
    ///
    /// A medication without a schedule (PRN / on demand) has no adherence at
    /// all — that is a fact of the medication, not a computed value, so its
    /// card keeps the "as needed" note. Every scheduled medication reads
    /// ``ComplianceCardSnapshot/unavailable``: the device does not compute a
    /// rate of its own.
    nonisolated static func offlineSnapshot(for medication: Medication) -> ComplianceCardSnapshot {
        let hasSchedule = medication.schedule.entries.contains { !$0.effectiveTimes.isEmpty }
        return hasSchedule ? .unavailable : ComplianceCardSnapshot(rate7: nil, rate30: nil)
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
    ///   2. fetch known-failed (offline / 5xx) → "unknown" for a scheduled
    ///      medication, "as needed" for a PRN one — never a device-computed
    ///      rate (#115 B7, ``offlineSnapshot(for:)``),
    ///   3. otherwise (fetch not yet settled) → `nil` → skeleton.
    func cardComplianceSnapshot(for medication: Medication) -> ComplianceCardSnapshot? {
        if let cached = complianceCardSnapshots[medication.id] { return cached }
        guard failedComplianceFetchIDs.contains(medication.id) else { return nil }
        return Self.offlineSnapshot(for: medication)
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
        // v1.39.1 (#1033) — a medication kept as a record has no adherence to
        // fetch; its card says "not tracked" without a request.
        let active = medications.filter { $0.active && $0.tracksIntake }.map(\.id)
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
        let active = Set(medications.filter { $0.active && $0.tracksIntake }.map(\.id))
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
