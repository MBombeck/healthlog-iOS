import Foundation
import Observation

/// `@Observable` wrapper over `PasskeyRepository` for the Settings → Security
/// passkey-management surface. Holds the registered-credential list + the
/// load/mutate lifecycle the screen renders.
///
/// **No persistence.** The list is server-authoritative and re-fetched on every
/// screen open / pull-to-refresh; nothing is cached to Keychain or
/// UserDefaults.
@MainActor
@Observable
public final class PasskeyManagementStore {
    public private(set) var passkeys: [PasskeyEntry] = []
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?

    private let repo: PasskeyRepository

    public init(repo: PasskeyRepository) {
        self.repo = repo
    }

    /// (Re)loads the registered passkeys.
    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            passkeys = try await repo.list()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Revokes a single passkey, then re-loads to reflect server truth.
    public func delete(id: String) async {
        error = nil
        do {
            try await repo.delete(id: id)
            await load()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Renames a passkey, then re-loads to reflect server truth.
    ///
    /// Guarded on the same rule the submit button uses
    /// (``WebAuthnKeyName/isValid(_:)``) so a whitespace-only name can never
    /// reach the network even if a caller skips the button state.
    ///
    /// - Returns: `true` when the rename was applied — the caller uses it to
    ///   decide whether to leave inline-edit mode.
    @discardableResult
    public func rename(id: String, name: String) async -> Bool {
        guard WebAuthnKeyName.isValid(name) else { return false }
        error = nil
        do {
            try await repo.rename(id: id, name: name)
            await load()
            return true
        } catch let err as HLError {
            error = err
            return false
        } catch {
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    /// Clears the surfaced error (alert dismissal).
    public func clearError() {
        error = nil
    }

    public func clearOnLogout() {
        passkeys = []
        error = nil
    }
}
