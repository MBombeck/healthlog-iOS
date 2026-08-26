import Foundation
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

#if canImport(AuthenticationServices)

    public protocol ASPresentationAnchorProvider: Sendable {
        @MainActor func anchor() -> ASPresentationAnchor
    }

    /// MainActor-isoliert, weil `ASAuthorizationController` und `ASPresentationAnchor`
    /// (UIWindow) UIKit-bound sind. Caller muss aus MainActor-Kontext aufrufen oder
    /// `await` die implizite Hop akzeptieren.
    public protocol PasskeyServiceProtocol: Sendable {
        @MainActor func register(
            challenge: String,
            rpId: String,
            rpName: String,
            userID: String,
            userName: String,
            displayName: String,
            anchor: ASPresentationAnchorProvider
        ) async throws -> PasskeyRegistration

        @MainActor func assert(
            challenge: String,
            rpId: String,
            allowCredentialIDs: [String],
            anchor: ASPresentationAnchorProvider
        ) async throws -> PasskeyAssertion
    }

    public struct PasskeyRegistration: Sendable {
        public let credentialID: String
        public let clientDataJSON: String
        public let attestationObject: String

        public init(credentialID: String, clientDataJSON: String, attestationObject: String) {
            self.credentialID = credentialID
            self.clientDataJSON = clientDataJSON
            self.attestationObject = attestationObject
        }
    }

    public struct PasskeyAssertion: Sendable {
        public let credentialID: String
        public let clientDataJSON: String
        public let authenticatorData: String
        public let signature: String
        public let userHandle: String?

        public init(
            credentialID: String,
            clientDataJSON: String,
            authenticatorData: String,
            signature: String,
            userHandle: String?
        ) {
            self.credentialID = credentialID
            self.clientDataJSON = clientDataJSON
            self.authenticatorData = authenticatorData
            self.signature = signature
            self.userHandle = userHandle
        }
    }

#endif
