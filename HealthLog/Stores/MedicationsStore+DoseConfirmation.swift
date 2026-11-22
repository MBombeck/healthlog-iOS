import Foundation

/// **1.7 — what the screens may say about today's doses on opening.**
///
/// The first frame after a cold start, a return from the background or a tab
/// switch used to paint today's doses from whatever the store held: the SWR
/// row on disk or the state in memory, hours old. A dose taken on the web, the
/// pill box or Telegram meanwhile stood there as due, with its Take button,
/// until the reload landed, and longer when it did not.
///
/// `asOf` is the instant the shown dose state last matched the server: a fresh
/// answer, or the write time of the cached row. Within
/// ``MedicationsStore/doseConfirmationWindow`` it counts as current. Older, the
/// store raises `isPending`, the surfaces show the dose neutrally (its time, no
/// due or overdue accent, no live Take button), and the reload runs. The hold
/// ends with the server's answer, with the end of the reload (offline, failed)
/// or after ``MedicationsStore/doseConfirmationHoldCap`` at the latest, so an
/// offline phone still offers its doses.
public struct DoseStateConfirmation: Equatable, Sendable {
    /// When the dose state in the store last matched the server.
    public internal(set) var asOf: Date?
    /// The shown dose state is not confirmed yet and the reload is running.
    public internal(set) var isPending = false
    /// When the current hold began (for the log line that measures it).
    var pendingSince: Date?
    /// Raised while a hold kept `onIntakesDidChange` back.
    var heldEffects = false
    /// Bumped per hold, so a cap timer of an earlier hold ends nothing.
    var holdGeneration: UInt64 = 0

    public init() {}

    /// Pure: is a dose state from `asOf` current at `now`?
    public static func isCurrent(asOf: Date?, now: Date, window: TimeInterval) -> Bool {
        guard let asOf else { return false }
        return now.timeIntervalSince(asOf) <= window && asOf <= now.addingTimeInterval(window)
    }
}

extension MedicationsStore {
    /// How old a dose state may be and still be shown as it is.
    nonisolated static let doseConfirmationWindow: TimeInterval = 120
    /// The longest the surfaces wait for the reload before they show the
    /// state they have (offline, a hanging request).
    nonisolated static let doseConfirmationHoldCap: TimeInterval = 8

    /// `true` while the surfaces show today's open doses neutrally.
    public var isDoseStateUnconfirmed: Bool {
        doseConfirmation.isPending
    }

    // MARK: Entry points

    /// **Foreground, tab switch, scene activation.** Re-reads the App Group
    /// ledger the notification extension fills, folds it into the state on
    /// screen, and, when that state is older than the window, holds the open
    /// doses neutral and starts the reload. Synchronous up to the reload, so
    /// the next frame is already neutral.
    public func refreshDoseStateIfStale(now: Date = .now) {
        guard captureAuthenticatedSessionLease() != nil else { return }
        foldResolvedDoseLedger()
        guard hasDoseStateToConfirm,
              !DoseStateConfirmation.isCurrent(asOf: doseConfirmation.asOf, now: now, window: Self.doseConfirmationWindow) else { return }
        beginDoseHold(now: now)
        if startForegroundRevalidation(now: now) == nil {
            // Inside the throttle a reload has just answered; nothing to wait for.
            settleDoseHold(reason: "throttled")
        }
    }

    /// Whether there is anything a hold would hide.
    var hasDoseStateToConfirm: Bool {
        !todayIntakes.isEmpty || !medications.isEmpty
    }

    // MARK: The load's view of it

    /// `load` begins: nothing is known in this process yet, so the first
    /// cached rows are held until they prove current.
    func beginDoseHoldIfUnknown(now: Date = .now) {
        guard doseConfirmation.asOf == nil, !doseConfirmation.isPending else { return }
        beginDoseHold(now: now)
    }

    /// Whether a cached today row may replace what the store shows. A row
    /// older than the state in memory never does: the disk write of the last
    /// answer may still be pending, and the older row would paint a dose open
    /// that the server already closed.
    func acceptsCachedTodayIntakes(cachedAt: Date) -> Bool {
        guard let asOf = doseConfirmation.asOf else { return true }
        return cachedAt >= asOf
    }

    /// A cached today row was applied. Returns whether the surfaces may act on
    /// it right away (it is current); otherwise the hold stays up.
    @discardableResult
    func noteCachedTodayIntakes(cachedAt: Date, now: Date = .now) -> Bool {
        doseConfirmation.asOf = max(doseConfirmation.asOf ?? cachedAt, cachedAt)
        if DoseStateConfirmation.isCurrent(asOf: doseConfirmation.asOf, now: now, window: Self.doseConfirmationWindow) {
            if doseConfirmation.isPending { settleDoseHold(reason: "cache-current") }
            return true
        }
        beginDoseHold(now: now)
        return false
    }

    /// The server answered today's intakes.
    func noteFreshTodayIntakes(now: Date = .now) {
        doseConfirmation.asOf = now
        doseConfirmation.heldEffects = false
        // R1 #2: the answer supersedes every ledger entry recorded before the
        // request left; a take deleted on the web is open again for the
        // widget, Siri and the banners too.
        resolvedDoseLedger.prune(recordedBefore: Self.ledgerCutoff(freshAt: now))
        if doseConfirmation.isPending { settleDoseHold(reason: "fresh", now: now) }
    }

    /// How long before a fresh answer a ledger entry may have been written
    /// without the answer knowing it yet (the request's flight).
    nonisolated static let ledgerFlightMargin: TimeInterval = 15

    /// The instant a fresh answer at `freshAt` speaks for.
    nonisolated static func ledgerCutoff(freshAt: Date) -> Date {
        freshAt.addingTimeInterval(-ledgerFlightMargin)
    }

    /// The today stream ended without a fresh answer it could use (offline,
    /// failed). The surfaces show what the store has.
    func noteTodayIntakesStreamEnded() {
        guard doseConfirmation.isPending, !Task.isCancelled else { return }
        settleDoseHold(reason: "stream-ended")
    }

    /// Applies a today payload: the generation guard, the resolved doses of the
    /// App Group ledger recorded after `asOf`, and `onIntakesDidChange` unless
    /// a hold keeps it back. Returns `true` when applied.
    @discardableResult
    func applyTodayIntakes(
        _ value: [MedicationIntake],
        loadGeneration: UInt64,
        asOf: Date?,
        notify: Bool
    ) -> Bool {
        guard mutationGeneration == loadGeneration else { return false }
        todayIntakes = Self.foldingResolvedDoses(resolvedDoseLedger.read(), into: value, asOf: asOf)
        if notify {
            onIntakesDidChange?()
        } else {
            doseConfirmation.heldEffects = true
        }
        return true
    }

    /// Logout: the next account starts unknown.
    func resetDoseConfirmation() {
        contract.doseHold?.cancel()
        contract.doseHold = nil
        doseConfirmation = DoseStateConfirmation()
    }

    // MARK: Hold

    func settleDoseHold(reason: StaticString, now: Date = .now) {
        contract.doseHold?.cancel()
        contract.doseHold = nil
        let since = doseConfirmation.pendingSince
        doseConfirmation.isPending = false
        doseConfirmation.pendingSince = nil
        if let since {
            let elapsed = Int((now.timeIntervalSince(since) * 1000).rounded())
            // A duration and a fixed reason word, no account data.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.cache.notice("dose-state settled reason=\(reason, privacy: .public) ms=\(elapsed, privacy: .public)")
        }
        if doseConfirmation.heldEffects {
            doseConfirmation.heldEffects = false
            onIntakesDidChange?()
        }
    }

    // MARK: Ledger

    /// Folds the App Group ledger into the state on screen, against the
    /// instant that state matched the server.
    func foldResolvedDoseLedger() {
        let folded = Self.foldingResolvedDoses(resolvedDoseLedger.read(), into: todayIntakes, asOf: doseConfirmation.asOf)
        if folded != todayIntakes { todayIntakes = folded }
    }

    /// **Pure: a dose resolved elsewhere, applied to today's rows.** An open
    /// row (pending, snoozed, missed) of the same medication whose slot lies
    /// within ``ResolvedReminderPlan/driftTolerance`` of a ledger entry, or
    /// whose id the entry names, becomes taken or skipped, but only when the
    /// entry was recorded after `asOf`: a server answer newer than the push
    /// already says what is true, an undo included. Without `asOf` every entry
    /// counts.
    nonisolated static func foldingResolvedDoses(
        _ ledger: [ResolvedDose],
        into intakes: [MedicationIntake],
        asOf: Date?
    ) -> [MedicationIntake] {
        let entries = ledger.filter { dose in asOf.map { dose.recordedAt > $0 } ?? true }
        guard !entries.isEmpty else { return intakes }
        return intakes.map { intake in
            guard intake.status == .pending || intake.status == .snoozed || intake.status == .missed else { return intake }
            let slot = intake.doseState?.slotInstant ?? intake.scheduledAt
            guard let dose = entries.last(where: { dose in
                dose.medicationId == intake.medicationId
                    && (dose.intakeId == intake.id
                        || abs(dose.slotAt.timeIntervalSince(slot)) <= ResolvedReminderPlan.driftTolerance)
            }) else { return intake }
            return resolved(intake, by: dose)
        }
    }

    private nonisolated static func resolved(_ intake: MedicationIntake, by dose: ResolvedDose) -> MedicationIntake {
        let state = dose.wasTaken ? "taken" : "skipped"
        return MedicationIntake(
            id: intake.id,
            medicationId: intake.medicationId,
            scheduledAt: intake.scheduledAt,
            takenAt: dose.wasTaken ? (dose.takenAt ?? dose.recordedAt) : nil,
            status: dose.wasTaken ? .taken : .skipped,
            takenVia: dose.wasTaken ? dose.source : nil,
            syncVersion: intake.syncVersion,
            idempotencyKey: intake.idempotencyKey,
            doseState: intake.doseState.map {
                ServerDoseState(state: state, dueAt: $0.dueAt, slotInstant: $0.slotInstant, missedAfter: $0.missedAfter)
            }
        )
    }

    // MARK: Background
}

extension MedicationsStore {
    /// `/api/sync/state` named the stamp of the loaded data: it is current.
    func noteDoseStateConfirmedBySync(now: Date = .now) {
        guard captureAuthenticatedSessionLease() != nil else { return }
        doseConfirmation.asOf = now
        if doseConfirmation.isPending { settleDoseHold(reason: "sync-state", now: now) }
    }
}

extension MedicationsStore {
    /// **1.7 (R1 #8)** — the row of a slot the server reported as already
    /// taken: taken, with the server's `takenAt` and `takenVia`.
    nonisolated static func alreadyTakenRow(_ original: MedicationIntake, _ already: MedicationAlreadyTaken) -> MedicationIntake {
        MedicationIntake(
            id: original.id,
            medicationId: original.medicationId,
            scheduledAt: original.scheduledAt,
            takenAt: already.takenAt ?? original.takenAt,
            status: .taken,
            takenVia: already.source,
            syncVersion: original.syncVersion,
            idempotencyKey: original.idempotencyKey,
            doseState: original.doseState.map {
                ServerDoseState(state: "taken", dueAt: $0.dueAt, slotInstant: $0.slotInstant, missedAfter: $0.missedAfter)
            }
        )
    }
}
