import Foundation

// Hourly sums of the summed types for the server's
// same-time baseline.
//
// Server contract, `MBombeck/HealthLog` `release/v1.43.0` (`d06ce3604`,
// `docs/api/openapi.yaml` and `src/lib/measurements/intraday-hour-buckets.ts`):
//
//   * external id `stats:<HKIdentifier>:<YYYY-MM-DD>T<HH>`, the local hour in
//     the account's zone (`/api/auth/me` `timezone`), zero-padded;
//   * `value` the hour's SUM in the unit of the day form, `startDate` the first
//     instant of that local hour, `endDate` one hour later;
//   * only for steps, active energy, walking and running distance and flights
//     climbed (no daylight), only while `features.cumulativeHourBuckets`;
//   * never a measurement and never part of the day total, which stays the
//     day form the app keeps posting; a re-post overwrites (`updated`);
//   * an hour not posted counts as "not reported" (`-1`), and a day needs at
//     least four posted hours before the server builds its profile from them;
//   * on the autumn day one local hour happens twice: both starts carry the
//     same key and must travel in the same batch, the server sums them.

/// One hourly sum of a summed type.
public struct HealthKitHourlyStatRow: Sendable, Equatable {
    public let hkIdentifier: String
    /// The first instant of the local hour.
    public let hourStart: Date
    /// `yyyy-MM-dd` of the hour in the account's zone.
    public let dayKey: String
    /// 0 ... 23, local.
    public let hour: Int
    public let value: Double
    public let unit: String

    public init(hkIdentifier: String, hourStart: Date, dayKey: String, hour: Int, value: Double, unit: String) {
        self.hkIdentifier = hkIdentifier
        self.hourStart = hourStart
        self.dayKey = dayKey
        self.hour = hour
        self.value = value
        self.unit = unit
    }

    public static let hourSeconds: TimeInterval = 3600

    /// `stats:<HK>:<YYYY-MM-DD>T<HH>`.
    public var externalId: String {
        Self.externalId(hkIdentifier: hkIdentifier, dayKey: dayKey, hour: hour)
    }

    public static func externalId(hkIdentifier: String, dayKey: String, hour: Int) -> String {
        "stats:\(hkIdentifier):\(dayKey)T\(hour < 10 ? "0" : "")\(hour)"
    }

    /// The identity one accepted value is remembered under: the instant, not
    /// the key, so the two occurrences of a repeated autumn hour stay apart.
    var slot: String {
        "\(hkIdentifier)@\(Int(hourStart.timeIntervalSince1970))"
    }

    var entry: HealthKitBatchEntryDTO {
        HealthKitBatchEntryDTO(
            hkIdentifier: hkIdentifier,
            value: value,
            unit: unit,
            startDate: hourStart,
            endDate: hourStart.addingTimeInterval(Self.hourSeconds),
            externalId: externalId
        )
    }

    /// The four types the server takes hourly rows for (daylight is not one).
    public static let identifiers: [String] = [
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierFlightsClimbed"
    ]

    /// The day-form configs of the four hourly types, so the hour and the day
    /// row of one type always carry the same unit.
    public static var configs: [HealthKitCumulativeTypeConfig] {
        HealthKitCumulativeTypeConfig.defaults.filter { identifiers.contains($0.identifier) }
    }

    /// Builds the rows of one type from HealthKit's hourly buckets.
    ///
    /// A day without any value posts nothing: a day the phone has no data
    /// for stays "not reported" on the server, as its day total does. A day
    /// with data posts every hour HealthKit enumerated, an empty hour as `0`:
    /// for a summed type no sample in an hour is a sum of zero, which is the
    /// same reading the day total makes. A bucket that does not start on a
    /// whole hour in `calendar` (a zone the device cannot align) is dropped,
    /// because the server would skip it as misaligned.
    public static func rows(
        identifier: String,
        wireUnit: String,
        buckets: [(start: Date, value: Double?)],
        calendar: Calendar
    ) -> [HealthKitHourlyStatRow] {
        var byDay: [String: [HealthKitHourlyStatRow]] = [:]
        var dayHasData: Set<String> = []
        for bucket in buckets {
            let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: bucket.start)
            guard parts.minute == 0, parts.second == 0, (parts.nanosecond ?? 0) == 0, let hour = parts.hour else {
                continue
            }
            let dayKey = HealthKitStatisticsService.dayKey(for: bucket.start, calendar: calendar)
            let value = max(0, bucket.value ?? 0)
            if value > 0 { dayHasData.insert(dayKey) }
            byDay[dayKey, default: []].append(HealthKitHourlyStatRow(
                hkIdentifier: identifier,
                hourStart: bucket.start,
                dayKey: dayKey,
                hour: hour,
                value: value,
                unit: wireUnit
            ))
        }
        return byDay
            .filter { dayHasData.contains($0.key) }
            .flatMap(\.value)
            .sorted { ($0.hourStart, $0.hkIdentifier) < ($1.hourStart, $1.hkIdentifier) }
    }
}

/// What one hourly read produced. `timeZoneIdentifier` names the zone the
/// hours were cut in; `nil` means the reader has no hourly support at all.
public struct HealthKitHourlyStatsRead: Sendable, Equatable {
    public let rows: [HealthKitHourlyStatRow]
    public let failedTypes: Int
    public let timeZoneIdentifier: String?

    public init(rows: [HealthKitHourlyStatRow], failedTypes: Int, timeZoneIdentifier: String?) {
        self.rows = rows
        self.failedTypes = failedTypes
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public static let unsupported = HealthKitHourlyStatsRead(rows: [], failedTypes: 0, timeZoneIdentifier: nil)
}

/// How much history one pass may give the hourly backfill. Built from the
/// pass's history budget: only triggers that may walk history at all get
/// one, so a short wake or an observer delivery never pays for it.
public struct HourlyStatsBackfillAllowance: Sendable {
    /// Closed days one run may read and post.
    public let maxDays: Int
    /// Wall time one run may take, on top of the pass's own window.
    public let timeBudget: TimeInterval
    public let isExpired: @Sendable () -> Bool

    public init(maxDays: Int, timeBudget: TimeInterval, isExpired: @escaping @Sendable () -> Bool = { false }) {
        self.maxDays = maxDays
        self.timeBudget = timeBudget
        self.isExpired = isExpired
    }
}

/// The outcome of one hourly run, kept for Sync Diagnostics.
public enum HourlyStatsOutcome: String, Codable, Sendable, CaseIterable {
    /// The server does not report `features.cumulativeHourBuckets` (or the
    /// local day-stats switch is off): nothing was read or sent.
    case serverUnsupported
    case notAdmitted
    case queryFailed
    case uploaded
    case upToDate
    case uploadFailed
    /// The pass's time ran out before every owed day was sent.
    case expired
}

/// Per-account progress of the hourly path.
struct HourlyStatsLedger: Codable, Equatable, Sendable {
    /// The zone the remembered hours were cut in. Another zone means other
    /// hours, so a change starts the ledger over (the server does the same).
    var timeZoneIdentifier: String?
    /// Accepted values per day, keyed by ``HealthKitHourlyStatRow/slot``.
    var accepted: [String: [String: Double]] = [:]
    /// Closed days the backfill has sent in full.
    var completedDays: Set<String> = []
    var lastLiveUploadAt: Date?
    var lastBackfillUploadAt: Date?
    var lastLiveOutcome: HourlyStatsOutcome?
    var lastBackfillOutcome: HourlyStatsOutcome?

    /// Adopts `zone`; a different zone than the remembered one clears the
    /// hours, so every hour is sent again in the new zone.
    mutating func adopt(timeZoneIdentifier zone: String) {
        guard zone != timeZoneIdentifier else { return }
        if timeZoneIdentifier != nil {
            accepted = [:]
            completedDays = []
        }
        timeZoneIdentifier = zone
    }

    /// The rows the server does not hold yet: every row whose value differs
    /// from the accepted one, plus every row that shares an external id with
    /// such a row (the repeated autumn hour has to travel whole).
    func changedRows(_ rows: [HealthKitHourlyStatRow]) -> [HealthKitHourlyStatRow] {
        let changedIds = Set(rows.filter { accepted[$0.dayKey]?[$0.slot] != $0.value }.map(\.externalId))
        return rows.filter { changedIds.contains($0.externalId) }
    }

    mutating func remember(_ rows: [HealthKitHourlyStatRow]) {
        for row in rows {
            accepted[row.dayKey, default: [:]][row.slot] = row.value
        }
    }

    /// Forgets everything before `oldestDayKey` (`yyyy-MM-dd` sorts by date).
    mutating func prune(before oldestDayKey: String) {
        accepted = accepted.filter { $0.key >= oldestDayKey }
        completedDays = completedDays.filter { $0 >= oldestDayKey }
    }
}

/// Read-only summary for Sync Diagnostics (W5 owns the surface).
public struct HourlyStatsStatus: Sendable, Equatable {
    public let backfillDaysTotal: Int
    public let backfillDaysCompleted: Int
    public let lastLiveUploadAt: Date?
    public let lastBackfillUploadAt: Date?
    public let lastLiveOutcome: HourlyStatsOutcome?
    public let lastBackfillOutcome: HourlyStatsOutcome?

    public var isBackfillComplete: Bool {
        backfillDaysCompleted >= backfillDaysTotal
    }
}

enum HourlyStatsLedgerStore {
    static let keyPrefix = "hl.healthkit.hourlyStats.v1."

    static func key(ownerID: String) -> String {
        keyPrefix + HealthKitBackfillWindowStore.partitionToken(for: ownerID)
    }

    static func load(ownerID: String, defaults: UserDefaults) -> HourlyStatsLedger {
        guard let data = defaults.data(forKey: key(ownerID: ownerID)),
              let ledger = try? JSONDecoder().decode(HourlyStatsLedger.self, from: data) else
        {
            return HourlyStatsLedger()
        }
        return ledger
    }

    static func save(_ ledger: HourlyStatsLedger, ownerID: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: key(ownerID: ownerID))
    }

    /// What Sync Diagnostics may show for `ownerID`.
    static func status(ownerID: String, defaults: UserDefaults = .standard) -> HourlyStatsStatus {
        let ledger = load(ownerID: ownerID, defaults: defaults)
        let total = HealthKitStatisticsSyncCoordinator.hourlyBackfillDayOffsets.count
        return HourlyStatsStatus(
            backfillDaysTotal: total,
            backfillDaysCompleted: min(total, ledger.completedDays.count),
            lastLiveUploadAt: ledger.lastLiveUploadAt,
            lastBackfillUploadAt: ledger.lastBackfillUploadAt,
            lastLiveOutcome: ledger.lastLiveOutcome,
            lastBackfillOutcome: ledger.lastBackfillOutcome
        )
    }
}
