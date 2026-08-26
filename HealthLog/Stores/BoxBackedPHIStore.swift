import Foundation

/// **W-PHI-HARDENING (reliability audit G5) — marker protocol for per-user PHI
/// stores that are reached through a box / computed indirection rather than a
/// stored `AppContainer` property.**
///
/// `LogoutCompletenessTests` enforces the "every PHI store is cleared on
/// logout" invariant by *reflecting over `AppContainer`'s stored properties*.
/// Box-backed stores (`coachAboutMeStore` / `miniCoachStore`, resolved through
/// ``MiniCoachBox``) are **computed** properties, so the Mirror sweep never
/// sees them — exactly the blind spot the B187 About-Me PHI leak shipped
/// through.
///
/// This protocol closes the blind spot structurally: every box-backed PHI
/// store conforms, and ``MiniCoachBox`` keeps its cached conformers in a single
/// type-erased registry that its logout `clearStores(for:)` drains. The
/// completeness suite then asserts that (a) every cached box entry IS a
/// conformer and (b) `clearStores` actually wipes each conformer — so a NEW
/// box-backed `@Observable` store holding PHI cannot ship without being wired
/// into the logout cascade, or the test goes red.
///
/// `@MainActor` because every conformer is a `@MainActor @Observable` store and
/// the wipe mutates its observable PHI state in place (a SwiftUI re-paint
/// between the wipe and the cache-drop must not flash the predecessor's data).
@MainActor
public protocol BoxBackedPHIStore: AnyObject {
    /// Wipe the store's in-memory per-user PHI back to its pristine empty
    /// state. Called by the owning box's logout `clearStores(for:)` BEFORE the
    /// cache entry is dropped. Must be idempotent.
    func clearPHIOnLogout() async
}
