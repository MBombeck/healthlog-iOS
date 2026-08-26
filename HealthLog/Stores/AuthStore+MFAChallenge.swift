import Foundation

/// #37 — the observable second-factor challenge. Kept outside the primary type
/// body so the release lint gate holds the store below its structural size
/// ceiling; the nested name `AuthStore.MfaChallenge` is unchanged.
public extension AuthStore {
    /// Non-nil drives the MFA sheet on the auth step. Carries only the offered
    /// ``MfaMethod`` list; the single-use ticket itself is held privately
    /// (sensitive) in the store and never exposed.
    struct MfaChallenge: Equatable, Sendable {
        public let methods: [MfaMethod]

        public init(methods: [MfaMethod]) {
            self.methods = methods
        }

        /// True iff TOTP / recovery (the universal codes path) is offered. The
        /// server always includes at least one of these; the flag guards the
        /// "use a recovery code" affordance.
        public var offersRecovery: Bool {
            methods.contains(.recovery)
        }

        /// True iff a WebAuthn security key is an option. The view additionally
        /// gates the affordance on the default passkey host (RP binding).
        public var offersWebAuthn: Bool {
            methods.contains(.webauthn)
        }
    }
}
