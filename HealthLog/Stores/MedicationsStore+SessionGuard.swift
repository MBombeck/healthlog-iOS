import Foundation

extension MedicationsStore {
    /// Replaces the anonymous test boundary with AppContainer's shared account
    /// generation. Binding is single-shot so a store can never drift between
    /// two registries while work is in flight.
    func bindAuthenticatedSessionRegistry(
        _ registry: AuthenticatedSessionLeaseRegistry,
        ownerIDProvider: @escaping @Sendable () -> String?
    ) {
        precondition(ownsAuthenticatedSessionRegistry, "authenticated registry already bound")
        authenticatedSessionRegistry.invalidate()
        authenticatedSessionRegistry = registry
        authenticatedSessionOwnerProvider = ownerIDProvider
        ownsAuthenticatedSessionRegistry = false
    }

    /// Captures immutable account identity once, before an authenticated
    /// operation reaches its first suspension.
    func captureAuthenticatedSessionLease() -> AuthenticatedSessionLease? {
        guard let ownerID = authenticatedSessionOwnerProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !ownerID.isEmpty else
        {
            return nil
        }
        return authenticatedSessionRegistry.capture(ownerID: ownerID)
    }

    func authenticatedEffectIsCurrent(_ sessionLease: AuthenticatedSessionLease?) -> Bool {
        sessionLease?.isCurrent == true
    }

    /// Headless stores need a fresh anonymous generation after logout so later
    /// tests/previews still operate while every pre-clear lease stays stale.
    func rotateOwnedAuthenticatedSessionBoundary() {
        guard ownsAuthenticatedSessionRegistry else { return }
        authenticatedSessionRegistry.invalidate()
        authenticatedSessionRegistry.activate(ownerID: "_anonymous")
    }

    func awaitAuthenticatedSessionQuiescence() async {
        let tasks = [medicationsFanoutTask, complianceRefreshTask].compactMap { $0 }
        for task in tasks {
            await task.value
        }
    }
}
