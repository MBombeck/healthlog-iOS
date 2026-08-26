import Foundation

// Phase 07 Wave 1 — the admission fence every HealthKit operation passes.
//
// Wave 0 named the identity half of the problem: `HealthSyncOwnerLease`
// forwards Phase-06's owner and generation and deliberately mints no counter of
// its own. This file adds the second half an importer needs — the *bearer* that
// was live at admission — and pins it for the whole operation.
//
// Both halves are required, and neither is sufficient:
//
//   * Registry currency alone misses a token rotation. The owner id is stable
//     across a refresh, so an operation admitted before the rotation would keep
//     validating while its captured credential no longer exists.
//   * Bearer equality alone misses a same-owner re-login. Phase 06 advances the
//     generation on every `activate`, which is the only signal that the session
//     the operation was admitted into has been replaced.
//
// The bearer is read exactly once, at admission. Afterwards the provider is
// consulted only to compare against the pinned value — never to *choose* an
// owner for a request, a cursor write, or a reset. A path that re-reads the
// ambient Keychain after suspension is precisely the account-A-writes-into-B
// defect Phase 06 closed for the workout and ECG routes.
//
// The type is a plain `Sendable` struct over two `Sendable` closures: no
// `@unchecked Sendable`, no `assumeIsolated`, no second registry.

/// Why a HealthKit operation was refused.
///
/// `cancelled` is deliberately its own case. A cancelled page is *not* a
/// terminally accepted page: both refuse to authorize a mutation, but they hold
/// the cursor for different reasons and a diagnostic that conflates them cannot
/// tell an app suspension apart from an account switch.
enum HealthSyncLeaseRefusal: String, Error, Sendable, Equatable, CaseIterable {
    /// The work was cancelled (task cancellation, trigger budget exhausted, app
    /// suspended). Never terminal acceptance.
    case cancelled
    /// Owner, session generation, or the pinned bearer moved on since admission.
    case staleSession
    /// Admission itself was refused: no owner, or no bearer paired with it.
    case unavailableAuthentication

    /// How a page carrying this refusal must treat its cursor.
    ///
    /// Both values hold, so a refusal can never be mistaken for progress; the
    /// distinction survives into the commit decision for diagnosis.
    var holdReason: HealthSyncHoldReason {
        switch self {
        case .cancelled: .cancelled
        case .staleSession, .unavailableAuthentication: .leaseLost
        }
    }
}

/// One admitted HealthKit operation: the Phase-06 owner lease plus the bearer
/// that was live when the operation was admitted.
///
/// Captured before the first suspension point and revalidated before every
/// wire call, durable enqueue, cursor write, cache write, and reset. The
/// `admitting(_:)` fence exists so "revalidate on both sides" is one call
/// instead of a convention every importer re-implements.
struct HealthSyncAuthenticatedLease: Sendable {
    /// The Phase-06 identity this operation belongs to. Phase 07 adds nothing
    /// to it — owner and generation are forwarded verbatim.
    let owner: HealthSyncOwnerLease

    /// The credential generation captured at admission. Never persisted, never
    /// logged, never used to *derive* an owner — only compared.
    private let pinnedBearer: String

    /// Reads the currently stored bearer. Used solely for the equality check
    /// above; the value it returns can never become this operation's owner.
    private let liveBearer: @Sendable () -> String?

    var ownerID: String {
        owner.ownerID
    }

    var generation: UInt64 {
        owner.generation
    }

    var source: HealthSyncSource {
        owner.source
    }

    /// The exact `Authorization` value the admitted request must carry, so an
    /// `APIClient` 401 recovery cannot rebuild the envelope with a replacement
    /// account's credential.
    var authorizationHeader: String {
        "Bearer \(pinnedBearer)"
    }

    /// `nil` while this admission may still authorize an effect.
    var refusal: HealthSyncLeaseRefusal? {
        if Task.isCancelled { return .cancelled }
        guard owner.isCurrent else { return .staleSession }
        guard Self.canonical(liveBearer()) == pinnedBearer else { return .staleSession }
        return nil
    }

    var isCurrent: Bool {
        refusal == nil
    }

    func requireCurrent() throws {
        if let refusal { throw refusal }
    }

    /// The cursor partition this admission may write. Owner-bound by
    /// construction rather than by convention: there is no API on this type
    /// that yields another account's key.
    func cursorKey(typeIdentifier: String) -> HealthSyncCursorKey? {
        owner.cursorKey(typeIdentifier: typeIdentifier)
    }

    /// Runs `body` only while the admission is current, and revalidates after
    /// it returns.
    ///
    /// The trailing check is the one that matters: `body` is where the
    /// suspension lives, and an account replacement that lands *during* the
    /// await must invalidate the result rather than let it commit.
    func admitting<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try requireCurrent()
        let value = try await body()
        try requireCurrent()
        return value
    }

    /// Captures the live owner/generation from the Phase-06 registry and pins
    /// the bearer paired with it.
    ///
    /// Fails closed when either half is missing — a blank owner, or a bearer
    /// that logout has already removed while the user-id write has not yet
    /// completed. There is no partial admission.
    static func admit(
        from registry: AuthenticatedSessionLeaseRegistry,
        ownerID: String,
        source: HealthSyncSource,
        bearerProvider: @escaping @Sendable () -> String? = OutboxQueue.defaultAuthTokenProvider
    ) throws -> HealthSyncAuthenticatedLease {
        let owner = canonical(ownerID)
        let bearer = canonical(bearerProvider())
        guard !owner.isEmpty, !bearer.isEmpty else {
            throw HealthSyncLeaseRefusal.unavailableAuthentication
        }
        guard let session = HealthSyncOwnerLease.capture(from: registry, ownerID: owner, source: source) else {
            throw HealthSyncLeaseRefusal.unavailableAuthentication
        }
        return HealthSyncAuthenticatedLease(
            owner: session,
            pinnedBearer: bearer,
            liveBearer: bearerProvider
        )
    }

    private static func canonical(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
