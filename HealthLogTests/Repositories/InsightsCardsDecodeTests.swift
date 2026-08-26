import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// W-SERVER-SYNC — locks the consolidated `/api/insights/cards` contract.
///
/// The Insights screen already consumes this single endpoint (one fetch → all
/// metric cards) instead of per-metric digest fetches; the per-metric
/// `/api/insights/{metric}-status` splits stay for chart-detail granular
/// access. This suite pins the wire shape the server's `InsightCard` adapter
/// emits (id / title / summary / body / severity / recommendations /
/// generatedAt / provider) so a schema drift can never silently blank the
/// cards list. Uses the real `APIClient` + stubbed `URLProtocol` per the
/// project rule (no mock server).
@Suite("InsightsRepository.cards — consolidated cards decode", .serialized)
struct InsightsCardsDecodeTests {
    private func makeRepo() -> InsightsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return InsightsRepository(api: api)
    }

    @Test("Decodes the full server InsightCard array (severity + recommendations + provider)")
    func decodesFullCardArray() async throws {
        let body = Data(#"""
        {"data":[
            {
                "id": "alert-1",
                "title": "Blood pressure trending up",
                "summary": "Your 30-day average is above target.",
                "body": null,
                "severity": "caution",
                "recommendations": [
                    {"id": "rec-1", "label": "Review with your doctor", "actionURL": null}
                ],
                "generatedAt": "2026-05-29T08:00:00.000Z",
                "provider": "anthropic"
            },
            {
                "id": "alert-2",
                "title": "Weight stable",
                "summary": "No significant change in 90 days.",
                "body": null,
                "severity": "good",
                "recommendations": [],
                "generatedAt": "2026-05-29T08:00:00.000Z",
                "provider": "claude_haiku"
            }
        ]}
        """#.utf8)
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = makeRepo()
        let cards = try await repo.cards()

        #expect(capturedPath == "/api/insights/cards")
        #expect(cards.count == 2)

        let first = cards[0]
        #expect(first.id == "alert-1")
        #expect(first.title == "Blood pressure trending up")
        #expect(first.severity == .caution)
        #expect(first.body == nil)
        #expect(first.recommendations.count == 1)
        #expect(first.recommendations[0].label == "Review with your doctor")
        #expect(first.recommendations[0].actionURL == nil)
        #expect(first.providerLabel == "Anthropic")

        // Wide provider vocabulary must not throw the array (W2a-A2 §2.4) —
        // The wider model-family identifier is kept raw and mapped to the
        // neutral provider-family label.
        #expect(cards[1].severity == .good)
        #expect(cards[1].provider == "claude_haiku")
        #expect(cards[1].providerLabel == "Anthropic")
    }

    @Test("Empty cards array decodes to an empty list, not an error")
    func decodesEmptyArray() async throws {
        let body = Data(#"{"data":[]}"#.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = makeRepo()
        let cards = try await repo.cards()
        #expect(cards.isEmpty)
    }
}
