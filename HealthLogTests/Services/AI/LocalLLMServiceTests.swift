import Foundation
@testable import HealthLog
import Testing

/// v0.5.7 G.1 smoke coverage for `LocalLLMService`.
///
/// G.1 ships scaffolding only — the service exposes Apple
/// FoundationModels' `SystemLanguageModel.default.availability` through a
/// stable enum so the AskCoach hero kill-card has a single source of
/// truth. The actual `prepare()` + `respond(_:)` wiring lands in G.3.
///
/// **Scope of this suite:**
/// 1. The service must instantiate without throwing on every supported
///    runtime (iOS 18+ in the package; iOS 26.5 sim during CI today).
/// 2. The `availability` reader must return one of the documented
///    enum cases — never an out-of-band value. This pins the
///    `SystemLanguageModel.Availability` ↔ `LocalLLMService.Availability`
///    mapping so future Apple-added unavailable-reasons collapse to the
///    fail-closed `.deviceNotEligible` branch instead of escaping the
///    switch.
/// 3. `isReady` must agree with the `availability == .available` case.
///
/// Integration with the SpeziLLM `LLMRunner` lookup path is covered by
/// the existing `HealthLogSpeziDelegateTests` suite once G.3 wires the
/// async `prepare()` call.
@MainActor
@Suite("LocalLLMService — availability enum + init smoke")
struct LocalLLMServiceTests {
    @Test("service instantiates without throwing on every supported runtime")
    func serviceInitDoesNotThrow() {
        // Pure init path — the FoundationModels probe runs once
        // synchronously. On iOS 18 / 25 it returns `.unsupported`; on
        // iOS 26+ sims without Apple Intelligence enabled it returns
        // `.appleIntelligenceNotEnabled`; on an eligible device with
        // the model downloaded it returns `.available`. All branches
        // collapse to a no-throw construction.
        _ = LocalLLMService()
    }

    @Test("availability reader returns one of the documented enum cases")
    func availabilityIsWellFormed() {
        let service = LocalLLMService()
        let value = service.availability
        let knownCases: Set<LocalLLMService.Availability> = [
            .available,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .deviceNotEligible,
            .unsupported
        ]
        // Set-membership doubles as documentation: the kill-card branches
        // need to handle every case in this set, full stop. If Apple
        // adds a new `UnavailableReason`, the `@unknown default` branch
        // in `LocalLLMService.map(unavailableReason:)` collapses it to
        // `.deviceNotEligible` — this test stays green and the kill-card
        // stays safe (no "ready" badge while the model is actually
        // blocked for an unknown reason).
        #expect(knownCases.contains(value))
    }

    @Test("isReady mirrors availability == .available")
    func isReadyMatchesAvailability() {
        let service = LocalLLMService()
        let expected = service.availability == .available
        #expect(service.isReady == expected)
    }

    @Test("refresh() is a safe no-throw call on every runtime")
    func refreshDoesNotThrow() {
        let service = LocalLLMService()
        service.refresh()
        // Sanity: after refresh, the reader still returns one of the
        // documented cases (i.e. the re-probe path doesn't escape into
        // an undefined state).
        let knownCases: Set<LocalLLMService.Availability> = [
            .available,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
            .deviceNotEligible,
            .unsupported
        ]
        #expect(knownCases.contains(service.availability))
    }
}
