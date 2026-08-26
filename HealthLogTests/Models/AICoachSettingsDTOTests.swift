import Foundation
@testable import HealthLog
import Testing

/// **Build 6 / Item 6.6 — Coach/AI privacy DTO contract.**
///
/// Pins the two server-owned flags' wire shapes (`documentsAutoAiRead`,
/// `insightsPrivacyMode`/`privacyMode`) as pure decode/roundtrip units — no
/// network. The tolerant-decode cases are the point: a payload that OMITS the
/// field must resolve to the server's own default rather than throwing, so an
/// older server (or a partial payload) never crashes the settings surface.
@Suite("AICoachSettingsDTO")
struct AICoachSettingsDTOTests {
    private let decoder = JSONDecoder.hlDefault
    private let encoder = JSONEncoder.hlDefault

    // MARK: - documentsAutoAiRead

    @Test("documentsAutoAiRead decodes the explicit value")
    func documentsDecodesExplicit() throws {
        let on = try decoder.decode(
            DocumentsAutoAiReadDTO.self,
            from: Data(#"{"documentsAutoAiRead":true}"#.utf8)
        )
        #expect(on.documentsAutoAiRead == true)

        let off = try decoder.decode(
            DocumentsAutoAiReadDTO.self,
            from: Data(#"{"documentsAutoAiRead":false}"#.utf8)
        )
        #expect(off.documentsAutoAiRead == false)
    }

    @Test("documentsAutoAiRead tolerates a missing field → OFF default, no crash")
    func documentsToleratesMissing() throws {
        let dto = try decoder.decode(DocumentsAutoAiReadDTO.self, from: Data("{}".utf8))
        // Server contract is OFF-by-default; a partial payload must resolve there.
        #expect(dto.documentsAutoAiRead == false)
    }

    @Test("documentsAutoAiRead survives an encode→decode roundtrip")
    func documentsRoundtrip() throws {
        let original = DocumentsAutoAiReadDTO(documentsAutoAiRead: true)
        let data = try encoder.encode(original)
        let back = try decoder.decode(DocumentsAutoAiReadDTO.self, from: data)
        #expect(back == original)
    }

    @Test("documentsAutoAiRead PATCH body carries the boolean")
    func documentsWriteBody() throws {
        let data = try encoder.encode(DocumentsAutoAiReadWrite(documentsAutoAiRead: true))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["documentsAutoAiRead"] as? Bool == true)
        #expect(json.count == 1)
    }

    // MARK: - insightsPrivacyMode

    @Test("insightsPrivacyMode decodes both server tokens")
    func insightsDecodesTokens() throws {
        let aggregated = try decoder.decode(
            InsightsPrivacySettingsDTO.self,
            from: Data(#"{"privacyMode":"aggregated"}"#.utf8)
        )
        #expect(aggregated.privacyMode == .aggregated)

        let raw = try decoder.decode(
            InsightsPrivacySettingsDTO.self,
            from: Data(#"{"privacyMode":"raw"}"#.utf8)
        )
        #expect(raw.privacyMode == .raw)
    }

    @Test("insightsPrivacyMode ignores the wide GET payload's extra keys")
    func insightsIgnoresExtraKeys() throws {
        // The real GET /api/insights/settings returns connection status, admin-key
        // presence, etc. alongside `privacyMode` — the DTO must decode only its
        // own field and ignore the rest.
        let payload = """
        {"connectionStatus":"disconnected","connectedAt":null,"hasAdminKey":true,\
        "oauthConfigured":false,"centralProviderAvailable":false,"useCentralProvider":false,\
        "privacyMode":"raw","lastInsightAt":null}
        """
        let dto = try decoder.decode(InsightsPrivacySettingsDTO.self, from: Data(payload.utf8))
        #expect(dto.privacyMode == .raw)
    }

    @Test("insightsPrivacyMode tolerates a missing field → aggregated default")
    func insightsToleratesMissing() throws {
        let dto = try decoder.decode(InsightsPrivacySettingsDTO.self, from: Data("{}".utf8))
        #expect(dto.privacyMode == .aggregated)
    }

    @Test("insightsPrivacyMode tolerates an unknown token → aggregated default, no crash")
    func insightsToleratesUnknownToken() throws {
        // A future server mode this build doesn't know must fall back to the safe
        // default rather than throwing.
        let dto = try decoder.decode(
            InsightsPrivacySettingsDTO.self,
            from: Data(#"{"privacyMode":"experimental-future-mode"}"#.utf8)
        )
        #expect(dto.privacyMode == .aggregated)
    }

    @Test("insightsPrivacyMode PUT body carries the raw-value token")
    func insightsWriteBody() throws {
        let data = try encoder.encode(InsightsPrivacyModeWrite(privacyMode: .raw))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["privacyMode"] as? String == "raw")
        #expect(json.count == 1)
    }

    @Test("InsightsPrivacyMode raw values match the server enum exactly")
    func modeRawValuesMatchServer() {
        // Server zod guard: ["aggregated", "raw"]. Drift here = a 422 on write.
        #expect(InsightsPrivacyMode.aggregated.rawValue == "aggregated")
        #expect(InsightsPrivacyMode.raw.rawValue == "raw")
        #expect(InsightsPrivacyMode.allCases.count == 2)
    }
}
