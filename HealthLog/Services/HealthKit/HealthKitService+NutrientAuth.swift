import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **GH #48 / server v1.28 — nutrient read-authorization.**
    ///
    /// The 26 dietary `Dietary*` catalog types (24 vitamins/minerals + water +
    /// caffeine) are deliberately kept OUT of `defaultReadTypes` (the always-on
    /// onboarding sheet) — exactly like the cycle reproductive types. A user is
    /// only prompted for them once the opt-in `nutrients` module is ENABLED, so a
    /// user who never switches nutrients on is never asked for these permissions.
    ///
    /// Read-only: we never WRITE dietary samples back, so `toShare` is empty and
    /// these types stay out of `defaultWriteTypes`.
    public extension HealthKitService {
        /// Request read authorization for the full nutrient catalog. Only reached
        /// once the `nutrients` module is on (mirrors `requestCycleAuthorization`).
        func requestNutrientAuthorization() async throws {
            // The macros are asked only once the server takes them.
            let items = NutrientCatalog.syncItems(includingMacros: AppleHealthIngestCapability.isAvailable(.nutrientMacros))
            let readTypes = Set(items.compactMap { item -> HKObjectType? in
                HKObjectType.quantityType(
                    forIdentifier: HKQuantityTypeIdentifier(rawValue: item.hkIdentifier)
                )
            })
            guard !readTypes.isEmpty else { return }
            try await store.requestAuthorization(toShare: [], read: readTypes)
        }
    }

#endif
