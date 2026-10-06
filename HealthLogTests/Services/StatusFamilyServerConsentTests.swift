import Foundation
@testable import HealthLog
import Testing

/// **#115 B7 — the status family's client consent gate is coupled to the `ai` block.**
///
/// Server v1.39 resolves consent for the per-metric status notes itself: the
/// `statusText` capability reads `consent_required` and the route answers
/// `text: null` (`src/lib/insights/status-cache.ts`, `statusTextServable`). A
/// client gate on top only duplicates that, and blocks the read outright when
/// the consent was given on another device. Servers older than v1.39 send no
/// `ai` block and do not resolve consent for these routes, so for them the
/// client gate stays exactly as it was (B1: without `ai`, 1.0.3 behaviour).
@Suite("#115 B7 — status family consent follows the server when it reports ai")
struct StatusFamilyServerConsentTests {
    private actor Hits {
        private(set) var count = 0
        var none: Bool {
            count < 1
        }

        func hit() {
            count += 1
        }
    }

    private static func repo(
        consentOpen: Bool,
        capabilities: any AICapabilityReading,
        hits: Hits
    ) async -> MetricInsightsRepository {
        let api = StubAPIClient()
        await api.setHandler { _ in
            await hits.hit()
            return MetricStatusDTO(hasProvider: true, text: nil, cached: false, updatedAt: nil)
        }
        return MetricInsightsRepository(
            api: api,
            consentGate: { consentOpen },
            aiCapabilities: capabilities
        )
    }

    @Test("with an ai block a closed client gate no longer blocks the read; the server answers")
    func aiBlockLetsTheServerDecide() async throws {
        let hits = Hits()
        let repo = await Self.repo(
            consentOpen: false,
            capabilities: AICaps.reader([.statusText: AICaps.consentRequired]),
            hits: hits
        )

        let result = try await repo.fetch(metric: .bloodPressure, locale: "de")

        #expect(await hits.count == 1)
        #expect(result?.text == nil, "the server's text:null is what the card sees, not a client-side nil")
        #expect(result?.hasProvider == true)
    }

    @Test("without an ai block (server older than v1.39) the client gate still holds")
    func legacyServerKeepsTheClientGate() async throws {
        let hits = Hits()
        let repo = await Self.repo(consentOpen: false, capabilities: FixedAICapabilities(nil), hits: hits)

        let result = try await repo.fetch(metric: .bloodPressure, locale: "de")

        #expect(await hits.none, "an older server does not resolve consent for this route")
        #expect(result == nil)
    }

    @Test("a refusal mirrored on an older server does not count as the server reporting ai")
    @MainActor
    func refusalOverridesAreNotAnAIBlock() {
        let gate = AICapabilityGate()
        gate.applyRefusal(AIRefusal(
            errorCode: "assistant.disabled.statusText",
            capability: .statusText,
            reason: .operatorDisabled
        ))
        #expect(gate.reader.state(.statusText).isAvailable == false, "the override is mirrored")
        #expect(gate.reader.reportsCapabilities == false, "but no ai block arrived")

        gate.apply(AICaps.block())
        #expect(gate.reader.reportsCapabilities == true)

        gate.clearOnLogout()
        #expect(gate.reader.reportsCapabilities == false)
    }

    @Test("chart detail: the composed gate opens once the server reports ai, and only then")
    @MainActor
    func chartDetailGateFollowsTheAIBlock() {
        let capabilities = AICapabilityGate()
        let gate = AppContainer.statusFamilyConsentGate(capabilities: capabilities, consentGate: { false })

        #expect(gate() == false, "older server: the client consent receipt still decides")

        capabilities.apply(AICaps.block([.statusText: AICaps.consentRequired]))
        #expect(gate() == true, "v1.39: the server resolves consent and answers text:null")

        capabilities.apply(nil)
        #expect(gate() == false)
    }

    @Test("chart detail: an open client gate stays open on an older server")
    @MainActor
    func chartDetailGateLegacyOpen() {
        let gate = AppContainer.statusFamilyConsentGate(capabilities: AICapabilityGate(), consentGate: { true })
        #expect(gate() == true)
    }
}
