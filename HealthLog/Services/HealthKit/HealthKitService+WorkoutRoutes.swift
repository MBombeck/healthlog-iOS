import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **1.5 ROUTES (#149) — the workout-route read permission.**
    ///
    /// Asked in exactly one place: the moment the person turns "Send routes"
    /// on under Settings, Apple Health, Advanced. Never in the first sheet
    /// (``HealthKitService/workoutRouteReadTypes`` stays out of
    /// ``HealthKitService/defaultReadTypes``), never by the late-read pass
    /// after an update, never in the background. Read-only.
    public extension HealthKitService {
        func requestWorkoutRouteAuthorization() async throws {
            try await store.requestAuthorization(
                toShare: [],
                read: Self.workoutRouteReadTypes
            )
        }
    }

#endif
