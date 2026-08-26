import Foundation

/// **v0.5.5.1 W-MED2 — client-side intake synthesis for un-emitted server slots.**
///
/// **Operator pain (TestFlight build 21, walkthrough 2026-05-21):**
///
/// > "Ich habe auf dem Server eine Medikation Lisinopril, die ich zweimal nehmen
/// > muss am Tag. Heute hab ich noch keine genommen. Es wird sie mir nicht
/// > angezeigt und ich kann auch keine nehmen."
///
/// **Root cause:** the server's `reminder-worker.ts` only creates a
/// `MedicationIntakeEvent` row when the schedule window enters the **RED**
/// phase (i.e. the user has already missed the window or is in its final
/// minutes). Before that — for the entire window-start → near-window-end
/// span — `GET /api/medications/intake?scope=today` returns `[]` even
/// when the user has an active `twice_daily` Lisinopril schedule. The iOS
/// client treated this `[]` as "nothing planned today" and surfaced
/// every consumer (dashboard tile, upcoming card, Erfassen sheet,
/// quick-mark button) in their empty state. See also
/// `MedicationsRepository+ReminderIntake.swift:12-19` which already
/// documents this asymmetry in the context of notification-action
/// handling — but the asymmetry must equally be respected by the
/// in-app display path, not just push notifications.
///
/// **Fix:** synthesise client-side **placeholder** `MedicationIntake`
/// rows from each active medication's `schedule.times` + `weekdays` +
/// `intervalWeeks` for any slot that:
///
/// 1. Lands on today's calendar day in the user's locale.
/// 2. Has no matching server-emitted intake (de-duplicated by
///    `(medicationId, scheduledAt within ±5 min window)`).
///
/// The placeholder carries a synthetic id (`synth:<medId>|<iso8601>` — see
/// `synthesizedPlaceholderID(medicationId:scheduledAt:)` for the canonical
/// shape) so callers can detect it via ``MedicationIntake/isSynthesizedPlaceholder``
/// and route mark-as-taken through ``MedicationsRepository/recordFromReminder``
/// rather than the regular `POST /api/medications/intake` (which needs a
/// server-known `intakeId`).
///
/// When the user marks a placeholder as taken, the next `MedicationsStore.load()`
/// pulls the newly-created server row in and the placeholder is dropped from
/// the merge (the dedup window covers it). Until then the optimistic patch
/// flips the placeholder's `status` to `.taken` in-place so the UI reflects
/// the action immediately.
public extension MedicationIntake {
    /// Synthetic-id prefix. The id contract is
    /// `synth:<medId>|<scheduledAtIso8601>`. Stable across renders given
    /// the same `(medicationId, scheduledAt)` pair so SwiftUI's
    /// `ForEach(id: \.id)` does not churn placeholder rows between
    /// frames. We deliberately use `|` (pipe) — not another colon — as
    /// the internal separator because ISO-8601 timestamps already
    /// contain colons (`08:26:40Z`), so a colon-separated id cannot
    /// be parsed back unambiguously by splitting on the last colon.
    static let synthesizedPlaceholderPrefix = "synth:"

    /// Internal separator between `medicationId` and the ISO-8601
    /// timestamp inside the placeholder id.
    static let synthesizedPlaceholderSeparator: Character = "|"

    /// `true` when this intake was synthesised client-side from a
    /// medication schedule because the server has not yet emitted the
    /// row. Routes mark-as-taken through the bulk-intake endpoint.
    var isSynthesizedPlaceholder: Bool {
        id.hasPrefix(Self.synthesizedPlaceholderPrefix)
    }

    /// Build a stable synthetic id for a `(medicationId, scheduledAt)`
    /// pair. Uses a non-localised ISO-8601 timestamp so the id survives
    /// locale changes and re-renders.
    static func synthesizedPlaceholderID(
        medicationId: String,
        scheduledAt: Date
    ) -> String {
        synthesizedPlaceholderPrefix
            + medicationId
            + String(synthesizedPlaceholderSeparator)
            + ISO8601DateFormatter.plain.string(from: scheduledAt)
    }
}

/// Pure-function helpers + `MedicationsStore.derivedTodayIntakes` lives in
/// an extension so the parent store stays under the `type_body_length`
/// budget. All consumers — `MedicationsScreen`'s
/// `TodayTimelineSection` + `ActiveMedicationsSection`, the Erfassen-CTA
/// `MedicationQuickIntakeSheet`, and `ComplianceReconciler` — read this
/// computed property instead of `todayIntakes` directly.
public extension MedicationsStore {
    /// Today's intakes the UI should render — server-emitted rows unioned
    /// with synthesised placeholders for schedule slots the server has
    /// not yet created. Idempotent given the underlying arrays; computed
    /// each access (the inputs are small — typically < 20 medications +
    /// < 10 server intakes — so re-computation on every render is
    /// cheaper than maintaining a cached mirror).
    ///
    /// **audit-v0162 M-7 — the "fallback" scope, made honest, gated AND wired.**
    /// Synthesis is documented (PROJECT_GUIDE.md) as a "fallback ONLY for server ≤
    /// v1.15.17", but this live due-surface path synthesised UNCONDITIONALLY on
    /// every server — the inverted doc. On a modern slot-materialising server the
    /// ±5-min dedup can't catch a slot whose server `scheduledFor` diverges (a
    /// schedule-era edit / DST edge / profile-TZ seam), so the synth placeholder
    /// lands ALONGSIDE the real row: an inflated "N open", a phantom overdue ring
    /// dose, and an inflated app badge (`+BadgeCount` counts this).
    ///
    /// The synthesis is gated on `derivedIntakeSynthesisEnabledProvider`, and
    /// the composition root now WIRES that provider (it shipped as `= { true }`
    /// with an "until wired" note and stayed unconnected): it reads the
    /// persisted `MedicationSlotMaterializationGate` verdict from
    /// `GET /api/version`, OR'd with standalone mode. On a server ≥
    /// ``MedicationSlotMaterialization/minimumServerVersion`` the gate is off
    /// and this trusts the server rows verbatim — no double-count.
    ///
    /// **Optimistic rows survive a mid-session flip.** The gate-off branch
    /// filters `todayIntakes` by today's window only — it does NOT strip
    /// `synth:`-prefixed ids. That is deliberate: a synth-id row inside
    /// `todayIntakes` is not a projection, it is the operator's own
    /// optimistically-patched (possibly outbox-queued) mark
    /// (`markSynthesizedPlaceholderWithOutcome` appends it there). Dropping it
    /// when the gate flips would visibly un-take a dose the user just logged.
    /// It is reconciled the same way it always was: `invalidateAfterSynthMark`
    /// invalidates the today-intakes key and the next observe replaces the array
    /// with the server's rows, at which point the shadow is gone.
    ///
    /// `MainActor`-isolated (inherited from `MedicationsStore`) — both
    /// `todayIntakes` and `medications` are main-actor state. Pure-helper
    /// `deriveTodayIntakes(_:medications:now:calendar:)` is the
    /// `nonisolated` test seam.
    var derivedTodayIntakes: [MedicationIntake] {
        // v0.14 DATA — anchor today's window + the engine context on the
        // server-profile IANA timezone (NOT device `.current`) so a dose due
        // "now" stays inside `[startOfToday, endOfToday)` even when the device
        // TZ differs from the profile zone. `profileTimeZone` defaults to
        // `.current`, so until the composition root sets it the behaviour is
        // byte-unchanged.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = profileTimeZone
        // audit-v0162 M-7 — on a slot-materialising server, skip synthesis and
        // trust the server's today rows verbatim (no double-count hazard).
        guard derivedIntakeSynthesisEnabledProvider() else {
            let startOfToday = calendar.startOfDay(for: .now)
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
            return todayIntakes
                .filter { $0.scheduledAt >= startOfToday && $0.scheduledAt < endOfToday }
                .sorted { $0.scheduledAt < $1.scheduledAt }
        }
        return MedicationsStore.deriveTodayIntakes(
            serverIntakes: todayIntakes,
            medications: medications,
            now: .now,
            calendar: calendar
        )
    }

    /// Pure-function seam used by `derivedTodayIntakes` + the regression
    /// test suite. Deterministic given `(serverIntakes, medications, now,
    /// calendar)`.
    ///
    /// **Merge rules:**
    ///
    /// 1. All server-emitted intakes whose `scheduledAt` lands on today
    ///    are kept as-is (server is authoritative for any slot it has
    ///    materialised).
    /// 2. For each active medication, expand `schedule.times` against
    ///    today's date. Skip a slot if:
    ///    - the medication is `active == false`,
    ///    - the medication's `schedule.weekdays` excludes today's
    ///      weekday,
    ///    - the medication's `schedule.intervalWeeks` skips this week
    ///      (computed against an ISO-8601 epoch anchor so the same
    ///      `i2;` recurrence lands consistently across runs),
    ///    - a server intake for the same `(medicationId, scheduledAt
    ///      ±5 min)` already exists (dedup window).
    /// 3. Synthesised placeholders are sorted by `scheduledAt` and
    ///    appended to the server-emitted set; the final array is then
    ///    sorted by `scheduledAt` ascending (so the dashboard +
    ///    Erfassen-sheet render in chronological order regardless of
    ///    server vs synth origin).
    ///
    /// Sorted-stable: equal timestamps preserve the input order
    /// (server-first then synth).
    nonisolated static func deriveTodayIntakes(
        serverIntakes: [MedicationIntake],
        medications: [Medication],
        now: Date,
        calendar: Calendar
    ) -> [MedicationIntake] {
        let startOfToday = calendar.startOfDay(for: now)
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            return serverIntakes
        }

        // Step 1 — server-emitted today's intakes, preserved.
        let serverToday = serverIntakes.filter { intake in
            intake.scheduledAt >= startOfToday && intake.scheduledAt < endOfToday
        }

        // Step 2 — synthesise placeholders for schedule slots that the
        // server has not yet materialised. The `dedupWindow` matches
        // the reminder-worker's `localHmAsUtc` precision (whole-minute);
        // ±5 min absorbs DST + clock-skew without producing duplicates.
        //
        // **v0.10 R1 §3.3 — routed through `MedicationRecurrenceEngine`.**
        // Previously this iterated `schedule.times` and gated on a
        // weekday-only `medicationFiresToday`, which treated rolling /
        // monthly / yearly meds (whose `daysOfWeek` is null) as DAILY and
        // synthesised a placeholder EVERY day — the core "fires daily" bug.
        // The engine now produces exactly the slots the server would: a
        // rolling med surfaces only its single next-due slot (and only if it
        // lands today or is overdue), monthly/yearly don't fire on
        // non-matching days, and a one-shot stops once taken.
        let dedupWindow: TimeInterval = 5 * 60
        let timeZone = calendar.timeZone

        var synthesised: [MedicationIntake] = []
        for medication in medications where medication.active {
            let context = MedicationRecurrenceEngine.Context(
                medication: medication,
                timeZone: timeZone,
                now: now
            )

            // **B2 (v0.10.0 Walkthrough-1) — dedup dose instants per med.**
            // A medication can carry multiple `schedule.entries` that resolve to
            // the SAME clock time (e.g. a twice-daily med modelled as two entries
            // each carrying both `effectiveTimes` → 2×2 = 4 raw occurrences).
            // Collapsing the synthesised instants into a whole-minute-keyed map
            // BEFORE materialising placeholders means two entries firing at the
            // same `HH:mm` produce one slot, so the compliance-ring denominator
            // reflects DISTINCT doses (2), not `Σ(entries)×Σ(times)` (4).
            //
            // Keyed by the whole-minute floor of the instant; the first instant
            // seen for a minute wins (its seconds/ms are preserved for display
            // but duplicates within the same minute collapse).
            var instantByMinute: [Date: Date] = [:]
            for entry in medication.schedule.entries {
                let scheduledInstants = synthesisableInstants(
                    entry: entry,
                    context: context,
                    startOfToday: startOfToday,
                    endOfToday: endOfToday,
                    now: now
                )
                for scheduledAt in scheduledInstants {
                    let minuteKey = wholeMinute(scheduledAt)
                    if instantByMinute[minuteKey] == nil {
                        instantByMinute[minuteKey] = scheduledAt
                    }
                }
            }

            for scheduledAt in instantByMinute.values {
                let alreadyHasServerRow = serverToday.contains { server in
                    server.medicationId == medication.id
                        && abs(server.scheduledAt.timeIntervalSince(scheduledAt)) <= dedupWindow
                }
                guard !alreadyHasServerRow else { continue }

                synthesised.append(MedicationIntake(
                    id: MedicationIntake.synthesizedPlaceholderID(
                        medicationId: medication.id,
                        scheduledAt: scheduledAt
                    ),
                    medicationId: medication.id,
                    scheduledAt: scheduledAt,
                    takenAt: nil,
                    status: .pending,
                    snoozedUntil: nil
                ))
            }
        }

        // Step 3 — merge + stable sort. Pre-sort each input by
        // `scheduledAt` so the merged output is deterministic; the
        // dashboard + Erfassen sheet rely on chronological ordering for
        // their "earliest first" UX.
        let merged = serverToday + synthesised
        return merged.sorted { lhs, rhs in
            if lhs.scheduledAt != rhs.scheduledAt {
                return lhs.scheduledAt < rhs.scheduledAt
            }
            // Stable tie-break: server rows before placeholders so the
            // operator's earliest-actioned dose surfaces first.
            return !lhs.isSynthesizedPlaceholder && rhs.isSynthesizedPlaceholder
        }
    }

    // MARK: - Synth-placeholder id parsing

    /// Decode the `synth:<medId>|<isoDate>` id back into its component
    /// parts. The `|` separator is unambiguous because Prisma cuids
    /// don't contain pipes and ISO-8601 timestamps don't either —
    /// splitting on it is safe regardless of medication-id shape.
    /// Public so `MedicationsStore`'s in-body mark methods can route
    /// synth ids through `recordFromReminder` without re-implementing
    /// the id contract.
    nonisolated static func parseSynthesizedPlaceholderID(
        _ id: String
    ) -> (medicationId: String, scheduledAt: Date)? {
        let prefix = MedicationIntake.synthesizedPlaceholderPrefix
        guard id.hasPrefix(prefix) else { return nil }
        let body = id.dropFirst(prefix.count)
        guard let separator = body.firstIndex(of: MedicationIntake.synthesizedPlaceholderSeparator) else {
            return nil
        }
        let medicationId = String(body[..<separator])
        let isoString = String(body[body.index(after: separator)...])
        guard !medicationId.isEmpty,
              let scheduledAt = ISO8601DateFormatter.plain.date(from: isoString) else
        {
            return nil
        }
        return (medicationId, scheduledAt)
    }

    // MARK: - Helpers

    /// Whole-minute floor of an instant, used as the per-medication dedup key so
    /// two schedule entries that resolve to the same `HH:mm` collapse to one dose
    /// slot (B2). Truncates sub-minute precision via `timeIntervalSinceReferenceDate`
    /// rounding — locale/timezone-independent because it operates on the absolute
    /// instant, and two instants within the same wall-clock minute share a key.
    private nonisolated static func wholeMinute(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60)
    }

    /// Resolve the scheduled instants a single `ScheduleEntry` should
    /// synthesise placeholders for today.
    ///
    /// - **Calendar cadences** (daily / weekdays / everyNWeeks / monthly /
    ///   everyNMonths / yearly / legacy) — every occurrence that lands inside
    ///   today's `[startOfToday, endOfToday)` window. This is the unbounded
    ///   forward grid the server predicts, so monthly/yearly meds emit nothing
    ///   on non-matching days (the bug fix).
    /// - **Rolling / one-shot** — the single next-due slot, surfaced only when
    ///   it lands today OR is overdue (its instant is ≤ now). An overdue
    ///   rolling dose stays "still due" (one slot, not a backlog) so the
    ///   operator can log it; a future-dated rolling slot beyond today is not
    ///   surfaced as a today-placeholder.
    private nonisolated static func synthesisableInstants(
        entry: ScheduleEntry,
        context: MedicationRecurrenceEngine.Context,
        startOfToday: Date,
        endOfToday: Date,
        now: Date
    ) -> [Date] {
        switch entry.cadence {
        case .asNeeded:
            // PRN / as-needed — never synthesises a placeholder slot; intakes
            // are logged ad-hoc by the operator, not projected.
            return []

        case .rolling, .oneShot:
            // v0.10.0 W10 M4 — prefer the server `nextDueAt` when present so the
            // in-app today-placeholder agrees with the reminder slot
            // (`MedicationRecurrenceEngine.nextOccurrence` already prefers
            // `serverNextDueAt` for single-slot cadences). Without this, the
            // reminder fired at the server instant while the placeholder was
            // derived from the local `lastIntakeAt + N` projection — a felt
            // divergence. Fall back to the local engine projection when the
            // server omitted it (current server / PRN).
            let candidateInstants: [Date] = if let serverNext = context.serverNextDueAt {
                [serverNext]
            } else {
                // Local projection: from the start of time so an overdue slot
                // (next-due in the past) is still returned; the engine emits at
                // most one rolling slot.
                MedicationRecurrenceEngine.occurrences(
                    in: Date.distantPast ... endOfToday.addingTimeInterval(-1),
                    entry: entry,
                    context: context
                ).map(\.at)
            }
            return candidateInstants
                // Surface when due today, or overdue (≤ now). A future slot
                // beyond today is left to the next day's derive pass.
                .filter { $0 < endOfToday && ($0 >= startOfToday || $0 <= now) }

        case .daily, .weekdays, .everyNWeeks, .monthly, .everyNMonths,
             .yearly, .legacy, .cyclic:
            // Cyclic on/off-weeks is a calendar cadence: the engine emits a
            // today-slot only when today falls in an on-week (off-weeks silent).
            return MedicationRecurrenceEngine.occurrences(
                in: startOfToday ... endOfToday.addingTimeInterval(-1),
                entry: entry,
                context: context
            ).map(\.at)
        }
    }
}
