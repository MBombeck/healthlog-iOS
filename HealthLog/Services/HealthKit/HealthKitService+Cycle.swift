import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **Phase C2 — reproductive-category authorization + write-back surface.**
    ///
    /// The stateless cycle entry points on ``HealthKitService`` live here (the
    /// `cycleImporter` stored property + its start/stop/reset lifecycle stay on
    /// the main actor body, since an extension cannot add stored state). Split out
    /// to keep `HealthKitService.swift` under the 600-line file budget.
    ///
    /// The caller only reaches these once `CycleGate.isCycleTrackingAvailable` is true — men are
    /// NEVER prompted for cycle types because the cycle set is kept OUT of
    /// `defaultReadTypes`/`defaultWriteTypes` (the always-on onboarding sheet).
    public extension HealthKitService {
        /// Request the full reproductive-category read+share auth set up front
        /// (flow + vaginal bleeding + intermenstrual + mucus + ovulation + sexual
        /// activity + pregnancy/progesterone tests + the symptom catalogue).
        func requestCycleAuthorization() async throws {
            // NOTE: there is NO `HKCategoryTypeIdentifierVaginalBleeding` type —
            // `HKCategoryValueVaginalBleeding` is only the iOS-18 *value* enum on
            // the menstrual-flow type (verified against the iOS 26.5 SDK), which
            // is already part of `readCategoryTypes()`.
            let types = Set(CycleHealthKitImporter.readCategoryTypes().map { $0 as HKSampleType })
            try await store.requestAuthorization(toShare: types, read: Set(types.map { $0 as HKObjectType }))
        }

        /// Mirror a MANUAL cycle day-log into Apple Health (gate on a 2xx server
        /// write — HK has no metadata de-dup). Echo-guards `source:"HEALTHKIT"`
        /// rows internally. `isCycleStart` feeds the REQUIRED
        /// `HKMetadataKeyMenstrualCycleStart` flag on the flow sample.
        func writeCycleDayLog(_ dayLog: CycleDayLogDTO, isCycleStart: Bool) async throws {
            try await CycleHealthKitWriter(store: store).write(dayLog, isCycleStart: isCycleStart)
        }

        /// Delete every HK cycle sample mirrored for a day-log (by the anti-dup
        /// `HKMetadataKeyExternalUUID` marker).
        func deleteCycleDayLog(id: String) async throws {
            try await CycleHealthKitWriter(store: store).delete(dayLogID: id)
        }

        /// **No-prompt** read of the cached biological-sex characteristic, mapped
        /// to a platform-free ``CycleGateResolver/BiologicalSexSignal`` for the
        /// cycle gate's resolution path #3.
        ///
        /// `HKHealthStore.biologicalSex()` reads the already-stored characteristic
        /// and NEVER triggers an authorization prompt. When auth was not granted
        /// independently it throws — we map that (and any error) to `.unknown`, so
        /// the fallback contributes nothing and men are NEVER surfaced the feature.
        func cycleBiologicalSexSignal() -> CycleGateResolver.BiologicalSexSignal {
            do {
                let biologicalSex = try store.biologicalSex().biologicalSex
                switch biologicalSex {
                case .female: return .female
                case .male: return .male
                case .other: return .other
                case .notSet: return .notSet
                @unknown default: return .unknown
                }
            } catch {
                // Not authorized / unavailable — contribute nothing to the gate.
                return .unknown
            }
        }
    }

#endif
