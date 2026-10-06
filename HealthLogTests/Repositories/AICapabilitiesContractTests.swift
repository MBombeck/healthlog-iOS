import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// #114 / #115 · 0.2 — successor of `FeatureFlagsRepositoryTests`.
///
/// `FeatureFlagsRepository` decoded an invented `{ flags: [String: Bool] }`
/// from `GET /api/feature-flags` while the server has always sent
/// `{ assistant: { … } }`, so every fetch failed and every assistant flag sat at
/// its default "on". It is gone. The operator's — and every other layer's —
/// answer now arrives as `ai` on `GET /api/auth/me` (server v1.39,
/// `src/app/api/auth/me/route.ts` → `loadAiCapabilities`; OpenAPI
/// `AiAccountBlock` / `AiCapabilities` / `AiCapabilityState` /
/// `AiProviderState`). The fixtures below are that shape.
@Suite("AI capabilities — /api/auth/me `ai` contract", .serialized, .mockURLSession)
struct AICapabilitiesContractTests {
    /// A v1.39 `/api/auth/me` body: modules + moduleAccess + the complete `ai`
    /// block (all ten capabilities, always present server-side).
    static let meV139 = #"""
    {"data":{
      "id":"u1","email":"a@example.com",
      "modules":{"insights":true,"coach":true,"labs":true,"inboundDocuments":true},
      "moduleAccess":{"insights":"enabled","coach":"enabled","labs":"enabled","inboundDocuments":"enabled"},
      "ai":{
        "capabilities":{
          "coach":{"available":false,"reason":"operator_disabled","onDeviceAllowed":false},
          "briefing":{"available":true,"reason":null,"onDeviceAllowed":true},
          "periodNarrative":{"available":true,"reason":null,"onDeviceAllowed":true},
          "statusText":{"available":false,"reason":"consent_required","onDeviceAllowed":true},
          "workoutInsights":{"available":false,"reason":"consent_required","onDeviceAllowed":true},
          "reactionLines":{"available":false,"reason":"consent_required","onDeviceAllowed":true},
          "aboutMeQuestions":{"available":false,"reason":"operator_disabled","onDeviceAllowed":false},
          "documentAi":{"available":false,"reason":"no_provider","onDeviceAllowed":true},
          "labsOcr":{"available":false,"reason":"no_provider","onDeviceAllowed":true},
          "medicationExtract":{"available":false,"reason":"user_disabled","onDeviceAllowed":false}
        },
        "provider":{"configured":true,"managedBy":"server","canConfigure":true}
      }
    },"error":null}
    """#

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func decodeMe(_ json: String) throws -> AuthMeModules {
        let envelope = try JSONDecoder.hlDefault.decode(APIEnvelope<AuthMeModules>.self, from: Data(json.utf8))
        return try #require(envelope.data)
    }

    // MARK: - Decoding

    @Test("The v1.39 `ai` block decodes every capability, reason and onDeviceAllowed")
    func decodesFullBlock() throws {
        let ai = try #require(try decodeMe(Self.meV139).ai)
        #expect(ai.capabilities.count == AICapabilityKey.allCases.count)
        #expect(ai.state(.coach) == AICapabilityState(available: false, reason: .operatorDisabled, onDeviceAllowed: false))
        #expect(ai.state(.briefing).isAvailable)
        #expect(ai.state(.statusText).reason == .consentRequired)
        #expect(ai.state(.statusText).allowsOnDevice)
        #expect(ai.state(.medicationExtract).reason == .userDisabled)
        #expect(ai.provider == AIProviderState(configured: true, managedBy: .server, canConfigure: true))
    }

    @Test("A server older than v1.39 sends no `ai`: modules still decode, `ai` is nil")
    func missingBlockIsNil() throws {
        let me = try decodeMe(#"{"data":{"id":"u1","modules":{"insights":false}},"error":null}"#)
        #expect(me.ai == nil)
        #expect(me.modules?["insights"] == false)
    }

    @Test("An unknown reason decodes to .unknown and is unavailable on the device too")
    func unknownReason() throws {
        let json = Self.meV139.replacingOccurrences(
            of: #""coach":{"available":false,"reason":"operator_disabled","onDeviceAllowed":false}"#,
            with: #""coach":{"available":false,"reason":"zz_from_the_future","onDeviceAllowed":true}"#
        )
        let ai = try #require(try decodeMe(json).ai)
        #expect(ai.state(.coach).reason == .unknown)
        #expect(!ai.state(.coach).isAvailable)
        #expect(!ai.state(.coach).allowsOnDevice)
    }

    @Test("An unknown capability key is skipped; the known ones survive")
    func unknownKeySkipped() throws {
        let json = Self.meV139.replacingOccurrences(
            of: #""capabilities":{"#,
            with: #""capabilities":{"futureThing":{"available":true,"reason":null,"onDeviceAllowed":true},"#
        )
        let ai = try #require(try decodeMe(json).ai)
        #expect(ai.capabilities.count == AICapabilityKey.allCases.count)
        #expect(ai.state(.briefing).isAvailable)
    }

    @Test("A malformed capability entry drops only that entry; a hole reads as unavailable")
    func malformedEntryDropsOnlyItself() throws {
        let json = Self.meV139.replacingOccurrences(
            of: #""briefing":{"available":true,"reason":null,"onDeviceAllowed":true}"#,
            with: #""briefing":"broken""#
        )
        let ai = try #require(try decodeMe(json).ai)
        #expect(ai.capabilities[.briefing] == nil)
        #expect(ai.state(.briefing) == .absent)
        #expect(ai.state(.coach).reason == .operatorDisabled)
    }

    @Test("A malformed `ai` block can never cost the module map")
    func malformedBlockKeepsModules() throws {
        let me = try decodeMe(#"{"data":{"modules":{"coach":false},"ai":"nonsense"},"error":null}"#)
        #expect(me.ai == nil)
        #expect(me.modules?["coach"] == false)
    }

    @Test("Unknown provider.managedBy decodes tolerantly")
    func unknownManagedBy() throws {
        let json = Self.meV139.replacingOccurrences(of: #""managedBy":"server""#, with: #""managedBy":"federation""#)
        let ai = try #require(try decodeMe(json).ai)
        #expect(ai.provider?.managedBy == .unknown)
    }

    // MARK: - Loading through the gate the app already refreshes

    @Test("ModuleGate.load applies the `ai` block to the capability gate from the same /me response")
    @MainActor
    func moduleGateLoadAppliesAI() async {
        let paths = RequestPathLog()
        MockURLProtocol.install { req in
            paths.append(req.url!.path)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(Self.meV139.utf8)
            )
        }
        let gate = AICapabilityGate()
        let moduleGate = ModuleGate(repo: ModuleGateRepository(api: makeAPI()))
        moduleGate.aiCapabilityGate = gate
        await moduleGate.load()

        #expect(gate.reportsCapabilities)
        #expect(!gate.offersEntryPoint(.coach))
        #expect(gate.isAvailable(.briefing))
        // One request, to /api/auth/me — never the retired /api/feature-flags.
        #expect(paths.all == ["/api/auth/me"])
    }

    @Test("A /me without `ai` puts the gate back into the legacy (1.0.3) reading")
    @MainActor
    func moduleGateLoadWithoutAIIsLegacy() async {
        MockURLProtocol.install { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"modules":{"insights":true}},"error":null}"#.utf8)
            )
        }
        let gate = AICapabilityGate(account: AICaps.block([.coach: AICaps.operatorDisabled]))
        let moduleGate = ModuleGate(repo: ModuleGateRepository(api: makeAPI()))
        moduleGate.aiCapabilityGate = gate
        await moduleGate.load()

        #expect(!gate.reportsCapabilities)
        for key in AICapabilityKey.allCases {
            #expect(gate.state(key) == .legacy)
        }
    }
}

/// Thread-safe request-path recorder for `MockURLProtocol` handlers.
final class RequestPathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) {
        lock.withLock { paths.append(path) }
    }

    var all: [String] {
        lock.withLock { paths }
    }
}

// swiftlint:enable force_unwrapping
