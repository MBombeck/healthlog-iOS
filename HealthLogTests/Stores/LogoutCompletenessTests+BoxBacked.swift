// Sibling of `LogoutCompletenessTests.swift` (file_length split — the
// W-PHI-HARDENING G5 box-backed / computed PHI store coverage cases live here).
// App-Target-only, so skipped in the SPM-library build.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    // MARK: - W-PHI-HARDENING (G5) — box-backed / computed PHI store coverage

    @MainActor
    extension LogoutCompletenessTests {
        /// **The blind-spot proof.** The reflection registry in the main suite
        /// (`registryClassifiesEveryStoreProperty`) walks `AppContainer`'s
        /// STORED properties via `Mirror`, so the box-backed `coachAboutMeStore`
        /// / `miniCoachStore` — *computed* properties resolving through
        /// `MiniCoachBox` — are INVISIBLE to it. This is the exact blind spot the
        /// B187 About-Me PHI leak shipped through. Pin that the stored-property
        /// sweep genuinely does NOT see them (so the box invariant below is the
        /// thing that must cover them, not a redundant second net).
        @Test("the stored-property registry is blind to the box-backed PHI stores (G5)")
        func storedPropertyRegistryIsBlindToBoxBackedStores() throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            // Resolve them so the box has live instances — they STILL must not
            // appear as stored AppContainer properties (they're computed).
            _ = container.coachAboutMeStore
            _ = container.miniCoachStore
            let stored = Self.storeTypedProperties(of: container)
            #expect(!stored.contains("coachAboutMeStore"))
            #expect(!stored.contains("miniCoachStore"))
        }

        /// **G5 box-coverage invariant.** Every box-backed PHI store currently
        /// cached for the container MUST be wiped by `MiniCoachBox.clearStores`.
        /// Routes through the SAME `boxBackedPHIStores(for:)` registry the
        /// logout cascade drains, and additionally asserts that the structural
        /// `Mirror`-discovered set equals that hand-maintained registry — so a
        /// NEW box-backed `@Observable` PHI store (a fourth `…ByContainer` cache
        /// dictionary) cannot ship without being listed + cleared, or this goes
        /// red. This is the structural close of the reflection blind spot.
        @Test("every box-backed PHI store is discovered + cleared on logout (G5)")
        func boxBackedPHIStoresAreAllClearedOnLogout() async throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            // Seed both box-backed stores with previous-user PHI.
            let aboutMe = container.coachAboutMeStore
            aboutMe.seedLoadedStateForTesting(
                aboutMe: "I cycle", conditions: "Asthma", allergies: "Latex",
                coachFocus: "Breathe easier", pendingQuestions: ["Q?"]
            )
            let chat = container.miniCoachStore
            chat.seedMessagesForTesting([
                .init(role: .user, text: "secret PHI ask"),
                .init(role: .assistant, text: "answer")
            ])

            let box = MiniCoachBox.shared
            // The registry the cascade drains is non-empty and matches the
            // structural reflection discovery (no cached PHI store is invisible
            // to the hand list — a new un-listed cache dict would diverge here).
            // 06-05: the reflection sweep is the TEST-side canary now — the
            // production box must enumerate its owners explicitly.
            let registry = box.boxBackedPHIStores(for: container)
            let reflected = Self.reflectionCanaryBoxBackedStores(of: box, for: container)
            #expect(registry.count == 2)
            #expect(
                reflected.count == registry.count,
                "a box-backed PHI cache dictionary is not in boxBackedPHIStores(for:) — wire it in (G5 blind-spot recursion)"
            )
            #expect(
                Set(registry.map { ObjectIdentifier($0) })
                    == Set(reflected.map { ObjectIdentifier($0) }),
                "structural Mirror discovery diverged from the hand-maintained registry — a new box-backed PHI store is uncovered"
            )

            await container.performFullLocalLogout(reason: .userInitiated)

            // Every previously-cached conformer is wiped in place...
            #expect(aboutMe.conditions.isEmpty)
            #expect(aboutMe.didLoad == false)
            #expect(chat.messages.isEmpty)
            // ...and the caches are dropped (fresh re-resolution).
            #expect(box.boxBackedPHIStores(for: container).isEmpty)
        }

        /// **06-05 Task 1 — test-side reflection canary for the box.** Walks the
        /// box's `[ObjectIdentifier: V]` cache dictionaries and returns every
        /// cached ``BoxBackedPHIStore`` for `container`. Lives in the TEST
        /// target so production (`AppContainer+MiniCoach.swift`) never needs
        /// runtime reflection to know its own PHI owners.
        static func reflectionCanaryBoxBackedStores(
            of box: MiniCoachBox,
            for container: AppContainer
        ) -> [any BoxBackedPHIStore] {
            let key = ObjectIdentifier(container)
            var found: [any BoxBackedPHIStore] = []
            for child in Mirror(reflecting: box).children {
                // Dictionaries aren't value-covariant; bridge through AnyObject
                // (every cache value is a class) and runtime-check the marker.
                guard let dict = child.value as? [ObjectIdentifier: AnyObject],
                      let value = dict[key],
                      let store = value as? any BoxBackedPHIStore else { continue }
                found.append(store)
            }
            return found
        }

        /// **06-05 Task 1 — exact box-backed owner canary.** The box's explicit
        /// `boxBackedPHIStores(for:)` enumeration must cover every cached
        /// box-backed PHI owner exactly once (compared against the test-side
        /// reflection sweep above), and the production MiniCoach composition
        /// must not use runtime reflection to discover them.
        @Test
        func boxBackedOwnersAreExplicitAndExactlyComplete() throws {
            let container = try makeContainer(
                keychain: InMemoryKeychain(),
                healthKit: MockHealthKitWriter()
            )
            // Resolve both box-backed stores so the box holds live instances.
            _ = container.coachAboutMeStore
            _ = container.miniCoachStore

            let box = MiniCoachBox.shared
            let explicitIDs = box.boxBackedPHIStores(for: container).map { ObjectIdentifier($0) }
            let reflectedIDs = Self.reflectionCanaryBoxBackedStores(of: box, for: container)
                .map { ObjectIdentifier($0) }
            let duplicateCount = explicitIDs.count - Set(explicitIDs).count
            let reflectionHits = LogoutCompletenessTests.productionReflectionHits(
                relativePath: "HealthLog/Stores/AppContainer+MiniCoach.swift"
            )

            #expect(
                Set(explicitIDs) == Set(reflectedIDs) && duplicateCount == 0
                    && explicitIDs.count == reflectedIDs.count
                    && reflectionHits.isEmpty,
                "EXPECTED_RED: box-backed owner membership was not exact — explicit \(explicitIDs.count), reflected \(reflectedIDs.count), duplicates \(duplicateCount), production reflection \(reflectionHits)"
            )
        }

        /// **Failing-then-fixed.** A `BoxBackedPHIStore` conformer that is cached
        /// but NOT routed through `clearStores` would survive logout — the leak.
        /// We reproduce that shape with a tiny in-test conformer and prove the
        /// invariant catches it: `clearPHIOnLogout()` empties the PHI, while a
        /// conformer left out of the cleared set keeps its PHI (the red state we
        /// guard against). With the production wiring, the two real box stores
        /// ARE in the cleared set, so they end empty (verified above).
        @Test("a box-backed PHI conformer keeps its PHI until the cascade clears it (G5 red→green)")
        func uncoveredBoxBackedConformerLeaksUntilCleared() async {
            let leakable = SpyBoxBackedPHIStore()
            leakable.phi = "User A clinical note"

            // RED: a conformer the cascade forgets to clear still holds PHI.
            #expect(leakable.phi.isEmpty == false)

            // GREEN: once it IS routed through the marker protocol — exactly what
            // `MiniCoachBox.clearStores` now does for every cached conformer via
            // `boxBackedPHIStores(for:)` — the PHI is gone.
            await leakable.clearPHIOnLogout()
            #expect(leakable.phi.isEmpty)
            #expect(leakable.didClear)
        }
    }

    /// **W-PHI-HARDENING (G5)** — minimal in-test ``BoxBackedPHIStore`` conformer
    /// standing in for a future box-backed PHI store, to prove the marker
    /// protocol's wipe contract clears in-memory PHI (the red→green case).
    @MainActor
    final class SpyBoxBackedPHIStore: BoxBackedPHIStore {
        var phi: String = ""
        private(set) var didClear = false
        func clearPHIOnLogout() async {
            phi = ""
            didClear = true
        }
    }

#endif // !SWIFT_PACKAGE
