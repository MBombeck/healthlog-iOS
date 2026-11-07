import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// HK-NEW (1.5) — the two category types the server maps since v1.44.0.
    /// Kept apart from the main table so the converter file does not grow with
    /// every family.
    extension HealthKitWireConverter {
        /// Stand hours and mindful sessions; `[]` for every other category type.
        ///
        /// - `AppleStandHour`: one row with value `1` for a stood hour
        ///   (`HKCategoryValueAppleStandHour.stood`). An idle hour is never a
        ///   row: the server counts stood hours, and an idle `0` would still be
        ///   one row in its sum (`apple-health-mapping.ts`, the archive importer
        ///   drops `Idle` the same way).
        /// - `MindfulSession`: the session length in minutes from the sample's
        ///   own dates, the sleep contract. A sample with no length is dropped.
        static func server144CategoryEntries(_ sample: HKCategorySample) -> [HealthKitBatchEntryDTO] {
            switch sample.categoryType.identifier {
            case HealthKitServer144Types.standHour:
                guard sample.value == HKCategoryValueAppleStandHour.stood.rawValue else { return [] }
                return [categoryEntry(sample, value: 1, unit: "count")]
            case HealthKitServer144Types.mindfulSession:
                let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60.0
                guard minutes > 0 else { return [] }
                return [categoryEntry(sample, value: minutes, unit: "min")]
            default:
                return []
            }
        }

        /// The exercise and stand rings in minutes; AFib burden as the raw
        /// 0…1 fraction (the server scales ×100 and refuses anything above 1,
        /// so never pre-scale). `nil` for every other identifier.
        static func server144Unit(for identifier: String) -> WireUnit? {
            switch identifier {
            case HealthKitServer144Types.exerciseTime, HealthKitServer144Types.standTime:
                WireUnit(hkUnit: .minute(), wireSymbol: "min", scale: 1)
            case HealthKitServer144Types.afibBurden:
                WireUnit(hkUnit: .percent(), wireSymbol: "%", scale: 1)
            default:
                nil
            }
        }

        private static func categoryEntry(_ sample: HKCategorySample, value: Double, unit: String) -> HealthKitBatchEntryDTO {
            HealthKitBatchEntryDTO(
                hkIdentifier: sample.categoryType.identifier,
                value: value,
                unit: unit,
                startDate: sample.startDate,
                endDate: sample.endDate,
                externalId: sample.uuid.uuidString,
                externalSourceVersion: sample.sourceRevision.productType,
                deviceType: deviceType(for: sample.device)
            )
        }
    }

#endif
