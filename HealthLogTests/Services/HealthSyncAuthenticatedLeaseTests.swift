import Foundation
@testable import HealthLog
import Synchronization
import Testing

/// Phase 07 Wave 1 — admission and revalidation for the shared health-sync lease.
///
/// The three properties this suite pins are the ones every later importer
/// depends on: admission is all-or-nothing, a change to *any* of owner /
/// generation / bearer invalidates every later validation, and cancellation is
/// a distinct refusal that can never read as acceptance.
@Suite("HealthKit sync authenticated lease")
struct HealthSyncAuthenticatedLeaseTests {
    private func makeRegistry(owner: String) -> AuthenticatedSessionLeaseRegistry {
        let registry = AuthenticatedSessionLeaseRegistry()
        _ = registry.activate(ownerID: owner)
        return registry
    }

    // MARK: - Admission

    @Test("admission pins the live bearer alongside the Phase-06 generation")
    func admissionPinsOwnerGenerationAndBearer() throws {
        let registry = AuthenticatedSessionLeaseRegistry()
        let session = try #require(registry.activate(ownerID: "account-a"))
        let lease = try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: "account-a",
            source: .speziSamples,
            bearerProvider: { "token-a" }
        )

        #expect(lease.ownerID == "account-a")
        #expect(lease.source == .speziSamples)
        #expect(lease.generation == session.generation, "Phase 07 must not mint a generation of its own")
        #expect(lease.authorizationHeader == "Bearer token-a")
        #expect(lease.isCurrent)
        #expect(lease.refusal == nil)
        try lease.requireCurrent()
    }

    @Test("a blank owner or a missing bearer fails admission")
    func blankOwnerOrMissingBearerFailsAdmission() {
        let registry = makeRegistry(owner: "account-a")

        #expect(throws: HealthSyncLeaseRefusal.unavailableAuthentication) {
            _ = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: "   ",
                source: .mood,
                bearerProvider: { "token-a" }
            )
        }
        #expect(throws: HealthSyncLeaseRefusal.unavailableAuthentication) {
            _ = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: "account-a",
                source: .mood,
                bearerProvider: { nil }
            )
        }
        #expect(throws: HealthSyncLeaseRefusal.unavailableAuthentication) {
            _ = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: "account-a",
                source: .mood,
                bearerProvider: { "   " }
            )
        }
    }

    @Test("an owner the registry does not currently hold cannot be admitted")
    func unheldOwnerCannotBeAdmitted() {
        let registry = makeRegistry(owner: "account-a")

        #expect(throws: HealthSyncLeaseRefusal.unavailableAuthentication) {
            _ = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: "account-b",
                source: .dailyStatistics,
                bearerProvider: { "token-b" }
            )
        }
    }

    // MARK: - Revalidation

    @Test("a replacement account invalidates every later validation")
    func accountReplacementInvalidatesLease() throws {
        let registry = makeRegistry(owner: "account-a")
        let lease = try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: "account-a",
            source: .dailyStatistics,
            bearerProvider: { "token-a" }
        )

        _ = registry.activate(ownerID: "account-b")

        #expect(!lease.isCurrent)
        #expect(lease.refusal == .staleSession)
        #expect(throws: HealthSyncLeaseRefusal.staleSession) {
            try lease.requireCurrent()
        }
    }

    @Test("a same-owner re-login invalidates the earlier admission")
    func sameOwnerReloginInvalidatesLease() throws {
        let registry = makeRegistry(owner: "account-a")
        let lease = try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: "account-a",
            source: .heartEvent,
            bearerProvider: { "token-a" }
        )

        _ = registry.activate(ownerID: "account-a")

        #expect(lease.refusal == .staleSession, "the generation is the only signal a same-owner re-login gives")
    }

    @Test("logout invalidates the lease even before the owner id is cleared")
    func logoutInvalidatesLease() throws {
        let registry = makeRegistry(owner: "account-a")
        let lease = try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: "account-a",
            source: .ecg,
            bearerProvider: { "token-a" }
        )

        registry.invalidate()

        #expect(lease.refusal == .staleSession)
    }

    @Test("a rotated bearer invalidates the lease while owner and generation still match")
    func rotatedBearerInvalidatesLease() throws {
        let registry = makeRegistry(owner: "account-a")
        let bearer = Mutex("token-a")
        let lease = try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: "account-a",
            source: .appleMedication,
            bearerProvider: { bearer.withLock { $0 } }
        )
        #expect(lease.isCurrent)

        bearer.withLock { $0 = "token-a-refreshed" }

        #expect(lease.refusal == .staleSession, "registry currency alone cannot see a credential rotation")
        #expect(lease.authorizationHeader == "Bearer token-a", "the admitted request stays pinned to its own bearer")
    }

    // MARK: - Cancellation is not acceptance

    @Test("cancellation is a distinct refusal and holds the cursor for its own reason")
    func cancellationIsDistinctFromStaleSession() async throws {
        let registry = makeRegistry(owner: "account-a")
        let lease = try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: "account-a",
            source: .cycle,
            bearerProvider: { "token-a" }
        )

        let refusal = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return lease.refusal
        }.value

        #expect(refusal == .cancelled)
        #expect(HealthSyncLeaseRefusal.cancelled.holdReason == .cancelled)
        #expect(HealthSyncLeaseRefusal.staleSession.holdReason == .leaseLost)
        #expect(HealthSyncLeaseRefusal.unavailableAuthentication.holdReason == .leaseLost)
        #expect(HealthSyncLeaseRefusal.allCases.count == 3, "a new refusal must choose its hold reason deliberately")
    }

    // MARK: - The mutation fence

    @Test("the fence revalidates after the suspension, not only before it")
    func fenceRevalidatesAfterTheAwait() async throws {
        let registry = makeRegistry(owner: "account-a")
        let lease = try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: "account-a",
            source: .workout,
            bearerProvider: { "token-a" }
        )

        await #expect(throws: HealthSyncLeaseRefusal.staleSession) {
            try await lease.admitting {
                // The account is replaced while the "wire call" is in flight.
                _ = registry.activate(ownerID: "account-b")
                return 1
            }
        }
    }

    @Test("the fence passes a result through while the admission stays current")
    func fencePassesResultThroughWhileCurrent() async throws {
        let registry = makeRegistry(owner: "account-a")
        let lease = try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: "account-a",
            source: .nutrient,
            bearerProvider: { "token-a" }
        )

        let value = try await lease.admitting { 42 }
        #expect(value == 42)
    }

    // MARK: - Partitioning

    @Test("a lease can only address its own owner's cursor partition")
    func leaseAddressesOnlyItsOwnPartition() throws {
        let registry = makeRegistry(owner: "account-a")
        let leaseA = try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: "account-a",
            source: .speziSamples,
            bearerProvider: { "token-a" }
        )
        _ = registry.activate(ownerID: "account-b")
        let leaseB = try HealthSyncAuthenticatedLease.admit(
            from: registry,
            ownerID: "account-b",
            source: .speziSamples,
            bearerProvider: { "token-b" }
        )

        let keyA = try #require(leaseA.cursorKey(typeIdentifier: "HKQuantityTypeIdentifierStepCount"))
        let keyB = try #require(leaseB.cursorKey(typeIdentifier: "HKQuantityTypeIdentifierStepCount"))

        #expect(keyA.storageKey != keyB.storageKey)
        #expect(!keyA.storageKey.contains("account-a"), "the owner is hashed into the key, never stored in clear")
    }
}
