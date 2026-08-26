import Foundation
import Observation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// N5.1 (v0.14.8 tech audit) — locks the Observation-tracking contract of
/// `AIConsentStore`'s externally-backed getters.
///
/// The audit's riskiest finding: `hasConsent(for:)` resolves from the Keychain
/// (untracked by Observation), so a SwiftUI body gating ONLY on `hasConsent()`
/// was never invalidated when a grant landed asynchronously — the consent gate
/// rendered stale until relaunch (the RCA-ai-consent-flow staleness class).
/// The fix anchors every externally-backed getter on the stored `revision` via
/// `trackRevisionRead()`; these tests lock that contract at the Observation
/// level (`withObservationTracking` is exactly what a SwiftUI body evaluation
/// does — each test FAILS without the in-getter revision read).
@Suite("AIConsentStore — getters are Observation-tracked (N5.1)")
@MainActor
struct AIConsentStoreObservationTests {
    @Test("a reader of ONLY hasConsent(for:) is invalidated when the grant lands")
    func hasConsentReaderInvalidatedByGrant() async {
        let store = makeStore()
        await confirmation("onChange fires for a hasConsent-only reader") { invalidated in
            withObservationTracking {
                _ = store.hasConsent(for: .anthropic)
            } onChange: {
                invalidated()
            }
            store.grant(for: .anthropic)
        }
        #expect(store.hasConsent(for: .anthropic))
    }

    @Test("an aiMode-only reader is invalidated by setMode")
    func aiModeReaderInvalidatedBySetMode() async {
        let store = makeStore()
        await confirmation("onChange fires for an aiMode-only reader") { invalidated in
            withObservationTracking {
                _ = store.aiMode
            } onChange: {
                invalidated()
            }
            store.setMode(.onDevice, activeProvider: .unconfigured)
        }
        #expect(store.aiMode == .onDevice)
    }

    @Test("a wasDeclined-only reader is invalidated by decline()")
    func wasDeclinedReaderInvalidatedByDecline() async {
        let store = makeStore()
        await confirmation("onChange fires for a wasDeclined-only reader") { invalidated in
            withObservationTracking {
                _ = store.wasDeclined(for: .anthropic)
            } onChange: {
                invalidated()
            }
            store.decline(for: .anthropic)
        }
        #expect(store.wasDeclined(for: .anthropic))
    }

    @Test("an isAnyProviderGranted-only reader is invalidated by revoke()")
    func anyProviderGrantedReaderInvalidatedByRevoke() async {
        let store = makeStore()
        store.grant(for: .anthropic)
        await confirmation("onChange fires for an isAnyProviderGranted-only reader") { invalidated in
            withObservationTracking {
                _ = store.isAnyProviderGranted()
            } onChange: {
                invalidated()
            }
            store.revoke(for: .anthropic)
        }
        #expect(store.isAnyProviderGranted() == false)
    }

    private func makeStore() -> AIConsentStore {
        AIConsentStore(keychain: InMemoryKeychain(), defaults: makeIsolatedDefaults())
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AIConsentObservationTests.\(UUID().uuidString)") ?? .standard
    }
}
