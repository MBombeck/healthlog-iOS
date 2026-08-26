import Foundation

// MARK: - v0.5.2 A6 / Mini-Coach wiring

//
// AppContainer.swift is at its 600-line ceiling, so the Mini-Coach
// service lives in this extension. The service holds its own
// actor-bound classifier, history, and safety-filter — the container
// just owns the singleton lifetime + DI seam.
//
// **UX-surface is deferred to v0.5.2 C4-C6.** This wave (C1+C2+C3)
// ships the foundation: an actor-bound coach the eventual chat surface
// can resolve from `@Environment(\.miniCoach)` without touching this
// extension.

public extension AppContainer {
    /// Lazy-instantiated singleton — first read on the MainActor wires
    /// the service against the live feature-flag store. Cached on the
    /// associated-object box so subsequent reads return the same
    /// actor (state — conversation history etc. — persists across
    /// reads for the session, per C3).
    var miniCoachService: MiniCoachService {
        if let existing = MiniCoachBox.shared.service(for: self) {
            return existing
        }
        let created = MiniCoachService(featureFlags: featureFlagsStore.liveService())
        MiniCoachBox.shared.set(created, for: self)
        return created
    }

    /// Lazy-instantiated UI store for the Mini-Coach conversation surface
    /// (C4). Wraps ``miniCoachService`` + the in-session message log so
    /// SwiftUI views can resolve it via `@Environment(\.appContainer)`.
    /// Cached on the same `MiniCoachBox` so the conversation persists
    /// across sheet-dismissal within a single session.
    var miniCoachStore: MiniCoachStore {
        if let existing = MiniCoachBox.shared.store(for: self) {
            return existing
        }
        let created = MiniCoachStore(service: miniCoachService)
        MiniCoachBox.shared.set(created, for: self)
        return created
    }

    /// **W-B187 COACH-3** — shared driver for the coach self-context +
    /// clarifying-question loop (adopt / dismiss / remember). Lazily cached on
    /// the same `MiniCoachBox` so the Settings "About me" editor and the chat
    /// "remember this" action operate on the SAME store instance — a question
    /// adopted from chat reflects in the editor, and vice-versa, without a
    /// second GET. Wraps the container-owned `coachAboutMeRepo` (outbox-backed).
    var coachAboutMeStore: CoachAboutMeStore {
        if let existing = MiniCoachBox.shared.aboutMeStore(for: self) {
            return existing
        }
        let created = CoachAboutMeStore(repository: coachAboutMeRepo)
        MiniCoachBox.shared.set(created, for: self)
        return created
    }
}

/// MainActor-isolated cache for the lazily-instantiated Mini-Coach
/// service. We keep a separate cache (rather than an `objc`-style
/// associated object) so the storage stays Swift-native and
/// strict-concurrency-clean.
@MainActor
final class MiniCoachBox {
    static let shared = MiniCoachBox()

    /// Use ObjectIdentifier as the key — AppContainer is a class, so
    /// identity-based lookup is well-defined for its lifetime.
    private var serviceByContainer: [ObjectIdentifier: MiniCoachService] = [:]
    private var storeByContainer: [ObjectIdentifier: MiniCoachStore] = [:]
    private var aboutMeStoreByContainer: [ObjectIdentifier: CoachAboutMeStore] = [:]

    private init() {}

    func service(for container: AppContainer) -> MiniCoachService? {
        serviceByContainer[ObjectIdentifier(container)]
    }

    func set(_ service: MiniCoachService, for container: AppContainer) {
        serviceByContainer[ObjectIdentifier(container)] = service
    }

    func store(for container: AppContainer) -> MiniCoachStore? {
        storeByContainer[ObjectIdentifier(container)]
    }

    func set(_ store: MiniCoachStore, for container: AppContainer) {
        storeByContainer[ObjectIdentifier(container)] = store
    }

    func aboutMeStore(for container: AppContainer) -> CoachAboutMeStore? {
        aboutMeStoreByContainer[ObjectIdentifier(container)]
    }

    func set(_ store: CoachAboutMeStore, for container: AppContainer) {
        aboutMeStoreByContainer[ObjectIdentifier(container)] = store
    }

    /// **W-PHI-HARDENING (G5) / 06-05** — the box-backed PHI stores currently
    /// cached for `container`, type-erased to the marker protocol. This is the
    /// SINGLE, EXPLICIT collection point ``clearStores(for:)`` drains and the
    /// `LogoutCompletenessTests` box-coverage invariant inspects. A NEW
    /// box-backed `@Observable` PHI store must be (1) a ``BoxBackedPHIStore``
    /// conformer and (2) added here, or the completeness suite's exact-identity
    /// canary goes red. Plan 06-05 moved the structural `Mirror` discovery of
    /// the cache dictionaries into the TEST target
    /// (`LogoutCompletenessTests.reflectionCanaryBoxBackedStores`), so
    /// production never uses runtime reflection to know its own PHI owners —
    /// the canary still catches a fourth `…ByContainer` cache dictionary that
    /// is cached but not listed here.
    ///
    /// `MiniCoachService` is intentionally absent: its per-user PHI is the
    /// actor-side ``MiniCoachHistory``, which is dropped (not wiped in place)
    /// when the cache entry is cleared — and ``MiniCoachStore/wipe()`` already
    /// resets that history actor before the drop.
    func boxBackedPHIStores(for container: AppContainer) -> [any BoxBackedPHIStore] {
        let key = ObjectIdentifier(container)
        var stores: [any BoxBackedPHIStore] = []
        if let aboutMe = aboutMeStoreByContainer[key] { stores.append(aboutMe) }
        if let store = storeByContainer[key] { stores.append(store) }
        return stores
    }

    /// **W-B187 (AUDIT-SEC-b187 B1 + High)** — wipe + drop every cached
    /// Mini-Coach store for this container on logout.
    ///
    /// `MiniCoachBox` is the ONE per-user store cache the logout cascade did
    /// not touch (B1): the `coachAboutMeStore` / `miniCoachStore` are
    /// *computed* (box-backed) properties, invisible to the reflection-based
    /// `LogoutCompletenessTests` registry, so the leak slipped through. After
    /// an A→B account switch the cached ``CoachAboutMeStore`` kept
    /// `didLoad == true` and rendered User A's conditions / allergies /
    /// coach-focus to User B (the `if !s.didLoad` guard in
    /// `SettingsAboutMeScreen` skipped the reload), and the in-session
    /// ``MiniCoachStore`` conversation likewise stranded.
    ///
    /// We wipe the in-memory PHI of any live store FIRST (a SwiftUI re-paint
    /// between the wipe and the cache-drop below would otherwise flash the
    /// predecessor's data), then drop all three cached instances so the next
    /// user re-hydrates fresh against their own partition. The
    /// `MiniCoachService` is dropped with the store — its actor-side
    /// ``MiniCoachHistory`` carried the previous user's turns.
    func clearStores(for container: AppContainer) async {
        let key = ObjectIdentifier(container)
        // W-PHI-HARDENING (G5) — wipe every cached box-backed PHI store through
        // the single ``boxBackedPHIStores(for:)`` registry the completeness
        // suite enforces, BEFORE dropping the caches. Routing the wipe through
        // the same collection the test inspects means a new conformer added to
        // the registry is automatically cleared here too (no second edit), and
        // one that is cached but missing from the registry fails the test.
        for store in boxBackedPHIStores(for: container) {
            await store.clearPHIOnLogout()
        }
        serviceByContainer[key] = nil
        storeByContainer[key] = nil
        aboutMeStoreByContainer[key] = nil
    }
}
