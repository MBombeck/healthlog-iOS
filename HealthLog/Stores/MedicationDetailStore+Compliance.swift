// Compliance KPI + Verlauf-glyph track split out of MedicationDetailStore.swift (pure move, W-FILELEN).
import Foundation

extension MedicationDetailStore {
    // MARK: - v0.6.1.2 Y4 — compliance KPI + Verlauf glyph track

    /// In-time compliance summary for the detail-screen KPI block.
    /// "In-time" = `takenAt` within ±30 min of `scheduledFor`. Mirrors
    /// the web's "on_time" classification (`src/lib/analytics/compliance.ts`
    /// `classifyIntakeTiming`) at a tighter, easier-to-explain tolerance —
    /// the operator brief prefers a single bar over the four-bucket
    /// breakdown the web charts surface.
    public struct ComplianceSummary: Sendable, Equatable {
        /// Number of past-due intakes with `takenAt` within ±30 min of
        /// their `scheduledFor`. Skipped events do not count toward this
        /// numerator — they're a deliberate user decision, not a miss.
        public let inTime: Int
        /// Total number of past-due intakes considered (taken + missed
        /// + skipped). Future-scheduled rows are excluded so the bar
        /// doesn't pessimistically count a yet-to-fire dose as a miss.
        public let total: Int
        /// Convenience ratio in 0...1. Returns 1.0 when `total == 0` so
        /// a fresh medication paints "full" instead of "empty/error".
        public var ratio: Double {
            total == 0 ? 1.0 : Double(inTime) / Double(total)
        }

        /// Integer percentage 0...100 for the KPI text rendering.
        public var percentage: Int {
            Int((ratio * 100).rounded())
        }

        public init(inTime: Int, total: Int) {
            self.inTime = inTime
            self.total = total
        }
    }

    /// Per-day glyph for the Verlauf track. Maps to a single SF Symbol
    /// in `MedicationDetailSections.VerlaufGlyphTrack`.
    public enum VerlaufGlyph: Sendable, Equatable {
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

    /// Compliance summary for the last 30 days.
    ///
    /// **W45 (v0.11) — client-intake authoritative.** This screen's intake
    /// TABLE renders `intakes`, which `load()` drains to the FULL history
    /// (`drainRemainingIntakes`). The operator's complaint was that the KPI %
    /// and the Verlauf glyph track diverged from that table — they read the
    /// server's compliance payload, whose 30-day window is bounded by the
    /// account's server-side effective-days clamp (`calculateCompliance`
    /// clamps `totalExpected` to the medication's server lifespan +
    /// `createdAt`). For a long-history twice-daily Lisinopril re-imported into a
    /// young server account that window collapses to a handful of slots, so the
    /// KPI under-counted (and the prior #42 band-aid that floored `total` at the
    /// loaded past-due count produced a `taken > total` > 100 % reading).
    ///
    /// Root fix: the loaded `intakes` set is the same truth the table shows, so
    /// it is the authoritative source for the trailing-30-day KPI whenever it
    /// carries any past-due slot in the window. We derive both the numerator
    /// (`taken` in-time) and the denominator (past-due slots) from it, so
    /// `inTime ≤ total` holds by construction and optimistic today-marks
    /// (already applied to `intakes`) update the bar immediately.
    ///
    /// Server fallback: when the client has NOT loaded any past-due intake for
    /// the window (initial paint before the drain completes, or a genuinely
    /// sparse client view), read the server's cadence-canonical `compliance30`
    /// verbatim — the case the original server-canonical path fixed ("0 von 2"
    /// against a paged-out intake set). The server `rate` is already
    /// `min(100, …)`-capped, and we cap `inTime` at `total` regardless, so the
    /// denominator can never be exceeded.
    public func complianceSummary(now: Date = .now) -> ComplianceSummary {
        // W3-MEDCONTRACT — ledger-first. The server ledger is the same
        // source the compliance % and the web Verlauf read, AND it is
        // era-aware (v1.16.3): a schedule edit archives the old cadence and
        // past days keep being judged against the schedule live then. Any
        // client-side derivation (both branches below) projects from the
        // CURRENT schedule and drifts after an edit, so it survives only as
        // the fallback for ≤ v1.15.17 servers / standalone / fetch hiccups.
        if let ledgerSummary = ledgerComplianceSummary(now: now) {
            return ledgerSummary
        }
        // W-MEDVERIFY (v0.14.8) — server-verbatim doctrine. A v1.7.0-capable
        // `/compliance` payload is cadence-canonical AND era-aware, so it
        // outranks any client-side re-derivation from the drained intake
        // table. The demo walkthrough proved the W45 ordering wrong on a
        // ledger-less server: the card read the server 75 % / 84 % while this
        // KPI re-derived 0 % / 12 % "pünktlich" from the same history — two
        // numbers for one med on adjacent screens. The W45 intake-derivation
        // survives below ONLY for pre-v1.7.0 payloads (degenerate
        // effective-days windows) and for settled loads without any payload.
        if let payload = compliance, payload.isV170Capable {
            return Self.serverWindowSummary(payload.compliance30)
        }
        let loadedTotal = loadedPastDueCount(now: now)
        if loadedTotal > 0 {
            // The drained intake history covers the window — it is the same
            // truth the table renders, so derive the KPI from it directly.
            let inTime = loadedInTimeCount(now: now)
            return ComplianceSummary(inTime: min(inTime, loadedTotal), total: loadedTotal)
        }
        // No loaded past-due intake in the window → trust the server's
        // 30-day window (or fall through to the empty 100 % state when neither
        // source has data). This is the "0 von 2 against a paged-out intake
        // set" case the original server-canonical path fixed.
        guard let payload = compliance else {
            return ComplianceSummary(inTime: 0, total: 0)
        }
        let window = payload.compliance30
        // Pre-v1.7.0 server (the capable case returned above):
        // `calculateCompliance` computes `totalExpected = schedules.length *
        // effectiveDays`, ignoring `daysOfWeek` / `intervalWeeks` — a weekly
        // Trulicity reads 30, not 4. Recompute the denominator from the local
        // cadence engine and cap at the server number; an engine-projected 0
        // (PRN / future `startsOn` / non-due window) is trusted as genuinely
        // not-due → denominator 0 → 100 %.
        // W-TZ-MED — project expected doses on the server-profile zone (the same
        // zone the cadence engine anchors on for the due surfaces), not the
        // device TZ, so a traveling user's pre-v1.7.0 denominator matches the
        // profile calendar. Falls back to `.current` for a nil/unknown zone.
        let engineContext = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: profileTimeZone,
            now: now
        )
        let scheduleExpected = medication.schedule.expectedDoses(
            from: now.addingTimeInterval(-30 * 24 * 60 * 60),
            to: now,
            context: engineContext
        )
        let effectiveExpected = scheduleExpected > 0
            ? min(scheduleExpected, window.totalExpected)
            : 0
        // Skipped doses leave the denominator (deliberate user decision, W19e
        // doctrine); `inTime` is capped at the resulting total so a server
        // `taken` can never exceed it (no > 100 %).
        let total = max(0, effectiveExpected - window.skipped)
        let inTime = min(window.taken, total)
        return ComplianceSummary(inTime: inTime, total: total)
    }

    /// W-MEDVERIFY (v0.14.8) — the server `/compliance` 30-day window taken
    /// VERBATIM (b177 doctrine: the client never recomputes a rate the server
    /// already graded). `totalExpected` is cadence-canonical on v1.7.0+
    /// servers; skipped doses leave the denominator (W19e) and `inTime` is
    /// capped at the resulting total so `taken` can never exceed it.
    private static func serverWindowSummary(
        _ window: ComplianceWindowResult
    ) -> ComplianceSummary {
        let total = max(0, window.totalExpected - window.skipped)
        return ComplianceSummary(inTime: min(window.taken, total), total: total)
    }

    /// **W-COMPLIANCE-INV — KPI paint state.** The view renders exactly one of:
    /// a placeholder (`.pending`), the server-canonical number (`.server` —
    /// dose-history ledger first, the `/compliance` 30-day window second), or
    /// the clearly-marked local estimate (`.localFallback` — only after the
    /// load attempt has settled WITHOUT any server compliance payload:
    /// offline, standalone against a local mirror, or a ≤ v1.15.17 server
    /// whose degenerate window the W42/W45 doctrine overrides with the loaded
    /// intake history). The client-side interim derivation can therefore
    /// never paint before the server round-trip has had its chance.
    public enum ComplianceKPIState: Sendable, Equatable {
        /// First load still in flight — paint a skeleton/placeholder.
        case pending
        /// Server-canonical value (ledger or `/compliance` window).
        case server(ComplianceSummary)
        /// Local derivation — offline / old-server fallback. Views mark it.
        case localFallback(ComplianceSummary)
    }

    /// Resolve the KPI paint state for the detail screen. Mirrors the
    /// `complianceSummary` source precedence exactly (ledger → loaded
    /// intakes → server window → empty) but tags WHICH source produced the
    /// number, and gates every non-ledger paint on `hasSettledComplianceLoad`
    /// so partial-drain interim values never reach the screen.
    public func complianceKPIState(now: Date = .now) -> ComplianceKPIState {
        if let ledgerSummary = ledgerComplianceSummary(now: now) {
            return .server(ledgerSummary)
        }
        guard hasSettledComplianceLoad else { return .pending }
        let summary = complianceSummary(now: now)
        // W-MEDVERIFY (v0.14.8) — a v1.7.0-capable `/compliance` window is
        // server-canonical (mirrors the `complianceSummary` precedence): it
        // must paint as `.server`, never as the "Offline – lokale Schätzung"
        // badge the W45 ordering produced while demonstrably online.
        if compliance?.isV170Capable == true {
            return .server(summary)
        }
        if loadedPastDueCount(now: now) > 0 {
            // W45 doctrine branch — derived from the drained intake table
            // (pre-v1.7.0 server / degenerate window).
            return .localFallback(summary)
        }
        if compliance != nil {
            return .server(summary)
        }
        return .localFallback(summary)
    }

    /// W3-MEDCONTRACT — trailing-30-day KPI from the server ledger.
    ///
    /// "Pünktlich" = a slot the server graded `taken_on_time` (its own
    /// per-dose window bands, v1.15.18 — not the legacy hardcoded ±30 min).
    /// Denominator = every past actionable slot (`taken_on_time` +
    /// `taken_late` + `missed`); skipped slots leave the denominator (W19e
    /// doctrine, matches the server's `tallyLedgerRows` rate) and
    /// `upcoming` slots never count (b162 dose-safety: a future slot can't
    /// read as taken or missed). Ad-hoc takes are off-schedule — excluded
    /// from a punctuality ratio, mirroring the server rate. Returns `nil`
    /// when no ledger is loaded (caller falls back to local derivation).
    private func ledgerComplianceSummary(now: Date) -> ComplianceSummary? {
        guard let ledger = doseHistory else { return nil }
        let windowStart = now.addingTimeInterval(-30 * 24 * 60 * 60)
        var inTime = 0
        var total = 0
        for row in ledger.rows where row.at >= windowStart && row.at <= now {
            switch row.status {
            case .takenOnTime:
                inTime += 1
                total += 1
            case .takenLate, .missed:
                total += 1
            case .skipped, .upcoming, .adHoc, nil:
                continue
            }
        }
        return ComplianceSummary(inTime: inTime, total: total)
    }

    /// W42 — count of past-due intakes already loaded for the trailing 30-day
    /// window. The store drains the full intake history in `load()`, so this is
    /// the truthful client-side denominator the server's degenerate window must
    /// not undercut. Skipped events are included (mirrors the legacy fallback's
    /// `pastDue.count`, where skipped intakes still occupied a slot).
    private func loadedPastDueCount(now: Date) -> Int {
        let windowStart = now.addingTimeInterval(-30 * 24 * 60 * 60)
        return intakes.filter {
            $0.scheduledFor >= windowStart && $0.scheduledFor <= now
        }.count
    }

    /// W42 — count of past-due intakes taken within ±30 min of their scheduled
    /// time, over the same trailing 30-day window. The in-time numerator paired
    /// with `loadedPastDueCount(now:)`.
    private func loadedInTimeCount(now: Date) -> Int {
        let windowStart = now.addingTimeInterval(-30 * 24 * 60 * 60)
        return intakes.lazy
            .filter { $0.scheduledFor >= windowStart && $0.scheduledFor <= now }
            .filter { event in
                guard !event.skipped, let takenAt = event.takenAt else { return false }
                return abs(takenAt.timeIntervalSince(event.scheduledFor)) <= 30 * 60
            }
            .count
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
    public func verlaufGlyphs(days: Int = 14, now: Date = .now, calendar: Calendar? = nil) -> [VerlaufGlyph] {
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
        let dueOverlay: (Date) -> Bool? = { [self] dayStart in
            guard let payload = compliance, payload.isV170Capable else { return nil }
            let localFormatter = Self.dailyComplianceKeyFormatter(for: calendar.timeZone)
            let utcFormatter = Self.dailyComplianceKeyFormatter(
                for: TimeZone(identifier: "UTC") ?? calendar.timeZone
            )
            let bucket = payload.dailyCompliance[localFormatter.string(from: dayStart)]
                ?? payload.dailyCompliance[utcFormatter.string(from: dayStart)]
            return bucket?.wasDue
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
    static func parseHeadlineDose(_ dose: String) -> Double? {
        parseHeadlineDose(dose, locale: .current)
    }

    /// Locale-injectable seam behind ``parseHeadlineDose(_:)`` so the
    /// grouping/decimal behaviour is unit-pinnable independent of the host
    /// locale (see `ParseHeadlineDoseTests`).
    static func parseHeadlineDose(_ dose: String, locale: Locale) -> Double? {
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
