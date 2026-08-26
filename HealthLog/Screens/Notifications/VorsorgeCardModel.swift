import Foundation

/// **W-VORSORGE-CARDS (v0.15.1 web-parity) — pure presentation logic for one
/// preventive-care reminder card.**
///
/// Mirrors the web `vorsorge-section.tsx` card grammar (v1.18.2): a cadence
/// chip, a "next due / last done" block, a discreet 7-day strip, an origin
/// badge, an `endsOn` line, and a single bottom-pinned action that branches on
/// `measurementType` (measure-now vs mark-done).
///
/// **Render-only doctrine:** the reminder engine is the single authority for
/// due dates. The relative-due bucket here is *presentation of the delta to
/// now* (exactly what the web `relativeDueKey` does) — it NEVER recomputes the
/// cadence/`nextDueAt`. All cadence/`endsOn`/`lastSatisfiedAt` text is the
/// server value formatted, never arithmetic.
///
/// Kept free of SwiftUI so the due-bucket + action-branch + strip-derivation
/// decisions are unit-tested without a view host.
enum VorsorgeCard {
    /// Relative due bucket — the web `relativeDueKey` mirror. The card renders
    /// the server `nextDueAt` relative to "now" as a calm word/phrase; this is
    /// display formatting, not a cadence recompute.
    enum DueBucket: Equatable {
        case none
        case overdue(days: Int)
        case today
        case tomorrow
        case inDays(Int)

        /// Localization key for the bucket. Reuses the web's wording 1:1.
        var localizedKey: String {
            switch self {
            case .none: "vorsorge.card.due.none"
            case .overdue: "vorsorge.card.due.overdue"
            case .today: "vorsorge.card.due.today"
            case .tomorrow: "vorsorge.card.due.tomorrow"
            case .inDays: "vorsorge.card.due.inDays"
            }
        }

        /// The `%d` argument the format string expects (days), or `nil` when the
        /// key carries no count (none / today / tomorrow).
        var dayArgument: Int? {
            switch self {
            case let .overdue(days): days
            case let .inDays(days): days
            case .none, .today, .tomorrow: nil
            }
        }

        /// `true` when the reminder is due now or overdue — drives the action
        /// button's prominent "do it now" treatment (the card surface itself
        /// stays neutral, per the no-alarming-tint rule).
        var isDue: Bool {
            switch self {
            case .today, .overdue: true
            case .none, .tomorrow, .inDays: false
            }
        }
    }

    /// Maps a server `nextDueAt` to a relative bucket. `nil` ⇒ `.none` (a
    /// free-text reminder with no scheduled due yet).
    ///
    /// **Parity 1.8c — CALENDAR-day delta, not a rolling 24 h one.** Both
    /// instants are floored to their local day start before differencing,
    /// mirroring the web fix in v1.18.9 (`vorsorge-section.tsx:153-165`, issue
    /// #490). The previous `Int((due - now) / 86400).rounded()` mis-bucketed the
    /// everyday case: a reminder due today 09:00, read the same evening at
    /// 20:00, rounded to −1 and read "seit 1 Tag überfällig" on iOS while the
    /// web said "Heute fällig". The doc comment above it claimed web parity —
    /// it described the *pre*-v1.18.9 web code.
    static func dueBucket(
        nextDueAt: Date?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> DueBucket {
        guard let due = nextDueAt else { return .none }
        let dueDay = calendar.startOfDay(for: due)
        let nowDay = calendar.startOfDay(for: now)
        // Day-component difference between two day starts — DST-safe, unlike a
        // fixed 86400 s divisor (a 23 h / 25 h day would round the wrong way).
        let deltaDays = calendar.dateComponents([.day], from: nowDay, to: dueDay).day ?? 0
        if deltaDays < 0 { return .overdue(days: abs(deltaDays)) }
        if deltaDays == 0 { return .today }
        if deltaDays == 1 { return .tomorrow }
        return .inDays(deltaDays)
    }

    /// **Parity 1.8b — resolve a reminder's display label.**
    ///
    /// A `COACH`-minted reminder stores an **i18n KEY** in `label` (the cadence
    /// preset's `labelKey`, e.g. `coach.reminderSuggestion.cadence.bp722`), not
    /// free prose; a user-created `VORSORGE` reminder stores free text. iOS
    /// rendered `row.label` verbatim for both, so a coach reminder showed the
    /// bare key on the card. Mirrors the web `resolveReminderLabel`
    /// (`vorsorge-section.tsx:170-184`) including its miss fallback:
    /// `String(localized:)` echoes an unknown key back, in which case the raw
    /// value is used so a future catalog addition never surfaces as a bare key.
    ///
    /// Returns `nil` when the reminder carries no usable label at all (the
    /// caller then falls back to the measurement-type label).
    static func resolvedLabel(for row: MeasurementReminderRow) -> String? {
        let trimmed = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard row.origin == .coach else { return trimmed }
        let translated = String(localized: String.LocalizationValue(trimmed))
        return translated == trimmed ? trimmed : translated
    }

    /// The card's primary-action branch. A measurement-linked reminder opens the
    /// prefilled capture sheet ("measure now"); a free-text / self-planned
    /// reminder marks done silently ("mark done"). Mirrors the web
    /// `onPrimaryAction` branch on `measurementType`.
    enum PrimaryAction: Equatable {
        /// Open the capture sheet seeded with this `MetricKind`, then satisfy.
        case measure(MetricKind)
        /// #42 (v1.27.6) — a mental-wellbeing screening reminder
        /// (`PHQ9_SCORE` / `GAD7_SCORE` / `WHO5_SCORE`): the sum score is derived,
        /// not hand-entered, so the action starts the check-in surface instead of
        /// a numeric capture form or a silent mark-done.
        case checkIn
        /// No mappable capture kind (free-text, or a type the capture sheet
        /// can't record) — mark the reminder done directly.
        case markDone
    }

    /// Resolves the primary action for a row, reusing the Home tile's
    /// server-type→`MetricKind` map so the two front doors stay identical. A
    /// screening reminder (PHQ9/GAD7/WHO5) gets `.checkIn`; a row whose
    /// `measurementType` maps to a capturable kind gets `.measure`; everything
    /// else (free-text, or a scale-only type) gets `.markDone`.
    static func primaryAction(for row: MeasurementReminderRow) -> PrimaryAction {
        // #42 — screening scores are server-derived, so they route to the
        // mental-health check-in, NOT a numeric entry form. Checked FIRST so a
        // future overlap with the capture map can't win.
        if MeasurementReminderType.isMentalHealthScreening(row.measurementType) {
            return .checkIn
        }
        if let kind = VorsorgeNextDue.prefillKind(forServerType: row.measurementType) {
            return .measure(kind)
        }
        return .markDone
    }

    // MARK: - Detail arm (W-VORSORGE-DETAIL, b244)

    /// Which detail experience the card's tap opens. Mirrors the same branch
    /// root as ``primaryAction(for:)`` — a screening reminder is checked FIRST,
    /// then a capture-mappable metric, else the honest free-text arm. Kept pure
    /// + SwiftUI-free so the routing is unit-tested without a view host.
    enum DetailArm: Equatable {
        /// The linked metric's reading history is chartable (`recent(kind:)`).
        case metric(MetricKind)
        /// A mental-wellbeing screening reminder (PHQ-9 / GAD-7 / WHO-5 / SCI):
        /// the richer severity-band history lives on the `MentalHealthStore`.
        case screening(MentalHealthInstrument)
        /// No linked metric + not a screener — no chart, an honest Next/Last sheet.
        case freeText
    }

    /// Resolves the detail arm for a row. Screening FIRST (so a future overlap
    /// with the capture map can't win), then a capture-mappable `MetricKind`
    /// (the SAME `VorsorgeNextDue.prefillKind` seam the measure-now action uses),
    /// else free-text.
    static func detailArm(for row: MeasurementReminderRow) -> DetailArm {
        if let instrument = mentalHealthInstrument(forServerType: row.measurementType) {
            return .screening(instrument)
        }
        if let kind = VorsorgeNextDue.prefillKind(forServerType: row.measurementType) {
            return .metric(kind)
        }
        return .freeText
    }

    /// Maps a screening reminder's server `measurementType` (`PHQ9_SCORE` …) onto
    /// its ``MentalHealthInstrument``. `nil` for any non-screening / free-text
    /// type. The screener set matches ``MeasurementReminderType/isMentalHealthScreening``.
    static func mentalHealthInstrument(forServerType raw: String?) -> MentalHealthInstrument? {
        switch raw {
        case "PHQ9_SCORE": .phq9
        case "GAD7_SCORE": .gad7
        case "WHO5_SCORE": .who5
        case "SCI_SCORE": .sci
        default: nil
        }
    }

    /// One dated chart point — a SwiftUI-free mirror of `HistoryLineChart.Point`
    /// so the pure card logic never imports SwiftUI. The model maps these onto
    /// the view's point type.
    struct ChartPoint: Equatable {
        let id: String
        let date: Date
        let value: Double
    }

    /// Chart points for the metric arm from the linked metric's readings.
    ///
    /// The server returns newest-first (`recent(kind:)`); this reverses to
    /// oldest → newest (left = older → right = newest, as the strip does),
    /// extracts each row's `primaryValue` (systolic for BP), and returns `nil`
    /// for fewer than two points — the SAME "one dot is no trend" rule as
    /// ``stripHeights(values:)``.
    static func chartPoints(from measurements: [Measurement]) -> [ChartPoint]? {
        let ordered = Array(measurements.reversed())
        guard ordered.count >= 2 else { return nil }
        return ordered.map { ChartPoint(id: $0.id, date: $0.recordedAt, value: $0.primaryValue) }
    }

    /// Derives the discreet 7-day strip bar heights (0…1, oldest → newest) from
    /// a metric's recent readings. Mirrors the web `VorsorgeTrendStrip`
    /// normalisation: floor at 18 % so a flat series still reads as bars, span
    /// guarded against divide-by-zero. Returns `nil` (render nothing) for fewer
    /// than two readings — a single dot is no trend.
    ///
    /// `values` is expected oldest → newest (the caller reverses the server's
    /// newest-first list, as the web does).
    static func stripHeights(values: [Double]) -> [Double]? {
        guard values.count >= 2 else { return nil }
        let min = values.min() ?? 0
        let max = values.max() ?? 0
        let span = (max - min) == 0 ? 1 : (max - min)
        return values.map { 0.18 + (($0 - min) / span) * 0.82 }
    }

    /// Whether the manage list should self-suppress to the empty state. Empty
    /// when there are no reminders at all (the calm empty card shows instead).
    static func shouldShowEmptyState(reminders: [MeasurementReminderRow]) -> Bool {
        reminders.isEmpty
    }

    /// Relative next-due text (the web `relativeDueKey` mirror) — presentation of
    /// the server `nextDueAt` delta, never a cadence recompute. Shared by the card
    /// and the detail sheet so the two surfaces read identically.
    static func dueDisplayText(nextDueAt: Date?, now: Date = .now) -> String {
        let bucket = dueBucket(nextDueAt: nextDueAt, now: now)
        let key = String.LocalizationValue(bucket.localizedKey)
        if let days = bucket.dayArgument {
            return String(format: String(localized: key), days)
        }
        return String(localized: key)
    }

    /// Relative last-done text — "heute"/"gestern" where natural, absolute date
    /// fallback, "—" when never satisfied. Shared by the card and the sheet.
    static func lastDoneDisplayText(
        lastSatisfiedAt: Date?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        guard let last = lastSatisfiedAt else { return "—" }
        let day = calendar.startOfDay(for: last)
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        if day == today {
            return String(localized: "medications.today")
        }
        if day == yesterday {
            return String(localized: "medications.yesterday")
        }
        return last.formatted(.dateTime.day().month().year())
    }

    /// Cadence chip text — "Every N days" or a "Custom" label for an RRULE.
    /// Render verbatim from the server cadence; never recomputed. `nil` ⇒ no
    /// chip (neither interval nor rrule present).
    static func cadenceKeyAndArg(for row: MeasurementReminderRow) -> (key: String, days: Int?)? {
        if let days = row.intervalDays {
            return ("vorsorge.card.cadence.everyNDays", days)
        }
        if let rrule = row.rrule, !rrule.isEmpty {
            return ("vorsorge.card.cadence.custom", nil)
        }
        return nil
    }

    // MARK: - Adherence summary — REMOVED (G1, 2026-08-22)

    // `AdherenceSummary` and `adherenceSummary(reminders:now:calendar:)` lived
    // here from b215 (`b84adbe0`) until 2026-08-23. They folded the reminder
    // portfolio into the honest current-state snapshot the „4 von 4 im Plan"
    // header rendered.
    //
    // The header is gone on the operator's statement („soll komplett raus"), and
    // the fold went with it rather than staying behind as a pure function with
    // no reader. That is the deliberate half of the decision: a tested,
    // documented aggregation sitting unused is an invitation to re-mount the
    // surface it was written for, and re-mounting it needs a NEW request — he
    // asked for the card himself on 2026-07-07 and withdrew it on 2026-08-22.
    //
    // Nothing else consumed it (`dueBucket`, `isSnoozed` and the ledger seam are
    // untouched), and the per-reminder completion ledger its last revision
    // pointed at is unaffected: it renders on the reminder it describes.
}

// MARK: - ROUTE-07 (server v1.37.20) — snooze cursor, skipped cycle, ledger

/// The reminder's two derived states and its completion ledger, as presentation.
///
/// Both states are **clock comparisons against instants the server sent**, which
/// is exactly what the accepted DTO description tells clients to do ("snoozed
/// means snoozedUntil > now, a skipped cycle means lastSkippedAt >
/// lastSatisfiedAt; clients compare against the clock and never recompute
/// cadence"). Nothing here derives a due date, a cadence, an event, an order or
/// a page window.
extension VorsorgeCard {
    /// Is the current cycle snoozed? `snoozedUntil > now`, and nothing else. The
    /// cursor self-expires because the comparison is against the clock, so no
    /// invalidation is needed when the moment passes.
    static func isSnoozed(_ row: MeasurementReminderRow, now: Date = .now) -> Bool {
        guard let until = row.snoozedUntil else { return false }
        return until > now
    }

    /// Was the current cycle skipped rather than completed?
    /// `lastSkippedAt > lastSatisfiedAt`. A reminder skipped but never satisfied
    /// counts: there is nothing for the skip to be older than, and a skip never
    /// moves `lastSatisfiedAt` — that is the contract's own distinction.
    static func hasSkippedCurrentCycle(_ row: MeasurementReminderRow) -> Bool {
        guard let skipped = row.lastSkippedAt else { return false }
        guard let satisfied = row.lastSatisfiedAt else { return true }
        return skipped > satisfied
    }

    /// One rendered ledger row. Every member is either a server value or a
    /// localization key chosen by a total `switch` over a server value — never a
    /// key assembled from a wire string, which would mint keys for values the
    /// catalogue has never heard of.
    struct LedgerEntry: Equatable, Identifiable, Sendable {
        let id: String
        /// When the fulfilment or the skip happened. Formatted, never compared.
        let occurredAt: Date
        /// `vorsorge.history.kind.*`
        let kindKey: String
        /// `vorsorge.history.source.*`
        let sourceKey: String
        /// `vorsorge.history.onTime` / `vorsorge.history.late` — the server
        /// derived this at write time against the due instant that was current
        /// then. iOS never re-derives it, exactly as it never recomputes
        /// `nextDueAt`.
        let punctualityKey: String
        /// The exact string the server sent for an unrecognised `kind`/`source`.
        /// `nil` for a value the client knows. A row with an unknown value is
        /// rendered with a neutral label **and** this token, because dropping it
        /// would be a hole in a history the person has no other way to see.
        let unknownWireValue: String?
    }

    /// What the ledger section should render. The three ways a ledger can be
    /// absent are three different sentences on purpose — collapsing them is how
    /// "your history is empty" ends up on a reminder whose history was simply
    /// never requested, or never offered.
    enum LedgerState: Equatable, Sendable {
        /// Not asked yet, or the first page is in flight.
        case loading
        /// The route answered `404` for this reminder: it does not offer a
        /// ledger here. Not an error and not an empty history.
        case unsupported
        /// Loaded, and honestly empty. The ledger begins at the release that
        /// introduced it and cannot be backfilled, so this is the true answer
        /// for every reminder older than it — the copy must say that.
        case empty
        /// Rows to render, newest first, exactly as the server ordered them.
        case loaded(entries: [LedgerEntry], hasMore: Bool)
        /// A page failed. Whatever was already accepted stays on screen and a
        /// retry is offered; emptying the list would lose server truth over a
        /// transport problem.
        case failed(entries: [LedgerEntry], hasMore: Bool)
    }

    /// Maps the store's ledger onto what the surface renders. The ONLY input is
    /// the ledger; the reminder row is deliberately not a parameter, so a rowful
    /// of `lastSatisfiedAt` / `lastSkippedAt` / `skipCount` cannot leak into a
    /// history the server did not send.
    static func ledgerState(_ ledger: MeasurementReminderLedger) -> LedgerState {
        if ledger.isUnsupported { return .unsupported }
        let entries = ledger.events.map(ledgerEntry(for:))
        if ledger.error != nil { return .failed(entries: entries, hasMore: ledger.hasMore) }
        if ledger.isLoading, entries.isEmpty { return .loading }
        if !ledger.isLoaded { return .loading }
        if entries.isEmpty { return .empty }
        return .loaded(entries: entries, hasMore: ledger.hasMore)
    }

    /// One server event, rendered. Order is not touched here — the caller maps
    /// the array the server returned, in the order it returned it.
    static func ledgerEntry(for event: MeasurementReminderEvent) -> LedgerEntry {
        LedgerEntry(
            id: event.id,
            occurredAt: event.occurredAt,
            kindKey: kindKey(event.kind),
            sourceKey: sourceKey(event.source),
            punctualityKey: event.onTime ? "vorsorge.history.onTime" : "vorsorge.history.late",
            unknownWireValue: unknownWireValue(kind: event.kind, source: event.source)
        )
    }

    /// Total switch — a key per published value, plus one neutral key for a
    /// value a newer server invented.
    static func kindKey(_ kind: MeasurementReminderEventKind) -> String {
        switch kind {
        case .satisfied: "vorsorge.history.kind.satisfied"
        case .skipped: "vorsorge.history.kind.skipped"
        case .unknown: "vorsorge.history.kind.unknown"
        }
    }

    /// Total switch over the seven published sources. The accepted contract says
    /// the set will widen, which is why `.unknown` has a key of its own rather
    /// than a key derived from the wire string.
    static func sourceKey(_ source: MeasurementReminderEventSource) -> String {
        switch source {
        case .manual: "vorsorge.history.source.manual"
        case .autoMeasurement: "vorsorge.history.source.autoMeasurement"
        case .autoLab: "vorsorge.history.source.autoLab"
        case .telegram: "vorsorge.history.source.telegram"
        case .vaccination: "vorsorge.history.source.vaccination"
        case .encounter: "vorsorge.history.source.encounter"
        case .skip: "vorsorge.history.source.skip"
        case .unknown: "vorsorge.history.source.unknown"
        }
    }

    /// The raw token behind an unrecognised `kind` or `source`, so the row shows
    /// what the server actually said. `kind` wins when both are unknown — it is
    /// the more load-bearing of the two.
    static func unknownWireValue(
        kind: MeasurementReminderEventKind,
        source: MeasurementReminderEventSource
    ) -> String? {
        if case let .unknown(raw) = kind { return raw }
        if case let .unknown(raw) = source { return raw }
        return nil
    }
}
