import Foundation

// Phase 07 Wave 3 — how an opt-in importer learns which account it works for.
//
// The sample path resolves its owner through `AppOwnedHealthCollection`, which
// the composition root installs with a closure over the Keychain and the
// Phase-06 lease registry. The opt-in importers (Apple medications, State of
// Mind) reach HealthKit through `AnyHealthKitWriter` and their own settings
// stores instead, and both of those are public seams while
// `HealthSyncAuthenticatedLease` is deliberately module-internal.
//
// This type is the one-line bridge: a public carrier whose payload is internal,
// so the public seam can pass an admission through without publishing the lease
// vocabulary. It stores no owner of its own and caches nothing — the closure is
// evaluated fresh on every sweep, exactly like the sample path's, so a sweep
// that starts after a logout refuses instead of running under the previous
// account.

/// Carries an account admission across a public seam without publishing the
/// internal lease vocabulary.
///
/// The stored closure is internal, so the memberwise initializer is internal
/// too: nothing outside this module can mint an admission, and nothing inside it
/// can read an owner out of one except by admitting a source.
public struct HealthSyncImporterAdmission: Sendable {
    let admit: @Sendable (HealthSyncSource) throws -> HealthSyncAuthenticatedLease

    /// The production admission: the signed-in user and the bearer paired with
    /// it, read once per sweep and pinned for that sweep.
    ///
    /// Fails closed on either half being missing — a signed-out process imports
    /// nothing rather than importing under whoever signed in last.
    static func keychainBound(
        keychain: KeychainStoring,
        registry: AuthenticatedSessionLeaseRegistry
    ) -> HealthSyncImporterAdmission {
        HealthSyncImporterAdmission { source in
            try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: keychain.getString(forKey: KeychainKey.userID) ?? "",
                source: source,
                bearerProvider: { keychain.getString(forKey: KeychainKey.authToken) }
            )
        }
    }

    /// A single-source provider in the shape every Phase-07 importer already
    /// takes, so an importer stores one closure rather than a source plus a
    /// carrier.
    func provider(for source: HealthSyncSource) -> @Sendable () throws -> HealthSyncAuthenticatedLease {
        let admit = admit
        return { try admit(source) }
    }

    /// Why this source cannot be admitted right now, or `nil` when it can.
    ///
    /// **Phase 07 / plan 07-07.** Every admission-gated importer already refuses
    /// on its own, and every one of them refuses *silently* — which is how a
    /// composition where admission can never succeed stayed invisible through
    /// four waves of green suites. The orchestrator asks this question once per
    /// capability so the pass aggregate can distinguish "this ran and had
    /// nothing to do" from "this was never allowed to start", and so
    /// `notAdmitted` reaches an operator instead of a log line nobody reads.
    ///
    /// It admits and discards; it never becomes anyone's owner.
    func refusal(for source: HealthSyncSource) -> HealthSyncFailureClass? {
        do {
            _ = try admit(source)
            return nil
        } catch let refusal as HealthSyncLeaseRefusal {
            switch refusal {
            case .unavailableAuthentication: return .notAdmitted
            case .staleSession: return .staleSession
            case .cancelled: return .cancelled
            }
        } catch {
            return .unknown
        }
    }
}

/// Carries a named importer outcome back across the same public seam.
///
/// Plan 07-06 gave `CycleHealthKitImporter.refresh()` and
/// `HeartHealthEventImporter.refresh()` a `HealthSyncDisposition` return value
/// and then deleted the `HealthKitService` wrappers, because nothing on the
/// public `AnyHealthKitWriter` protocol could name an internal enum and a
/// callerless wrapper is a false statement about the app. This is the other half
/// of the `HealthSyncImporterAdmission` trick, in the other direction: the
/// stored property is internal, so the memberwise initializer is internal, so
/// only this module can make a claim about what an importer did — while the
/// public protocol can carry it.
public struct HealthSyncImportOutcome: Sendable, Equatable {
    let disposition: HealthSyncDisposition

    /// The honest answer for a context with no importer: not "it worked", not
    /// "it failed", but "this build cannot run it".
    static let unsupported = HealthSyncImportOutcome(disposition: .unsupported)
    /// The importer is behind an opt-in or gate that is currently off.
    static let disabled = HealthSyncImportOutcome(disposition: .disabled)
}
