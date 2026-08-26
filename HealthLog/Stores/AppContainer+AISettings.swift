import Foundation

// MARK: - Build 6 / Item 6.6 — Coach/AI privacy settings wiring

//
// The Coach/AI privacy flags (`documentsAutoAiRead`, `insightsPrivacyMode`) are
// surfaced on `SettingsCoachScreen`. Following the `coachAboutMeStore` /
// `miniCoachStore` precedent, the store is exposed as a lazily-instantiated,
// box-cached COMPUTED property rather than a stored one — AppContainer.swift is
// already over its file-length budget, and a computed property keeps this
// self-contained. Cached on an identity-keyed box so the surface resolves the
// same `@Observable` instance across navigations within a session.
//
// The repository is a cheap `actor` over the shared, pinned `APIClient` (`api`);
// it is built once with the store and captured by the box entry.

public extension AppContainer {
    /// Shared driver for the Coach/AI privacy controls. Lazily created on first
    /// read and cached for the container's lifetime. Wiped on logout via
    /// ``AICoachSettingsBox/clearStore(for:)`` so the next user on a shared
    /// device never inherits the previous user's flags before their own load.
    var aiCoachSettingsStore: AICoachSettingsStore {
        if let existing = AICoachSettingsBox.shared.store(for: self) {
            return existing
        }
        // Build 9 (9.2) — inject `moduleGate` so a disable-coach toggle can
        // optimistically flip the `coach` module surface without a `/me` refresh.
        let created = AICoachSettingsStore(
            repo: AICoachSettingsRepository(api: api),
            moduleGate: moduleGate
        )
        AICoachSettingsBox.shared.set(created, for: self)
        return created
    }
}

/// MainActor-isolated identity-keyed cache for the lazily-instantiated
/// ``AICoachSettingsStore`` (mirrors `MiniCoachBox`). Kept separate from
/// `MiniCoachBox` so this item never touches that box's logout-completeness
/// reflection invariants — this store holds preference flags, not PHI.
@MainActor
final class AICoachSettingsBox {
    static let shared = AICoachSettingsBox()

    private var storeByContainer: [ObjectIdentifier: AICoachSettingsStore] = [:]

    private init() {}

    func store(for container: AppContainer) -> AICoachSettingsStore? {
        storeByContainer[ObjectIdentifier(container)]
    }

    func set(_ store: AICoachSettingsStore, for container: AppContainer) {
        storeByContainer[ObjectIdentifier(container)] = store
    }

    /// Reset the live store's in-memory flags, then drop the cache entry so the
    /// next user re-hydrates fresh against their own session.
    func clearStore(for container: AppContainer) {
        let key = ObjectIdentifier(container)
        storeByContainer[key]?.clearOnLogout()
        storeByContainer[key] = nil
    }
}
