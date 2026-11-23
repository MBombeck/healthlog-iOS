import Foundation

extension AppContainer {
    /// The module question of the ingest-v2 units. A module map not loaded
    /// yet answers "off": nothing is read before the server said the module
    /// is on, so a refusal cannot cost a page.
    static func ingestModuleProbe(moduleGate: ModuleGate) -> @Sendable (ModuleKey) async -> Bool {
        { [weak moduleGate] key in
            await MainActor.run {
                guard let moduleGate, moduleGate.modules != nil else { return false }
                return moduleGate.isEnabled(key)
            }
        }
    }
}
