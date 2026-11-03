import Foundation

#if canImport(HealthKit)
    import HealthKit

    /// **X4 (1.3, #138 / #77)** — the hourly read behind the same-time
    /// baseline. The same statistics machinery as the day totals, with one-hour
    /// intervals anchored on the start of the day in the account's zone (the
    /// one ``dayAnchorCalendar`` reads), so every bucket starts on a whole local
    /// hour and keys exactly as the server cuts it.
    public extension HealthKitStatisticsService {
        func hourlyTimeZone() async -> TimeZone? {
            dayAnchorCalendar.timeZone
        }

        func hourlyRows(from: Date, through: Date) async -> HealthKitHourlyStatsRead {
            let calendar = dayAnchorCalendar
            let anchor = calendar.startOfDay(for: from)
            // Through the end of `through`'s hour: the hour in progress is
            // included and overwritten by the next sweep as it fills.
            let endExclusive = calendar.dateInterval(of: .hour, for: through)?.end
                ?? through.addingTimeInterval(HealthKitHourlyStatRow.hourSeconds)
            guard endExclusive > anchor else {
                return HealthKitHourlyStatsRead(rows: [], failedTypes: 0, timeZoneIdentifier: calendar.timeZone.identifier)
            }
            var rows: [HealthKitHourlyStatRow] = []
            var failedTypes = 0
            for config in HealthKitHourlyStatRow.configs {
                guard let quantityType = HKObjectType.quantityType(
                    forIdentifier: HKQuantityTypeIdentifier(rawValue: config.identifier)
                ) else { continue }
                // B5 (1.4, R4 2.1) — no hour that is only partly readable.
                let start = await readableStart(anchor, of: quantityType, bucket: .hour)
                guard start < endExclusive else { continue }
                do {
                    let collection = try await runStatisticsCollection(
                        quantityType: quantityType,
                        predicate: HKQuery.predicateForSamples(withStart: start, end: endExclusive, options: []),
                        anchor: start,
                        interval: DateComponents(hour: 1)
                    )
                    let buckets = Self.hourBuckets(
                        from: collection,
                        hkUnit: hkUnit(for: config.identifier),
                        anchor: start,
                        endExclusive: endExclusive
                    )
                    rows += HealthKitHourlyStatRow.rows(
                        identifier: config.identifier,
                        wireUnit: config.wireUnit,
                        buckets: buckets,
                        calendar: calendar
                    )
                } catch {
                    failedTypes += 1
                    // The error's type only: a message can carry a date.
                    let errorType = String(describing: type(of: error))
                    // swiftlint:disable:next hllog_public_privacy_interpolation
                    HLLog.healthKit.error("HK-HOURLY query failed — error=\(errorType, privacy: .public)")
                }
            }
            return HealthKitHourlyStatsRead(
                rows: rows,
                failedTypes: failedTypes,
                timeZoneIdentifier: calendar.timeZone.identifier
            )
        }

        /// Every hourly interval HealthKit enumerates, an empty one with `nil`.
        /// `nonisolated` and pure, like ``rows(from:identifier:wireUnit:hkUnit:anchor:endExclusive:calendar:)``.
        internal nonisolated static func hourBuckets(
            from collection: HKStatisticsCollection,
            hkUnit: HKUnit,
            anchor: Date,
            endExclusive: Date
        ) -> [(start: Date, value: Double?)] {
            var out: [(start: Date, value: Double?)] = []
            collection.enumerateStatistics(from: anchor, to: endExclusive) { stats, _ in
                guard stats.startDate < endExclusive else { return }
                out.append((stats.startDate, stats.sumQuantity()?.doubleValue(for: hkUnit)))
            }
            return out
        }
    }

#endif
