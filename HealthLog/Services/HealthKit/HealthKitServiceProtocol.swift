import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    // MARK: - HealthKitServiceProtocol

    /// v0.5.5 Phase A.2 — canonical seam for the HealthKit service surface.
    ///
    /// Phase A.2 extracts this protocol so the Spezi-backed implementation
    /// (`HealthLogStandard` plus `SpeziHealthKit` configuration) can plug in
    /// behind the same seam in Phase A.3+. Inherits from `AnyHealthKitWriter`
    /// so existing stores that only need the writer slice (Measurements,
    /// Mood, BackgroundSync) keep their lighter dependency surface; HealthKit-
    /// aware call-sites (HKReadiness, Onboarding) get the broader API
    /// without resorting to `as? HealthKitService` casts.
    ///
    /// Members declared here must be `nonisolated` whenever possible — the
    /// underlying `HKHealthStore` authorization-status APIs are documented
    /// thread-safe by Apple, and async-hopping just to read a status would
    /// add latency for no concurrency benefit. Writes + observations stay
    /// `async` so the conforming actor (`HealthKitService`) keeps its
    /// isolation guarantees.
    public protocol HealthKitServiceProtocol: AnyHealthKitWriter {
        // MARK: Capability + status

        func isAvailable() -> Bool
        func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus

        /// Batched status read. `nonisolated` mirror of `authorizationStatus`,
        /// used by `HKReadinessStore.refresh()` so the readiness model can
        /// snapshot every Write-Type in a single pass without per-call actor
        /// hops.
        func authorizationStatuses(for types: Set<HKSampleType>) -> [String: HKReadinessStore.AuthStatus]

        // MARK: Authorization

        func requestAuthorization(read: Set<HKObjectType>, write: Set<HKSampleType>) async throws

        /// Resets the "type was disabled at HK level on first try" tracking
        /// (F8 hotfix v0.4.1.1). Called after a successful re-authorization
        /// so observers for previously-denied-then-allowed types attempt
        /// again immediately, without waiting for the next cold-start.
        func resetAuthDisabledTypes() async

        /// **25-02 (E-2026-08-29 #5)** —
        /// `HKHealthStore.getRequestStatusForAuthorization(toShare:read:)`
        /// behind the seam: whether presenting the request sheet is still
        /// necessary for the given sets. The ONE status API that accepts READ
        /// types: it answers answered-vs-open for the whole set (grant and
        /// deny both count as answered) and never the grant itself, which iOS
        /// reveals for write types only. Defaulted in the extension below so
        /// existing test doubles compile unchanged and fail closed.
        func authorizationRequestStatus(
            toShare: Set<HKSampleType>,
            read: Set<HKObjectType>
        ) async -> HKAuthorizationRequestStatus

        // MARK: Default type-sets (instance accessors)

        /// Default HK Read-Types covered by the service. Instance-level
        /// accessor (not static-on-protocol) so the seam stays mockable in
        /// tests without conditional-typing dances. Concrete implementations
        /// forward to their own static `defaultReadTypes` when applicable.
        func defaultReadTypes() -> Set<HKObjectType>

        /// Default HK Write-Types covered by the service. See
        /// ``defaultReadTypes()`` for the rationale on the instance-level
        /// indirection.
        func defaultWriteTypes() -> Set<HKSampleType>

        // MARK: Direct write + observation (already on Writer slice)

        func writeMeasurement(_ measurement: Measurement) async throws
        func writeMoodEntry(_ entry: MoodEntry) async throws
        func startBackgroundDeliveries() async throws
    }

    public extension HealthKitServiceProtocol {
        /// Fail-closed default for seams that cannot ask the system (test
        /// doubles, hermetic worlds): `.unknown`. Callers fall back to their
        /// state rule and never suppress a surface on an unanswered question.
        func authorizationRequestStatus(
            toShare _: Set<HKSampleType>,
            read _: Set<HKObjectType>
        ) async -> HKAuthorizationRequestStatus {
            .unknown
        }
    }

#endif
