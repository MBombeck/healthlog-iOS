import Foundation

// MARK: - Access headers without relaunch (#153)

extension AppContainer {
    /// Stores the access headers and hands them to the running client, so the
    /// next request carries them, signed in or not.
    ///
    /// Not `reloadEnvironment()`: that one re-resolves the whole environment
    /// for an address change and forgets per-host state (slot gate, server
    /// type gate). A header edit changes neither the host nor anything learned
    /// about it.
    ///
    /// - Returns: the list as stored (trimmed, empty rows dropped).
    @discardableResult
    func saveAccessHeaders(_ headers: [ServerAccessHeader]) async throws -> [ServerAccessHeader] {
        let stored = try ServerAccessHeaders.save(headers, keychain: keychain)
        environment = environment.replacingStoredAccessHeaders(stored)
        if let apiClient = api as? APIClient {
            await apiClient.setAccessHeaders(stored)
        }
        return stored
    }
}
