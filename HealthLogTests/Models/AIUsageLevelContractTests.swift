import Foundation
@testable import HealthLog
import Testing

/// #129 (server v1.43) — the AI usage level: decoded from `ai.usage`, chosen
/// only among the options the server allows, written with
/// `PUT /api/auth/me/ai-usage`, and the reason `usage_level` has its sentence.
/// Fixtures follow `AiUsageState` in `docs/api/openapi.yaml` on
/// `release/v1.43.0` (`d06ce3604`).
@Suite("AI usage level (#129)", .serialized)
@MainActor
struct AIUsageLevelContractTests {
    static let meJSON = """
    {
      "modules": {},
      "ai": {
        "capabilities": {
          "coach": {"available": true, "reason": null, "onDeviceAllowed": true},
          "supplementLabel": {"available": false, "reason": "usage_level", "onDeviceAllowed": false}
        },
        "usage": {
          "level": "standard",
          "preference": "full",
          "defaultLevel": "standard",
          "maxLevel": "standard",
          "source": "admin_cap",
          "options": [
            {"level": "frugal", "allowed": true, "estimatedTokensPerDay": 1200},
            {"level": "standard", "allowed": true, "estimatedTokensPerDay": 4800},
            {"level": "full", "allowed": false, "estimatedTokensPerDay": null}
          ],
          "measuredTokensPerDay": 5100,
          "measuredDays": 7
        }
      }
    }
    """

    private func decodeMe(_ json: String = meJSON) throws -> AuthMeModules {
        try JSONDecoder.hlDefault.decode(AuthMeModules.self, from: Data(json.utf8))
    }

    @Test("ai.usage decodes beside the capabilities, supplementLabel and usage_level included")
    func decodesUsageBlock() throws {
        let me = try decodeMe()
        let usage = try #require(me.ai?.usage)
        #expect(usage.level == .standard)
        #expect(usage.preference == .full)
        #expect(usage.maxLevel == .standard)
        #expect(usage.source == .adminCap)
        #expect(usage.options.map(\.level) == [.frugal, .standard, .full])
        #expect(usage.option(.frugal)?.estimatedTokensPerDay == 1200)
        #expect(usage.option(.full)?.allowed == false)
        #expect(usage.measuredTokensPerDay == 5100)
        #expect(usage.measuredDays == 7)
        let label = try #require(me.ai?.capabilities[.supplementLabel])
        #expect(label.reason == .usageLevel)
        #expect(label.isAvailable == false)
    }

    @Test("A server without ai.usage hides the setting; a broken usage block costs nothing else")
    func absentOrBrokenUsage() throws {
        let old = try decodeMe("""
        {"modules": {}, "ai": {"capabilities": {"coach": {"available": true, "reason": null, "onDeviceAllowed": true}}}}
        """)
        #expect(old.ai?.usage == nil)
        #expect(old.ai?.state(.coach).isAvailable == true)
        let broken = try decodeMe("""
        {"modules": {}, "ai": {"capabilities": {"coach": {"available": true, "reason": null, "onDeviceAllowed": true}},
         "usage": {"level": "turbo"}}}
        """)
        #expect(broken.ai?.usage == nil)
        #expect(broken.ai?.state(.coach).isAvailable == true)
    }

    @Test("An option the server does not allow is never sendable, nor a level it did not list")
    func onlyAllowedOptionsAreSendable() throws {
        let usage = try #require(try decodeMe().ai?.usage)
        #expect(usage.canChoose(.frugal))
        #expect(usage.canChoose(.standard))
        #expect(usage.canChoose(.full) == false)
        let partial = AIUsageState(level: .frugal, options: [AIUsageOption(level: .frugal, allowed: true)])
        #expect(partial.canChoose(.standard) == false)
    }

    @Test("The PUT body names the level, and null follows the server default")
    func putBody() throws {
        let level = try JSONEncoder.hlDefault.encode(AIUsagePutRequest(level: .frugal))
        #expect(String(data: level, encoding: .utf8) == #"{"level":"frugal"}"#)
        let reset = try JSONEncoder.hlDefault.encode(AIUsagePutRequest(level: nil))
        #expect(String(data: reset, encoding: .utf8) == #"{"level":null}"#)
    }

    @Test("Each option names its estimate or why it is disabled; admin_cap and measured use get a note")
    func presentation() throws {
        let usage = try #require(try decodeMe().ai?.usage)
        let full = try #require(usage.option(.full))
        #expect(AIUsagePresentation.detail(for: full) == String(localized: "settings.ai.usage.limited"))
        let frugal = try #require(usage.option(.frugal))
        #expect(AIUsagePresentation.detail(for: frugal)?.contains(1200.formatted()) == true)
        #expect(AIUsagePresentation.detail(for: AIUsageOption(level: .standard, allowed: true)) == nil)
        let notes = AIUsagePresentation.notes(for: usage)
        #expect(notes.count == 2)
        #expect(AIUsagePresentation.notes(for: AIUsageState(level: .standard, options: [])).isEmpty)
    }

    @Test("usage_level has its own sentence on every AI surface that explains a refusal")
    func usageLevelSentence() {
        let sentence = String(localized: "ai.reason.usageLevel")
        #expect(!sentence.isEmpty)
        let refusal = AIRefusal(errorCode: "ai.usage.levelTooLow", capability: .coach, reason: .usageLevel)
        #expect(AskCoachSheet.coachRefusalCopy(refusal) == sentence)
    }

    @Test("403 ai.usage.levelTooLow is read as an AI refusal for the named capability")
    func levelTooLowIsARefusal() throws {
        let meta = APIEnvelopeMeta(errorCode: "ai.usage.levelTooLow", reason: "usage_level", capability: "supplementLabel")
        let refusal = try #require(AIRefusal.from(status: 403, meta: meta, topLevelCode: nil))
        #expect(refusal.affectedCapabilities == [.supplementLabel])
        #expect(refusal.impliedState.reason == .usageLevel)
        #expect(refusal.impliedState.allowsOnDevice == false)
    }

    @Test("A choice is written with PUT and the gate renders the answered block")
    func gateAppliesAnsweredUsage() throws {
        let me = try decodeMe()
        let gate = AICapabilityGate(account: me.ai)
        let answered = AIUsageState(
            level: .frugal, preference: .frugal, source: .user,
            options: [AIUsageOption(level: .frugal, allowed: true)]
        )
        gate.applyUsage(answered)
        #expect(gate.account?.usage == answered)
        #expect(gate.state(.coach).isAvailable == true)
    }
}
