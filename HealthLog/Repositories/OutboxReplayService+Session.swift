import Foundation

// The replay and the session its rows are sent under (#2, #6).
//
// Every row carries the account that wrote it. The pass reads the signed-in
// account again for every row, re-checks it after every pause, and binds the
// row's owner around its dispatch (`RequestOwnerBinding`), so `APIClient`
// builds no request for that row once another account is signed in.
//
// A failure that is about the session rather than the write (a 401, a lease
// that no longer matches, a session that changed) is "not yet": the row keeps
// its attempt budget and only its back-off stamp moves. Up to 1.6 each such
// pass counted an attempt, and after eight the rows waited unsent until
// "Erneut senden" or the seven-day sweep, HealthKit pages in the skip
// register until the next build.

/// What a pass needs to know about the session before it sends anything.
/// Production wires the Keychain and the refresh coordinator; `nil` (tests,
/// widget) admits every pass, as before.
public struct OutboxReplaySessionGate: Sendable {
    /// `false` when no access token is stored: the pass would only collect
    /// 401s. Renews an expired access token before it answers.
    public let admitsPass: @Sendable () async -> Bool

    public init(admitsPass: @escaping @Sendable () async -> Bool) {
        self.admitsPass = admitsPass
    }

    /// How long before its stated expiry an access token counts as expired.
    static let expiryMargin: TimeInterval = 60

    /// The production gate: a stored bearer, renewed first when its expiry
    /// has passed. A renewal that fails leaves the pass to the bearer it has;
    /// the server's answer decides, and a 401 costs no attempt.
    public static func live(
        keychain: KeychainStoring,
        now: @escaping @Sendable () -> Date = Date.init,
        refresh: @escaping @Sendable () async -> Void
    ) -> OutboxReplaySessionGate {
        OutboxReplaySessionGate {
            guard keychain.getString(forKey: KeychainKey.authToken)?.isEmpty == false else { return false }
            if isExpired(keychain.getString(forKey: KeychainKey.accessTokenExpiresAt), now: now()) {
                await refresh()
            }
            return keychain.getString(forKey: KeychainKey.authToken)?.isEmpty == false
        }
    }

    /// Whether the stored ISO-8601 expiry has passed. An unreadable or
    /// missing value is not expired: nothing says so.
    static func isExpired(_ stored: String?, now: Date) -> Bool {
        guard let stored else { return false }
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: stored)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = formatter.date(from: stored)
        }
        guard let date else { return false }
        return now.addingTimeInterval(expiryMargin) >= date
    }
}

extension OutboxReplayService {
    /// Dispatches `op` only while its owner is the signed-in account, and
    /// binds that owner to every request the dispatch builds. Runs inside the
    /// 429 pause loop, so a row that waited is checked again before it goes.
    func dispatchBoundToOwner(_ op: OutboxQueue.Operation) async throws -> String? {
        guard let owner = RequestOwnerBinding.canonical(op.ownerUserID) else {
            return try await dispatch(op)
        }
        guard RequestOwnerBinding.canonical(currentUserProvider()) == owner else {
            throw HLError.authenticatedSessionChanged
        }
        return try await RequestOwnerBinding.$owner.withValue(owner) {
            try await dispatch(op)
        }
    }

    /// A failure about the session, not about the write.
    static func isSessionTransition(_ error: Error) -> Bool {
        if error is OutboxQueue.OwnerLeaseError { return true }
        return (error as? HLError)?.isAuthenticationHold ?? false
    }

    /// The row stays as it is apart from its back-off stamp: no attempt is
    /// counted, so it can never age into the dead-letter lane or the skip
    /// register for a session that was not there.
    func onSessionTransition(_ op: OutboxQueue.Operation, now: Date) async {
        let note = Self.lastErrorKeepingUnconfirmed(op, "authentication hold")
        try? await outbox.touchAttempt(id: op.id, lastError: note)
        // Kind only — operator-grade.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.outbox.info("Op \(op.kind.rawValue, privacy: .public) held for the session — attempt not counted")
    }

    /// A sign-in: the account's own rows start their attempt budget again
    /// (rows an expired session pushed over it under an older build go out
    /// again), then the pass drains them. Parked and unconfirmed rows keep
    /// their marks; another account's rows are not touched.
    public func runAfterSignIn() async {
        if let owner = RequestOwnerBinding.canonical(currentUserProvider()) {
            let reset = await (try? outbox.resetAttempts(ownedBy: owner)) ?? 0
            if reset > 0 {
                // A count only.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.outbox.info("sign-in: \(reset, privacy: .public) row(s) start their attempt budget again")
            }
        }
        await runOnce()
    }
}
