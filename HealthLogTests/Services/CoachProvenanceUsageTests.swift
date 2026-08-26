import Foundation
@testable import HealthLog
import Testing

/// **CO4 / CO5 (v0154)** — pure `parseSSE` decode coverage for the two SSE
/// payloads iOS previously dropped on the floor: the `provenance` frame
/// (`metricSource`, CO4) and the `done.usage` envelope (CO5). The store-driven
/// stash tests (which need the fallback suite's API stub) live in
/// `CoachServerFallbackTests.swift`.
@Suite("Coach provenance + token usage — SSE decode")
struct CoachProvenanceUsageTests {
    // MARK: - CO4 provenance frame

    @Test("CO4 — parseSSE decodes a provenance frame (metrics/windows/counts/keyValues)")
    func parseProvenanceFrame() throws {
        // swiftlint:disable line_length
        let body = """
        data: {"type":"token","token":"Dein Schlaf ist stabil."}

        data: {"type":"provenance","metricSource":{"windows":["last30days"],"metrics":["sleep","bp"],"counts":{"sleep":12,"bp":8},"keyValues":[{"label":"Avg sleep","value":"7.2","unit":"h"}]}}

        data: {"type":"done","conversationId":"c-1","messageId":"m-1"}

        """
        // swiftlint:enable line_length
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        let provenance = try #require(reply.provenance)
        #expect(provenance.windows == ["last30days"])
        #expect(provenance.metrics == ["sleep", "bp"])
        #expect(provenance.counts?["sleep"] == 12)
        #expect(provenance.counts?["bp"] == 8)
        #expect(provenance.keyValues?.count == 1)
        let keyValue = try #require(provenance.keyValues?.first)
        #expect(keyValue.label == "Avg sleep")
        #expect(keyValue.value == "7.2")
        #expect(keyValue.unit == "h")
        #expect(provenance.isEmpty == false)
    }

    @Test("CO4 — parseSSE leaves provenance nil on a turn with no provenance frame")
    func parseNoProvenance() throws {
        let body = """
        data: {"type":"token","token":"ok"}

        data: {"type":"done","conversationId":"c","messageId":"m"}

        """
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.provenance == nil)
    }

    @Test("CO4 — parseSSE decodes a partial provenance frame (missing counts/keyValues)")
    func parseProvenancePartial() throws {
        let body = """
        data: {"type":"token","token":"ok"}

        data: {"type":"provenance","metricSource":{"windows":[],"metrics":["general"]}}

        data: {"type":"done","conversationId":"c","messageId":"m"}

        """
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        let provenance = try #require(reply.provenance)
        #expect(provenance.metrics == ["general"])
        #expect(provenance.windows.isEmpty)
        #expect(provenance.counts == nil)
        #expect(provenance.keyValues == nil)
    }

    @Test("CO4 — CoachProvenance.isEmpty is true when no metrics, windows, or keyValues")
    func provenanceIsEmpty() {
        let empty = CoachServerService.CoachProvenance(windows: [], metrics: [])
        #expect(empty.isEmpty == true)
        let withMetric = CoachServerService.CoachProvenance(windows: [], metrics: ["bp"])
        #expect(withMetric.isEmpty == false)
    }

    // MARK: - CO5 token usage

    @Test("CO5 — parseSSE decodes done.usage (totalTokens + model)")
    func parseUsageFrame() throws {
        let body = """
        data: {"type":"token","token":"ok"}

        data: {"type":"done","conversationId":"c-1","messageId":"m-1","usage":{"totalTokens":1234,"model":"gpt-4o"}}

        """
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.usage?.totalTokens == 1234)
        #expect(reply.usage?.model == "gpt-4o")
    }

    @Test("CO5 — parseSSE tolerates done.usage without a model")
    func parseUsageWithoutModel() throws {
        let body = """
        data: {"type":"token","token":"ok"}

        data: {"type":"done","conversationId":"c","messageId":"m","usage":{"totalTokens":42}}

        """
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.usage?.totalTokens == 42)
        #expect(reply.usage?.model == nil)
    }

    @Test("CO5 — parseSSE leaves usage nil on an older server (no usage key)")
    func parseNoUsage() throws {
        let body = """
        data: {"type":"token","token":"ok"}

        data: {"type":"done","conversationId":"c","messageId":"m"}

        """
        let reply = try CoachServerService.parseSSE(Data(body.utf8))
        #expect(reply.usage == nil)
    }
}
