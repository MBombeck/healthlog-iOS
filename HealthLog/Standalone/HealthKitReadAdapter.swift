import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// v0.11 W1 — HealthKit-direct series reader for standalone mode.
///
/// In standalone (no server) the dashboard / charts have no server SWR path to
/// read HK-backed metrics from — they need to read HealthKit directly. This
/// adapter generalizes `LiveHealthKitTodayStore`'s single-tile step read into a
/// reusable series/recent reader, emitting the same `[SeriesPoint]` shape the
/// chart views already consume.
///
/// **Anti-duplicate rule (PROJECT_GUIDE.md):** samples we wrote ourselves carry
/// `HKMetadataKeyExternalUUID`. When reading for the *local* lists we skip
/// those — otherwise a manual measurement would surface twice (once from the
/// `LocalRepository` mirror, once from its HK echo). Cumulative/aggregate reads
/// (steps via `HKStatisticsCollectionQuery`) sum everything: those are device
/// totals where our own contribution is already part of the legitimate sum.
///
/// **W1 scope (focused):** discrete reads cover **weight** + **heart rate**;
/// cumulative reads cover **steps**. The remaining dashboard/chart HK metrics
/// (BP, glucose, sleep, SpO2, resting HR, …) are a **W2 follow-up** — the
/// read-union wave that wires this adapter into the lists is where the rest of
/// the metric map earns its keep. This wave only freezes the adapter's shape +
/// the anti-dup discipline so W2 can extend the metric switch without reshaping
/// call sites. `LiveHealthKitTodayStore` is left untouched (not half-broken).
public protocol StandaloneHealthKitReading: Sendable {
    /// Recent discrete samples for `kind`, newest-first, capped at `limit`.
    /// Returns `[]` when the metric isn't an adapter-supported discrete type,
    /// when HK is unavailable, or when authorization is denied.
    func recentSamples(kind: MetricKind, days: Int, limit: Int) async -> [SeriesPoint]

    /// Daily-bucketed cumulative series (e.g. steps) over the trailing `days`,
    /// oldest-first. Returns `[]` for non-cumulative kinds / unavailable HK.
    func dailySeries(kind: MetricKind, days: Int) async -> [SeriesPoint]
}

/// v0.11 W2 — bridge the app-only adapter onto the Core read-union seam
/// (`StandaloneHealthKitReadServing`). The protocol method names carry the
/// `standalone…` prefix so they read unambiguously at the repo call sites; the
/// bodies just forward to the existing reader. The conformance is declared in a
/// `where` extension over `StandaloneHealthKitReading` so BOTH the HealthKit and
/// the non-HealthKit (empty-returning) actor variants pick it up.
public extension StandaloneHealthKitReading {
    func standaloneRecentSamples(kind: MetricKind, days: Int, limit: Int) async -> [SeriesPoint] {
        await recentSamples(kind: kind, days: days, limit: limit)
    }

    func standaloneDailySeries(kind: MetricKind, days: Int) async -> [SeriesPoint] {
        await dailySeries(kind: kind, days: days)
    }
}

#if canImport(HealthKit)

    public actor HealthKitReadAdapter: StandaloneHealthKitReading, StandaloneHealthKitReadServing {
        private let store: HKHealthStore
        private let calendar: Calendar
        private let clock: @Sendable () -> Date

        public init(
            store: HKHealthStore = HKHealthStore(),
            calendar: Calendar = .current,
            clock: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.store = store
            self.calendar = calendar
            self.clock = clock
        }

        // MARK: - Discrete reads (weight, heart rate)

        public func recentSamples(kind: MetricKind, days: Int, limit: Int) async -> [SeriesPoint] {
            guard let mapping = Self.discreteMapping(for: kind) else { return [] }
            guard let quantityType = HKObjectType.quantityType(forIdentifier: mapping.identifier) else {
                return []
            }
            let end = clock()
            let start = calendar.date(byAdding: .day, value: -max(1, days), to: end) ?? .distantPast
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let unit = mapping.unit

            let samples: [HKQuantitySample]
            do {
                samples = try await runSampleQuery(
                    sampleType: quantityType,
                    predicate: predicate,
                    limit: max(1, limit),
                    sortDescriptors: [sort]
                )
            } catch {
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.error(
                    // `kind.rawValue` is an enum case (operator-grade); the
                    // error string is sanitised via `LogSanitizer.redact`.
                    "Standalone HK read \(kind.rawValue, privacy: .public) failed: \(LogSanitizer.redact(error.localizedDescription))"
                )
                return []
            }

            return Self.points(from: samples, unit: unit)
        }

        // MARK: - Cumulative reads (steps)

        public func dailySeries(kind: MetricKind, days: Int) async -> [SeriesPoint] {
            guard let config = Self.cumulativeConfig(for: kind) else { return [] }
            guard let quantityType = HKObjectType.quantityType(
                forIdentifier: HKQuantityTypeIdentifier(rawValue: config.identifier)
            ) else { return [] }

            let now = clock()
            let anchor = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -max(1, days), to: now) ?? now
            )
            let endExclusive = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: 1, to: now) ?? now
            )
            let predicate = HKQuery.predicateForSamples(withStart: anchor, end: endExclusive, options: [])
            let hkUnit = Self.cumulativeUnit(for: config.identifier)

            let collection: HKStatisticsCollection
            do {
                collection = try await runStatisticsCollection(
                    quantityType: quantityType,
                    predicate: predicate,
                    anchor: anchor,
                    interval: DateComponents(day: 1)
                )
            } catch {
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.error(
                    // `kind.rawValue` is an enum case (operator-grade); the
                    // error string is sanitised via `LogSanitizer.redact`.
                    "Standalone HK daily-series \(kind.rawValue, privacy: .public) failed: \(LogSanitizer.redact(error.localizedDescription))"
                )
                return []
            }

            return Self.dailyPoints(
                from: collection,
                anchor: anchor,
                endExclusive: endExclusive,
                hkUnit: hkUnit
            )
        }

        // MARK: - Pure extractors

        /// Maps HK discrete samples → `SeriesPoint`, honouring the anti-dup
        /// rule (W-HK-RELIABILITY G-7): only a sample WE wrote — our
        /// `HKMetadataKeyExternalUUID` AND this app's own HK source — is
        /// skipped so the local mirror's row isn't double-counted. A
        /// third-party sample carrying an externalUUID now flows in.
        /// `nonisolated` so the extraction can run off the actor.
        nonisolated static func points(from samples: [HKQuantitySample], unit: HKUnit) -> [SeriesPoint] {
            samples.compactMap { sample in
                if HealthKitSampleOwnership.isOwnEcho(sample) {
                    return nil // our own write — the LocalRepository mirror owns it
                }
                return SeriesPoint(
                    id: sample.uuid.uuidString,
                    at: sample.endDate,
                    value: sample.quantity.doubleValue(for: unit),
                    secondary: nil
                )
            }
        }

        nonisolated static func dailyPoints(
            from collection: HKStatisticsCollection,
            anchor: Date,
            endExclusive: Date,
            hkUnit: HKUnit
        ) -> [SeriesPoint] {
            var points: [SeriesPoint] = []
            collection.enumerateStatistics(from: anchor, to: endExclusive) { stats, _ in
                guard let sum = stats.sumQuantity() else { return }
                let value = sum.doubleValue(for: hkUnit)
                guard value > 0 else { return }
                points.append(
                    SeriesPoint(
                        // v0162 perf — reuse the shared cached formatter instead
                        // of allocating one per statistics bucket. `.plain`
                        // (`.withInternetDateTime`) is byte-identical to the
                        // former default `ISO8601DateFormatter()` output.
                        id: ISO8601DateFormatter.plain.string(from: stats.startDate),
                        at: stats.startDate,
                        value: value,
                        secondary: nil
                    )
                )
            }
            return points
        }

        // MARK: - Metric mapping

        struct DiscreteMapping {
            let identifier: HKQuantityTypeIdentifier
            let unit: HKUnit
        }

        /// Adapter-supported discrete metrics for W1. Weight reads in kilograms
        /// (server-canonical), heart rate in count/min. Extend in W2 for the
        /// remaining discrete metrics (BP, glucose, SpO2, resting HR, …).
        nonisolated static func discreteMapping(for kind: MetricKind) -> DiscreteMapping? {
            switch kind {
            case .weight:
                DiscreteMapping(identifier: .bodyMass, unit: .gramUnit(with: .kilo))
            case .pulse:
                DiscreteMapping(
                    identifier: .heartRate,
                    unit: HKUnit.count().unitDivided(by: .minute())
                )
            default:
                nil
            }
        }

        /// Adapter-supported cumulative metrics for W1 (steps only). Reuses the
        /// existing `HealthKitCumulativeTypeConfig` vocabulary so the wire-unit
        /// stays consistent with the server-sync path.
        nonisolated static func cumulativeConfig(for kind: MetricKind) -> HealthKitCumulativeTypeConfig? {
            switch kind {
            case .steps:
                HealthKitCumulativeTypeConfig(
                    identifier: HKQuantityTypeIdentifier.stepCount.rawValue,
                    wireUnit: "steps"
                )
            default:
                nil
            }
        }

        nonisolated static func cumulativeUnit(for identifier: String) -> HKUnit {
            switch identifier {
            case HKQuantityTypeIdentifier.stepCount.rawValue,
                 HKQuantityTypeIdentifier.flightsClimbed.rawValue:
                .count()
            case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
                .kilocalorie()
            case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
                .meter()
            default:
                .count()
            }
        }

        // MARK: - Query runners

        private func runSampleQuery(
            sampleType: HKSampleType,
            predicate: NSPredicate,
            limit: Int,
            sortDescriptors: [NSSortDescriptor]
        ) async throws -> [HKQuantitySample] {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: sampleType,
                    predicate: predicate,
                    limit: limit,
                    sortDescriptors: sortDescriptors
                ) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
                }
                store.execute(query)
            }
        }

        private func runStatisticsCollection(
            quantityType: HKQuantityType,
            predicate: NSPredicate,
            anchor: Date,
            interval: DateComponents
        ) async throws -> HKStatisticsCollection {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKStatisticsCollectionQuery(
                    quantityType: quantityType,
                    quantitySamplePredicate: predicate,
                    options: .cumulativeSum,
                    anchorDate: anchor,
                    intervalComponents: interval
                )
                query.initialResultsHandler = { _, collection, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let collection else {
                        continuation.resume(throwing: HealthKitStatisticsError.noCollection)
                        return
                    }
                    continuation.resume(returning: collection)
                }
                store.execute(query)
            }
        }
    }

#else

    /// Non-HealthKit build (macOS test host) — every read returns empty. Keeps
    /// the call sites + tests buildable without `#if canImport(HealthKit)`
    /// peppered through them.
    public actor HealthKitReadAdapter: StandaloneHealthKitReading, StandaloneHealthKitReadServing {
        public init() {}

        public func recentSamples(kind _: MetricKind, days _: Int, limit _: Int) async -> [SeriesPoint] {
            []
        }

        public func dailySeries(kind _: MetricKind, days _: Int) async -> [SeriesPoint] {
            []
        }
    }

#endif
