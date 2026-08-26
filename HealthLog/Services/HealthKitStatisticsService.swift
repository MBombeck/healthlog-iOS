import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// Eine pro-Tag-Aggregat-Row fuer einen kumulativen HK-Type. Wird vom
/// `HealthKitStatisticsService` aus `HKStatistics` gebaut und vom Caller
/// (im Composition-Root: `HealthKitService` → `MeasurementBatchUploader`)
/// in eine `HealthKitBatchEntryDTO` plus locked-format `externalId` ueber-
/// fuehrt.
///
/// **externalId-Format** (locked v1.4.30 §12,
/// `08-locked-contracts.md`): `stats:<HKQuantityTypeIdentifier>:<YYYY-MM-DD>`.
/// Das Date-Segment ist user-TZ-Kalender-Tag (nicht UTC) — `dayKey` wird
/// vom Service genau in dieser Form vorgerechnet, damit der Konsument
/// keinen eigenen DateFormatter aufbauen muss.
public struct HealthKitDailyStatRow: Sendable, Equatable {
    /// Raw HK-Identifier (`"HKQuantityTypeIdentifierStepCount"` etc.).
    public let hkIdentifier: String
    /// User-TZ-Calendar-Day-Start (00:00 lokal). Wird als `measuredAt`
    /// zum Server geschickt.
    public let dayStart: Date
    /// Lokal-Kalender-Tag im `yyyy-MM-dd`-Format. Trennzeichen im
    /// `externalId` (siehe `externalId`).
    public let dayKey: String
    /// Kumulativ-Summe fuer den Tag, bereits in der Server-Unit (Steps,
    /// kcal, flights, Meter, Minuten).
    public let value: Double
    /// Server-Wire-Unit (`"steps"`, `"kcal"`, `"flights"`, `"m"`,
    /// `"minutes"`). Spiegelt das `unitMap` aus
    /// `src/lib/validations/measurement.ts`.
    public let unit: String

    public init(
        hkIdentifier: String,
        dayStart: Date,
        dayKey: String,
        value: Double,
        unit: String
    ) {
        self.hkIdentifier = hkIdentifier
        self.dayStart = dayStart
        self.dayKey = dayKey
        self.value = value
        self.unit = unit
    }

    /// Locked externalId. v1.4.30 §12 — `stats:<HKQuantityTypeIdentifier>:<YYYY-MM-DD>`.
    public var externalId: String {
        "stats:\(hkIdentifier):\(dayKey)"
    }
}

/// Konfigurations-Bundle pro kumulativem HK-Type. Bindet einen
/// `HKQuantityTypeIdentifier` an seine Wire-Unit-Strings + die HK-Unit
/// die der Statistics-Query intern braucht.
public struct HealthKitCumulativeTypeConfig: Sendable, Equatable {
    public let identifier: String
    /// Server-wire-unit-string (siehe `06-ios-responsibilities.md` Tabelle +
    /// `src/lib/validations/measurement.ts` `unitMap`).
    public let wireUnit: String

    public init(identifier: String, wireUnit: String) {
        self.identifier = identifier
        self.wireUnit = wireUnit
    }

    /// Canonical 5 cumulative types (locked v1.4.30 §12). Anchor in einem
    /// Set damit ein paralleler Konsument (`HealthKitService.handleNewSamples`)
    /// schnell pruefen kann, ob ein Sample-Type ueber den per-day-Pfad
    /// (stats) statt per-sample-Pfad (batch.externalId = uuid) geht.
    public static let cumulativeIdentifiers: Set<String> = [
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierFlightsClimbed",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierTimeInDaylight"
    ]

    /// Default-Konfig fuer alle 5 locked cumulative types. Wire-Units
    /// muessen 1:1 zum server-side `unitMap` passen — sonst rejected
    /// die Server-Batch-Route die Row mit `unit_mismatch`.
    public static let defaults: [HealthKitCumulativeTypeConfig] = [
        HealthKitCumulativeTypeConfig(identifier: "HKQuantityTypeIdentifierStepCount", wireUnit: "steps"),
        HealthKitCumulativeTypeConfig(identifier: "HKQuantityTypeIdentifierActiveEnergyBurned", wireUnit: "kcal"),
        HealthKitCumulativeTypeConfig(identifier: "HKQuantityTypeIdentifierFlightsClimbed", wireUnit: "flights"),
        HealthKitCumulativeTypeConfig(identifier: "HKQuantityTypeIdentifierDistanceWalkingRunning", wireUnit: "m"),
        HealthKitCumulativeTypeConfig(identifier: "HKQuantityTypeIdentifierTimeInDaylight", wireUnit: "minutes")
    ]
}

#if canImport(HealthKit)

    /// Statistics-Query-Wrapper fuer kumulative HK-Types. Sammelt einen
    /// User-TZ-bucketed Daily-Sum (`HKStatisticsCollectionQuery` mit
    /// `intervalComponents: DateComponents(day: 1)` + `options: .cumulativeSum`)
    /// und liefert eine Liste von `HealthKitDailyStatRow`-Eintraegen, die der
    /// Caller in Batch-DTOs verwandelt und ueber den existierenden
    /// `/api/measurements/batch`-Pfad an den Server schickt.
    ///
    /// **Warum kein Direkt-POST aus dem Service?**
    /// - Wir wollen die Cert-Pinning + Idempotency-Key + 429-Backoff-Logik
    ///   des existierenden `APIClient` + `MeasurementBatchUploader` reuse.
    /// - Der Caller (`HealthKitService`-Orchestrator) kennt den User-Auth-Status
    ///   und kann den Run unterdruecken bevor wir HK-Queries triggern, wenn
    ///   `enableDailyStats == false` (FeatureFlag).
    /// - Tests koennen den Service mit einem Stub-`HealthKitStatisticsQuerying`
    ///   isoliert decken.
    public actor HealthKitStatisticsService {
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

        /// Collect daily-sum rows fuer einen Type-Konfig zwischen `from` und
        /// `to` (beide inklusive auf Day-Granularitaet — der Statistics-Query
        /// bucket-trimmed selbst). Liefert leeres Array wenn der Type vom
        /// Device nicht unterstuetzt wird (z.B. `TimeInDaylight` auf einem
        /// pre-iOS-17 SDK ohne den Symbol).
        ///
        /// Anchor-Konvention: `from` wird auf den Start des User-TZ-Tages
        /// runter-gerundet, `to` auf den NAECHSTEN Tagesanfang nach `to`
        /// hoch-gerundet — sonst rutscht der letzte heutige Tag aus dem
        /// Statistics-Output. Die Caller verlassen sich darauf, dass
        /// "heute mit aktuellem Tagestotal" eingeschlossen ist.
        public func dailyRows(
            for config: HealthKitCumulativeTypeConfig,
            from: Date,
            to: Date
        ) async throws -> [HealthKitDailyStatRow] {
            guard let quantityType = HKObjectType.quantityType(
                forIdentifier: HKQuantityTypeIdentifier(rawValue: config.identifier)
            ) else {
                // SDK-Mismatch (z.B. TimeInDaylight auf <iOS17) — leer zurueck,
                // der Caller springt zum naechsten Type.
                return []
            }

            let anchor = startOfDay(for: from)
            let interval = DateComponents(day: 1)
            let endExclusive = startOfDay(for: nextDay(after: to))
            let predicate = HKQuery.predicateForSamples(
                withStart: anchor,
                end: endExclusive,
                options: []
            )

            let unit = hkUnit(for: config.identifier)
            let collection = try await runStatisticsCollection(
                quantityType: quantityType,
                predicate: predicate,
                anchor: anchor,
                interval: interval
            )

            return Self.rows(
                from: collection,
                identifier: config.identifier,
                wireUnit: config.wireUnit,
                hkUnit: unit,
                anchor: anchor,
                endExclusive: endExclusive,
                calendar: calendar
            )
        }

        /// Pure-funktionaler Extractor — getrennt vom Actor-isolated Code,
        /// damit der `enumerateStatistics`-Closure-Pfad nicht den Actor-State
        /// touched und Swift 6 nicht ueber "sending non-Sendable rows" meckert.
        nonisolated static func rows(
            from collection: HKStatisticsCollection,
            identifier: String,
            wireUnit: String,
            hkUnit: HKUnit,
            anchor: Date,
            endExclusive: Date,
            calendar: Calendar
        ) -> [HealthKitDailyStatRow] {
            var rows: [HealthKitDailyStatRow] = []
            collection.enumerateStatistics(from: anchor, to: endExclusive) { stats, _ in
                guard let sum = stats.sumQuantity() else { return }
                let value = sum.doubleValue(for: hkUnit)
                // Skip 0-rows — der Server schreibt sie eh in dieselbe Range-Validation
                // wie ein expliziter 0-POST, und ohne sie sparen wir die meiste Bandbreite
                // (idle-Tage haben keine Daten).
                guard value > 0 else { return }
                let row = HealthKitDailyStatRow(
                    hkIdentifier: identifier,
                    dayStart: stats.startDate,
                    dayKey: dayKey(for: stats.startDate, calendar: calendar),
                    value: value,
                    unit: wireUnit
                )
                rows.append(row)
            }
            return rows
        }

        /// Convenience-Wrapper: Daily-Rows fuer alle Default-Configs in einem
        /// Zeitraum. Liefert ein dictionary keyed by hkIdentifier; einzelne
        /// Types deren Query throw'ed werden uebersprungen (per-type-error
        /// blockiert nicht die anderen 4).
        public func dailyRowsForAllDefaults(
            from: Date,
            to: Date
        ) async -> [String: [HealthKitDailyStatRow]] {
            var out: [String: [HealthKitDailyStatRow]] = [:]
            for config in HealthKitCumulativeTypeConfig.defaults {
                do {
                    let rows = try await dailyRows(for: config, from: from, to: to)
                    if !rows.isEmpty {
                        out[config.identifier] = rows
                    }
                } catch {
                    HLLog.healthKit.error(
                        "Stats-Query \(config.identifier, privacy: .private) failed: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
            return out
        }

        /// **GH #48 / server v1.28 — nutrient day-totals.** Same day-anchored
        /// cumulative-sum machinery as ``dailyRows(for:from:to:)`` but with an
        /// EXPLICIT wire unit (`mg` | `ug` | `ml`) rather than the 5-type
        /// measurements switch — the caller (``NutrientDailySyncCoordinator``)
        /// resolves the HK mass/volume unit from the catalog. Returns rows carrying
        /// `dayKey` (user-TZ `yyyy-MM-dd`) + the day's cumulative total in the
        /// catalog unit. Empty when the type is unsupported on the device or the
        /// unit string is unknown. 0-value days are skipped (no data → no post).
        public func dailyRows(
            forNutrientIdentifier identifier: String,
            wireUnit: String,
            from: Date,
            to: Date
        ) async throws -> [HealthKitDailyStatRow] {
            guard let hkUnit = Self.hkUnit(forWireUnit: wireUnit) else {
                // Unknown wire unit — never send an unconvertible value.
                return []
            }
            guard let quantityType = HKObjectType.quantityType(
                forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)
            ) else {
                // SDK-Mismatch / unsupported dietary type — skip.
                return []
            }

            let anchor = startOfDay(for: from)
            let interval = DateComponents(day: 1)
            let endExclusive = startOfDay(for: nextDay(after: to))
            let predicate = HKQuery.predicateForSamples(
                withStart: anchor,
                end: endExclusive,
                options: []
            )

            let collection = try await runStatisticsCollection(
                quantityType: quantityType,
                predicate: predicate,
                anchor: anchor,
                interval: interval
            )

            return Self.rows(
                from: collection,
                identifier: identifier,
                wireUnit: wireUnit,
                hkUnit: hkUnit,
                anchor: anchor,
                endExclusive: endExclusive,
                calendar: calendar
            )
        }

        /// Resolves a nutrient catalog wire unit to its `HKUnit`. `mg`→milligram,
        /// `ug`→microgram, `ml`→millilitre. Mass stays in the metric unit — NEVER
        /// IU. Returns `nil` for an unknown string so the caller drops the type
        /// rather than posting an unconvertible value. `nonisolated` — pure.
        nonisolated static func hkUnit(forWireUnit wireUnit: String) -> HKUnit? {
            switch wireUnit {
            case "mg": HKUnit.gramUnit(with: .milli)
            case "ug": HKUnit.gramUnit(with: .micro)
            case "ml": HKUnit.literUnit(with: .milli)
            default: nil
            }
        }

        // MARK: - Internals

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

        private func startOfDay(for date: Date) -> Date {
            calendar.startOfDay(for: date)
        }

        private func nextDay(after date: Date) -> Date {
            calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }

        /// Per-Identifier HK-Unit fuer die statistics-Sum-Query. Mirror der
        /// `HealthKitWireConverter.preferredUnit`-Tabelle, aber auf die 5
        /// cumulative types beschraenkt.
        private nonisolated func hkUnit(for identifier: String) -> HKUnit {
            switch identifier {
            case "HKQuantityTypeIdentifierStepCount",
                 "HKQuantityTypeIdentifierFlightsClimbed":
                .count()
            case "HKQuantityTypeIdentifierActiveEnergyBurned":
                .kilocalorie()
            case "HKQuantityTypeIdentifierDistanceWalkingRunning":
                .meter()
            case "HKQuantityTypeIdentifierTimeInDaylight":
                .minute()
            default:
                .count()
            }
        }

        /// `yyyy-MM-dd` in user-TZ. Locked v1.4.30 §12. `nonisolated`, weil
        /// reine Berechnung — Tests ohne Service-Instanz koennen den Helper
        /// gegen die contract-locked Beispiele aus den 08-locked-contracts
        /// asserten.
        public nonisolated static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
            let formatter = dayKeyFormatter
            // Calendar drives the TZ — die TZ wird vom Calendar uebernommen,
            // damit "user-TZ" wirklich vom Caller injectable ist (z.B. Tests
            // mit `Europe/Berlin` calendar explicit).
            formatter.timeZone = calendar.timeZone
            return formatter.string(from: date)
        }

        /// ISO-8601-style `yyyy-MM-dd` formatter. `locale = en_US_POSIX` damit
        /// die Tagesstrings nicht durch User-Locale-Settings drift (locked
        /// contract bestaeht auf der numerischen Form, unabhaengig von
        /// Calendar-Lokalisierung).
        nonisolated static var dayKeyFormatter: DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }
    }

    public enum HealthKitStatisticsError: Error, Sendable, Equatable {
        case noCollection
    }

    /// GH #48 — the nutrient sync coordinator queries HK through the
    /// ``NutrientDailyRowsProviding`` seam; the concrete service already exposes
    /// the matching `dailyRows(forNutrientIdentifier:wireUnit:from:to:)`.
    extension HealthKitStatisticsService: NutrientDailyRowsProviding {}

#endif
