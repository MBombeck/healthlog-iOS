// Compliance KPI + Verlauf-glyph track split out of MedicationDetailStore.swift (pure move, W-FILELEN).
import Foundation

public extension MedicationDetailStore {
    // MARK: - v0.6.1.2 Y4 — compliance KPI + Verlauf glyph track

    /// **#115 · 1.3 — the KPI is the server's 30-day adherence, verbatim.**
    ///
    /// Until 1.0.3 the detail KPI tallied "on time" slots on the client (from
    /// the dose-history ledger, else the drained intake table with a ±30 min
    /// rule, else a cadence-capped server window) and ranked that tally ABOVE
    /// the server's `compliance30`. Two numbers for one medication on adjacent
    /// screens, one of them computed here. Now the tile paints
    /// `GET /api/medications/{id}/compliance` → `compliance30` as sent: `rate`,
    /// `taken`, and `taken + missed` as the denominator the rate uses (skips
    /// are excluded server-side).
    struct ServerAdherence: Sendable, Equatable {
        /// The server's rounded 0…100 rate.
        public let rate: Int
        public let taken: Int
        /// `taken + missed` — the rate's denominator.
        public let expected: Int

        public init(rate: Int, taken: Int, expected: Int) {
            self.rate = rate
            self.taken = taken
            self.expected = expected
        }

        public init(window: ComplianceWindowResult) {
            self.init(rate: window.rate, taken: window.taken, expected: window.taken + window.missed)
        }
    }

    /// Per-day glyph for the Verlauf track. Maps to a single SF Symbol
    /// in `MedicationDetailSections.VerlaufGlyphTrack`.
    enum VerlaufGlyph: Sendable, Equatable {
        /// All scheduled doses for the day were taken within ±30 min
        /// of their window. Renders as `circle.fill`.
        case onTime
        /// At least one dose was taken, but at least one fell outside
        /// the ±30 min window (still compliant, just delayed).
        /// Renders as `circle.dashed`.
        case late
        /// All past-due doses for the day are missed (no taken, no
        /// skipped). Renders as `circle` (outlined).
        case missed
        /// The day had no scheduled doses at all (interval-weekly
        /// medication's off-day). Renders as a muted dash.
        case noSchedule
    }

    /// **KPI paint state.** Exactly one of: a placeholder while the first
    /// load runs (`.pending`), the server's number (`.server`), the server's
    /// statement that no adherence applies (`.notApplicable`,
    /// `applicable: false` / `NO_LOCAL_SCHEDULE` — its zero placeholders are
    /// never painted as 0 %), or "unknown" when the load settled without a
    /// server payload (`.unavailable`: offline, standalone). No client-derived
    /// number paints in any state.
    enum ComplianceKPIState: Sendable, Equatable {
        case pending
        case server(ServerAdherence)
        case notApplicable
        /// v1.39.1 (#1033) — intake tracking is off (`trackIntake: false`,
        /// `notApplicableReason: INTAKE_NOT_TRACKED`): the medication is a
        /// record and has no adherence at all.
        case notTracked
        case unavailable
    }

    /// Resolve the KPI paint state for the detail screen.
    func complianceKPIState() -> ComplianceKPIState {
        // A medication kept as a record has no adherence whatever the payload
        // holds; the server answers `INTAKE_NOT_TRACKED` for it, and a stale
        // payload from before the switch must not paint its old rate.
        if !medication.tracksIntake { return .notTracked }
        if let payload = compliance {
            if payload.isApplicable { return .server(ServerAdherence(window: payload.compliance30)) }
            return payload.notApplicableReason == .intakeNotTracked ? .notTracked : .notApplicable
        }
        return hasSettledComplianceLoad ? .unavailable : .pending
    }

    /// Per-day glyph track for the Verlauf section. Builds one
    /// `VerlaufGlyph` per day from `now - (days-1)` to `now` inclusive,
    /// oldest-first.
    ///
    /// **W45 (v0.11) — intake-authoritative, matching the table.** The same
    /// `intakes` set that the intake TABLE renders is the source of truth for
    /// the glyph track: `glyph(forDay:)` reduces each day's loaded events into
    /// a glyph exactly as the table-row status would read. `load()` drains the
    /// full intake history, so the track covers the same dozens of slots the
    /// table shows instead of only the server's clamped 30/90-day window. This
    /// is what fixes "the glyph graph shows only a few intakes while the table
    /// shows several dozen".
    ///
    /// The server `dailyCompliance` payload is consulted ONLY as a cadence
    /// overlay: when it is v1.7.0-capable (per-day `due`/`expectedCount`) and a
    /// day has NO loaded intakes, a server `due == false` bucket suppresses the
    /// day to `.noSchedule` so an off-week / non-matching-weekday day doesn't
    /// read as a false miss. A day that DOES have loaded intakes is always
    /// rendered from those intakes — the table's truth wins.
    func verlaufGlyphs(days: Int = 14, now: Date = .now, calendar: Calendar? = nil) -> [VerlaufGlyph] {
        // W-TZ-MED — default to the profile-zone calendar so a traveling user
        // buckets each dose on the profile day (matching the card/dashboard/
        // ledger). Explicit `calendar` (tests) overrides; nil profile zone →
        // `.current` device-TZ fallback inside the provider.
        let calendar = calendar ?? profileCalendar
        // W3-MEDCONTRACT — ledger-first (same rationale as
        // `complianceSummary`): the server ledger already minted each day
        // against the schedule that was live THEN, so the glyph track stays
        // truthful across schedule edits. Fallback below for ≤ v1.15.17.
        if let ledger = doseHistory {
            return ledgerGlyphs(ledger, days: days, now: now, calendar: calendar)
        }
        let today = calendar.startOfDay(for: now)
        // v1.7.0-capable server payload → per-day `due` overlay for empty days.
        //
        // Audit B-6 — ONE zone forms the key: the profile zone the caller's
        // calendar carries. The UTC fallback that used to sit behind this
        // lookup answered a profile day with its NEIGHBOUR's bucket for every
        // user east of UTC — the UTC rendering of a profile-day midnight is the
        // previous calendar date. The server buckets `dailyCompliance` by the
        // profile zone (`compliance-payload.ts`), so a key that misses means the
        // server minted no verdict for that day, and the local schedule — not a
        // neighbouring day's `due` flag — decides what the glyph shows.
        let dueOverlay: (Date) -> Bool? = { [self] dayStart in
            guard let payload = compliance, payload.isV170Capable else { return nil }
            let formatter = Self.dailyComplianceKeyFormatter(for: calendar.timeZone)
            return payload.dailyCompliance[formatter.string(from: dayStart)]?.wasDue
        }
        return (0 ..< days).reversed().map { offset -> VerlaufGlyph in
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: today),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else
            {
                return .noSchedule
            }
            if dayStart > now {
                return .noSchedule
            }
            let dayEvents = intakes.filter { event in
                event.scheduledFor >= dayStart && event.scheduledFor < dayEnd
            }
            if dayEvents.isEmpty {
                // No intake loaded for this day. Suppress to `.noSchedule` when
                // the cadence says the day wasn't due — prefer the server's
                // canonical `due` flag, fall back to the local schedule when the
                // server payload is absent / not capable.
                if let serverDue = dueOverlay(dayStart) {
                    return serverDue ? .missed : .noSchedule
                }
                return medication.schedule.fires(on: dayStart, calendar: calendar)
                    ? glyph(forDay: dayEvents, now: now)
                    : .noSchedule
            }
            return glyph(forDay: dayEvents, now: now)
        }
    }

    /// W3-MEDCONTRACT — per-day glyph reduction over the server ledger.
    ///
    /// One `VerlaufGlyph` per day from `now − (days−1)` to `now`,
    /// oldest-first (same shape as the legacy path). A day reduces over its
    /// slot rows: any `missed` → `.missed`; else any `taken_late` →
    /// `.late`; else any take (`taken_on_time`, or an ad-hoc take logged
    /// that day — the server heatmap counts those green) → `.onTime`;
    /// all-skipped / upcoming-only days → `.onTime` (deliberate decision /
    /// nothing due yet — mirrors the legacy glyph semantics); a day with no
    /// ledger rows minted at all → `.noSchedule` (off-week, pre-creation,
    /// or beyond the 366-day server window).
    private func ledgerGlyphs(
        _ ledger: MedicationDoseHistoryEnvelope,
        days: Int,
        now: Date,
        calendar: Calendar
    ) -> [VerlaufGlyph] {
        let today = calendar.startOfDay(for: now)
        var rowsByDay: [Date: [MedicationDoseHistoryRow]] = [:]
        for row in ledger.rows {
            rowsByDay[calendar.startOfDay(for: row.at), default: []].append(row)
        }
        return (0 ..< days).reversed().map { offset -> VerlaufGlyph in
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: today),
                  dayStart <= now else
            {
                return .noSchedule
            }
            guard let dayRows = rowsByDay[dayStart], !dayRows.isEmpty else {
                return .noSchedule
            }
            var sawLate = false
            var sawTake = false
            var sawActionable = false
            for row in dayRows {
                switch row.status {
                case .missed:
                    return .missed
                case .takenLate:
                    sawLate = true
                    sawActionable = true
                case .takenOnTime, .adHoc:
                    sawTake = true
                    sawActionable = true
                case .skipped:
                    sawActionable = true
                case .upcoming, nil:
                    continue
                }
            }
            if sawLate { return .late }
            if sawTake || sawActionable { return .onTime }
            // Upcoming-only day (today, dose not due yet) — on-track.
            return .onTime
        }
    }

    /// `YYYY-MM-DD` formatter for the server's per-day `dailyCompliance`
    /// key. **v0.10.0 B15:** v1.7.0 keys by `userDayKey(dayStart,
    /// user.timezone)`, not UTC. iOS day starts are device-local midnight;
    /// formatting those in UTC for a user east of UTC (Berlin) lands on the
    /// previous day → every lookup misses → `.noSchedule` dashes. Using the
    /// caller's `calendar.timeZone` makes the iOS key == the server key. Since
    /// W-TZ-MED (v0.15.2) the caller's calendar defaults to the server-profile
    /// zone (not the device TZ), so a traveling user (device tz ≠ account tz)
    /// now keys on the same profile day the server graded against.
    ///
    /// **Audit B-6** — this is the only zone the lookup uses. The UTC second
    /// attempt it used to be paired with is gone: see ``verlaufGlyphs(days:now:calendar:)``.
    private nonisolated static func dailyComplianceKeyFormatter(for timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func glyph(
        forDay events: [PaginatedIntakeEvent],
        now: Date
    ) -> VerlaufGlyph {
        guard !events.isEmpty else { return .noSchedule }
        let pastDue = events.filter { $0.scheduledFor <= now }
        // Future-only day — nothing has come due yet, render as
        // "on-track" so the operator doesn't see a missed-circle for
        // a dose they couldn't possibly have taken.
        guard !pastDue.isEmpty else { return .onTime }
        let taken = pastDue.filter { !$0.skipped && $0.takenAt != nil }
        let skipped = pastDue.filter(\.skipped)
        let unactioned = pastDue.count - taken.count - skipped.count
        // The day counts as missed when at least one past-due slot was
        // neither taken nor deliberately skipped.
        if unactioned > 0 { return .missed }
        guard !taken.isEmpty else { return .onTime } // all skipped
        let allInTime = taken.allSatisfy { event in
            guard let takenAt = event.takenAt else { return false }
            return abs(takenAt.timeIntervalSince(event.scheduledFor)) <= 30 * 60
        }
        return allInTime ? .onTime : .late
    }

    /// Best-effort parser for the medication's headline dose string
    /// ("7.5 mg" / "1.0 mg" / "5 mg"). Returns the **first** numeric token,
    /// parsed locale-awarely — no other units accepted (defensive).
    ///
    /// FORM-5: display-only. The old implementation blindly replaced ","→"."
    /// which mangled a German grouped headline ("1.000 mg" → `1.0`, wrong by
    /// 1000×). We now extract the leading numeric token and hand it to
    /// ``LocaleDecimalParser`` (the single canonical seam that honours the
    /// user's decimal + grouping separators, so a de-DE "1.000 mg" reads as
    /// 1000 and "0,5 mg" as 0.5). Nothing here is persisted.
    internal static func parseHeadlineDose(_ dose: String) -> Double? {
        parseHeadlineDose(dose, locale: .current)
    }

    /// Locale-injectable seam behind ``parseHeadlineDose(_:)`` so the
    /// grouping/decimal behaviour is unit-pinnable independent of the host
    /// locale (see `ParseHeadlineDoseTests`).
    internal static func parseHeadlineDose(_ dose: String, locale: Locale) -> Double? {
        // Walk character-by-character; pick the first contiguous numeric run.
        // Keep both "." and "," so ``LocaleDecimalParser`` can disambiguate
        // decimal vs grouping against `locale` — do NOT normalise here.
        var token = ""
        for char in dose {
            if char.isNumber || char == "." || char == "," {
                token.append(char)
            } else if !token.isEmpty {
                break
            }
        }
        guard !token.isEmpty else { return nil }
        return LocaleDecimalParser.parse(token, locale: locale)
    }
}
