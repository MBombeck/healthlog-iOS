import Foundation

// Moved out of `AuthStore.swift` (file_length-Disziplin, PROJECT_GUIDE.md).
// The store passed 1,000 lines — SwiftLint's `file_length` **error** ceiling,
// not its warning one — when 13-02 added the password-fallback observable to
// the type body, where an `@Observable` stored property has to live. These
// four pass-throughs need no private state, so they are what moves. Pure
// relocation: no signature, no body and no call site changed.

public extension AuthStore {
    /// Async pass-throughs used by onboarding to expose only server-supported
    /// registration and SSO doors.
    func isRegistrationEnabled() async -> Bool {
        await auth.registrationEnabled()
    }

    func fetchOidcStatus() async -> OidcStatus {
        await auth.oidcStatus()
    }

    func isWebLoginAvailable() async -> Bool {
        await auth.webLoginAvailable()
    }

    /// 13-02 — the tri-state the auth step needs. The `Bool` above cannot say
    /// "not asked yet", and the first render of `ServerAuthStep` happens while
    /// the answer is still in flight. `internal`, not `public`: the tri-state
    /// is an onboarding-surface vocabulary and has no business in the module's
    /// public face.
    internal func webLoginAvailability() async -> WebLoginAvailability {
        await isWebLoginAvailable() ? .available : .unavailable
    }
}
