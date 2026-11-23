import Foundation

/// **Which scheduled dose a logged intake counts for, said before it is saved.**
///
/// The app had three ways to log an intake and asked this three ways: the free
/// log bound a skip to its own time and let the server guess for a take, the
/// card resolved a slot on its own, and the history offered "attribute to this
/// slot" only after the save. The one intake form (#191, server 1.49.0) reads
/// the answer off the chosen time, says it in words under the fields ("Counts
/// for the 08:00 dose") and the write carries it:
///
/// - a take within the on-time half-window of a slot counts for it
///   (`scheduledFor`, the server's canonical slot upsert);
/// - a take further off, up to four hours, counts for it as late unless the
///   person switches that off (`forceSlotInstant`);
/// - anything else, or a medication without dose times, is an extra dose
///   outside the schedule (no slot field);
/// - a skip always names the slot it skips, the nearest one on that day.
///
/// A mirror of the web's `intake-form/slot-attribution.ts`. Pure: the caller
/// hands in the calendar whose zone the time picker writes in.
public enum IntakeSlotAttribution: Equatable, Sendable {
    /// Within the on-time window: counts for the slot.
    case slot(Slot)
    /// Near, outside the on-time window, and the switch is on: counts as late.
    case late(Slot)
    /// An extra dose. `nearSlot` is the slot the take was near when the
    /// person switched the late count off, so the switch stays in view.
    case extra(nearSlot: Slot?)
    /// A skip of the nearest slot.
    case skip(Slot)
    /// A skip with no slot to skip (no dose times).
    case noSlot

    /// A dose time on the day of the chosen time.
    public struct Slot: Equatable, Sendable {
        /// The wall-clock dose time.
        public let time: TimeOfDay
        /// The instant of the dose time on that day.
        public let instant: Date
        /// Minutes between the chosen time and the slot, unsigned.
        public let gapMinutes: Double

        public init(time: TimeOfDay, instant: Date, gapMinutes: Double) {
            self.time = time
            self.instant = instant
            self.gapMinutes = gapMinutes
        }

        /// The dose time as minutes after midnight, for the hour-cycle aware clock.
        public var minutesAfterMidnight: Int {
            time.hour * 60 + time.minute
        }
    }

    /// How a take sits against its nearest slot.
    public enum TakeClass: Equatable, Sendable {
        case exact
        case near
        case extra
    }

    /// The default on-time half-window in minutes (±1 h, the dose-window default).
    public static let onTimeMinutes: Double = 60
    /// Past this gap a take is clearly its own extra dose.
    public static let nearSlotCeilingMinutes: Double = 240

    // MARK: - Dose times

    /// Distinct dose times across the entries, sorted. An as-needed entry has
    /// none; an entry without times of day contributes its window start.
    public static func slotTimes(of entries: [ScheduleEntry]) -> [TimeOfDay] {
        var times = Set<TimeOfDay>()
        for entry in entries where entry.cadence != .asNeeded {
            times.formUnion(entry.effectiveTimes)
        }
        return times.sorted()
    }

    /// The medication's dose times; none for an as-needed medication.
    public static func slotTimes(of medication: Medication) -> [TimeOfDay] {
        medication.asNeeded ? [] : slotTimes(of: medication.schedule.entries)
    }

    /// A medication without dose times has no dose to skip, so the form
    /// offers Taken only.
    public static func offersSkip(for medication: Medication) -> Bool {
        !slotTimes(of: medication).isEmpty
    }

    // MARK: - The rule

    /// The instant of `time` on the local day of `day`.
    public static func slotInstant(on day: Date, at time: TimeOfDay, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
    }

    /// The dose time nearest to `takenAt` on its own day, or nil.
    public static func nearestSlot(takenAt: Date, times: [TimeOfDay], calendar: Calendar) -> Slot? {
        var best: Slot?
        for time in times {
            guard let instant = slotInstant(on: takenAt, at: time, calendar: calendar) else { continue }
            let gap = abs(instant.timeIntervalSince(takenAt)) / 60
            if best == nil || gap < (best?.gapMinutes ?? .infinity) {
                best = Slot(time: time, instant: instant, gapMinutes: gap)
            }
        }
        return best
    }

    /// How a take sits against its nearest slot.
    public static func classify(_ nearest: Slot?) -> TakeClass {
        guard let nearest else { return .extra }
        if nearest.gapMinutes <= onTimeMinutes { return .exact }
        if nearest.gapMinutes <= nearSlotCeilingMinutes { return .near }
        return .extra
    }

    /// What the form will record. `countNear` is the person's switch for a
    /// take near, but outside, a slot's on-time window (default on).
    public static func resolve(
        takenAt: Date,
        times: [TimeOfDay],
        skipped: Bool,
        countNear: Bool,
        calendar: Calendar
    ) -> IntakeSlotAttribution {
        let nearest = nearestSlot(takenAt: takenAt, times: times, calendar: calendar)
        if skipped {
            return nearest.map(IntakeSlotAttribution.skip) ?? .noSlot
        }
        switch (classify(nearest), nearest) {
        case let (.exact, slot?):
            return .slot(slot)
        case let (.near, slot?):
            return countNear ? .late(slot) : .extra(nearSlot: slot)
        default:
            return .extra(nearSlot: nil)
        }
    }

    // MARK: - The day's slots, as the server lists them (#191, final)

    /// One slot the server will accept on the chosen day: a dose-history row
    /// with `kind: "slot"` that holds no take and no skip. `at` goes out as
    /// `forceSlotInstant` (or `scheduledFor`), `timeOfDay` is the label. The
    /// app never computes the cadence itself; an off day has no rows.
    public struct DaySlot: Equatable, Sendable {
        public let instant: Date
        public let time: TimeOfDay

        public init(instant: Date, time: TimeOfDay) {
            self.instant = instant
            self.time = time
        }
    }

    /// The open slot rows of a day's ledger: `kind: "slot"`, not taken or
    /// skipped (by `state`, or by `status` on an older server).
    public static func openDaySlots(_ rows: [MedicationDoseHistoryRow]) -> [DaySlot] {
        rows.compactMap { row -> DaySlot? in
            guard row.kind == "slot" else { return nil }
            if let state = row.stateRaw?.lowercased() {
                guard state != "taken", state != "skipped" else { return nil }
            } else {
                switch row.status {
                case .takenOnTime, .takenLate, .skipped, .adHoc: return nil
                case .missed, .upcoming, nil: break
                }
            }
            let time = row.timeOfDay.flatMap(Self.parseTime) ?? TimeOfDay(hour: 0, minute: 0)
            return DaySlot(instant: row.at, time: time)
        }
        .sorted { $0.instant < $1.instant }
    }

    /// `H:mm`/`HH:mm` of a ledger label.
    static func parseTime(_ text: String) -> TimeOfDay? {
        let parts = text.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1].prefix(2)),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        return TimeOfDay(hour: hour, minute: minute)
    }

    /// The slot nearest to `takenAt` among the server's slots of that day.
    public static func nearestSlot(takenAt: Date, daySlots: [DaySlot]) -> Slot? {
        daySlots
            .map { Slot(time: $0.time, instant: $0.instant, gapMinutes: abs($0.instant.timeIntervalSince(takenAt)) / 60) }
            .min { $0.gapMinutes < $1.gapMinutes }
    }

    /// ``resolve(takenAt:times:skipped:countNear:calendar:)`` on the server's
    /// slots of the day. No slots: an extra dose without `forceSlotInstant`.
    public static func resolve(
        takenAt: Date,
        daySlots: [DaySlot],
        skipped: Bool,
        countNear: Bool
    ) -> IntakeSlotAttribution {
        let nearest = nearestSlot(takenAt: takenAt, daySlots: daySlots)
        if skipped {
            return nearest.map(IntakeSlotAttribution.skip) ?? .noSlot
        }
        switch (classify(nearest), nearest) {
        case let (.exact, slot?):
            return .slot(slot)
        case let (.near, slot?):
            return countNear ? .late(slot) : .extra(nearSlot: slot)
        default:
            return .extra(nearSlot: nil)
        }
    }

    // MARK: - Reading it

    /// The slot the take counts for (on time or late), if any.
    public var countedSlot: Slot? {
        switch self {
        case let .slot(slot), let .late(slot): slot
        default: nil
        }
    }

    /// The slot the "Count it for the 08:00 dose" switch names, if it shows.
    public var nearSlot: Slot? {
        switch self {
        case let .late(slot): slot
        case let .extra(nearSlot): nearSlot
        default: nil
        }
    }

    /// `scheduledFor` of the write: the slot of an on-time take or a skip.
    public var scheduledFor: Date? {
        switch self {
        case let .slot(slot), let .skip(slot): slot.instant
        default: nil
        }
    }

    /// `forceSlotInstant` of the write: the slot of a late take.
    public var forceSlotInstant: Date? {
        if case let .late(slot) = self { return slot.instant }
        return nil
    }

    /// The configured dose: the dose of the schedule the take counts for,
    /// when it names one (titration schedules differ per slot), else the
    /// medication's.
    public static func configuredDose(for medication: Medication, attribution: IntakeSlotAttribution) -> String {
        if let slot = attribution.countedSlot,
           let entry = medication.schedule.entries.first(where: {
               $0.cadence != .asNeeded && $0.effectiveTimes.contains(slot.time)
           }),
           let dose = entry.dose?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dose.isEmpty
        {
            return dose
        }
        return medication.dose
    }
}

/// The fields the one intake form writes to `POST /api/medications/{id}/intake`
/// (server `MedicationIntakeRequest`): `skipped`, `takenAt`, the slot field of
/// the attribution, and `doseTaken` only when the dose deviates from the
/// configured one.
public struct IntakeFormWrite: Equatable, Sendable {
    public let skipped: Bool
    public let takenAt: Date
    public let scheduledFor: Date?
    public let forceSlotInstant: Date?
    public let doseTaken: String?

    public init(
        attribution: IntakeSlotAttribution,
        takenAt: Date,
        skipped: Bool,
        dose: String,
        configuredDose: String
    ) {
        self.skipped = skipped
        self.takenAt = takenAt
        scheduledFor = attribution.scheduledFor
        forceSlotInstant = attribution.forceSlotInstant
        let trimmed = dose.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = configuredDose.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviates = !skipped && !trimmed.isEmpty && trimmed != configured
        doseTaken = deviates ? trimmed : nil
    }
}
