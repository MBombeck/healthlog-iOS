import Foundation
@testable import HealthLog
import Testing

/// Locks the AI-Provider model surface: enum wire-mapping, config resolution,
/// and the `String??` PATCH encoder semantics. These are the contracts the
/// M2-A3 audit said the previous version got wrong on every axis — keeping
/// them under test is non-negotiable.
@Suite("AIProvider model contracts")
struct AIProviderModelTests {
    // MARK: - Enum wire mapping

    @Test(
        "fromWire round-trips every server enum value",
        arguments: [
            ("ANTHROPIC", AIProvider.anthropic),
            ("OPENAI", .openai),
            ("LOCAL", .local)
        ]
    )
    func fromWireKnownValues(raw: String, expected: AIProvider) {
        let resolved = AIProvider.fromWire(raw)
        #expect(resolved == expected)
        #expect(resolved?.wireValue == raw)
    }

    @Test("fromWire nil and empty both resolve to .unconfigured")
    func fromWireEmpty() {
        #expect(AIProvider.fromWire(nil) == .unconfigured)
        #expect(AIProvider.fromWire("") == .unconfigured)
    }

    @Test("fromWire returns nil for genuinely unknown providers")
    func fromWireUnknown() {
        #expect(AIProvider.fromWire("MISTRAL") == nil)
        #expect(AIProvider.fromWire("UNSUPPORTED_OAUTH") == nil)
        #expect(AIProvider.fromWire("anthropic") == nil) // case-sensitive — server is uppercase
    }

    @Test(".unconfigured wire value is nil so server clears the column")
    func unconfiguredWireIsNull() {
        #expect(AIProvider.unconfigured.wireValue == nil)
    }

    @Test("configurableCases contains exactly the three real iOS-configurable providers")
    func configurableCases() {
        // Server-only provider modes without a configure-and-save flow stay
        // out of the picker.
        let cases = AIProvider.configurableCases
        #expect(cases.count == 3)
        #expect(cases.contains(.anthropic))
        #expect(cases.contains(.openai))
        #expect(cases.contains(.local))
        #expect(!cases.contains(.unconfigured))
    }

    @Test("supportsBaseUrl is LOCAL-only")
    func supportsBaseUrl() {
        #expect(AIProvider.local.supportsBaseUrl == true)
        for other in AIProvider.allCases where other != .local {
            #expect(other.supportsBaseUrl == false, "\(other) should not support baseUrl")
        }
    }

    @Test("requiresKey covers the three providers with API-key auth")
    func requiresKey() {
        #expect(AIProvider.anthropic.requiresKey == true)
        #expect(AIProvider.openai.requiresKey == true)
        #expect(AIProvider.local.requiresKey == true)
        #expect(AIProvider.unconfigured.requiresKey == false)
    }

    // MARK: - AIProviderConfig resolution

    @Test("resolvedProvider falls back to .unconfigured when server returns nil")
    func resolvedProviderNil() {
        let config = AIProviderConfig()
        #expect(config.resolvedProvider == .unconfigured)
    }

    @Test("resolvedProvider falls back to .unconfigured for unknown wire values")
    func resolvedProviderUnknownValue() {
        // M2-A3 §2 root-cause: previously a missing field defaulted to
        // a legacy provider default, painting a phantom cloud configuration. The new model
        // returns `.unconfigured` for missing + unknown alike.
        let config = AIProviderConfig(provider: "MISTRAL")
        #expect(config.resolvedProvider == .unconfigured)
    }

    @Test(
        "isFullyConfigured per provider",
        arguments: [
            (AIProviderConfig(), false),
            (AIProviderConfig(provider: "ANTHROPIC"), false), // no key
            (AIProviderConfig(provider: "ANTHROPIC", hasAnthropicKey: true), true),
            (AIProviderConfig(provider: "OPENAI"), false),
            (AIProviderConfig(provider: "OPENAI", hasOpenaiKey: true), true),
            (AIProviderConfig(provider: "LOCAL", hasLocalKey: true), false), // missing baseUrl
            (AIProviderConfig(provider: "LOCAL", baseUrl: "https://x", hasLocalKey: true), true)
        ]
    )
    func isFullyConfigured(config: AIProviderConfig, expected: Bool) {
        #expect(config.isFullyConfigured == expected)
    }

    // MARK: - COACH-10 (W-B184 / RCA Bug 4) — loading ≠ truly-unconfigured

    /// The "Provider nicht konfiguriert" surfaces must distinguish two states
    /// that both decode to `.unconfigured`:
    ///   1. **config not loaded yet** (`config == nil`) — the client simply
    ///      hasn't fetched `GET /api/user/ai-provider` — show a neutral loading
    ///      affordance, NEVER a scary "not configured".
    ///   2. **server genuinely has no provider** (`config != nil` && resolves
    ///      `.unconfigured`) — only then is the empty-state copy honest.
    /// `resolvedProvider` collapses both to `.unconfigured`, so callers must
    /// gate on `config != nil` first. This locks that the two inputs are
    /// observably different at the model layer.
    @Test("COACH-10: nil config (loading) is distinct from a loaded empty config")
    func loadingVersusTrulyUnconfigured() {
        let loading: AIProviderConfig? = nil
        let trulyUnconfigured: AIProviderConfig? = AIProviderConfig() // loaded, no provider

        // Both resolve to .unconfigured…
        #expect((loading?.resolvedProvider ?? .unconfigured) == .unconfigured)
        #expect((trulyUnconfigured?.resolvedProvider ?? .unconfigured) == .unconfigured)

        // …but the load-state guard (`config != nil`) tells them apart, which is
        // exactly what the UI branches on so it never shows "not configured"
        // while the fetch is still in flight.
        #expect((loading != nil) == false)
        #expect((trulyUnconfigured != nil) == true)
    }

    @Test("COACH-10: a loaded config with a real provider is neither loading nor unconfigured")
    func loadedConfiguredProviderIsNeitherState() {
        let configured: AIProviderConfig? = AIProviderConfig(
            provider: "ANTHROPIC",
            hasAnthropicKey: true
        )
        #expect(configured != nil) // loaded
        #expect(configured?.resolvedProvider == .anthropic) // and a real provider
        #expect((configured?.resolvedProvider ?? .unconfigured) != .unconfigured)
    }

    @Test("activeKeyPreview returns the matching provider preview")
    func activeKeyPreview() {
        let anthropic = AIProviderConfig(
            provider: "ANTHROPIC",
            hasAnthropicKey: true,
            anthropicKeyPreview: "...AB12"
        )
        #expect(anthropic.activeKeyPreview == "...AB12")

        let openai = AIProviderConfig(
            provider: "OPENAI",
            hasOpenaiKey: true,
            openaiKeyPreview: "...XYZ9"
        )
        #expect(openai.activeKeyPreview == "...XYZ9")

        let local = AIProviderConfig(
            provider: "LOCAL",
            baseUrl: "https://x",
            hasLocalKey: true
        )
        // LOCAL has no per-key preview — we return a placeholder if a key is set.
        #expect(local.activeKeyPreview == "•••")

        let unconfigured = AIProviderConfig()
        #expect(unconfigured.activeKeyPreview == nil)
    }

    // MARK: - AIProviderUpdate encoding semantics

    /// Three states must be encoded distinctly so the partial-update server
    /// can tell "no change" from "clear" from "set" — the `String??` shape
    /// is the whole reason this type uses a custom Encoder.
    private func encode(_ update: AIProviderUpdate) throws -> [String: Any] {
        let data = try JSONEncoder().encode(update)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test("Update with no fields encodes to empty object")
    func emptyUpdate() throws {
        let update = AIProviderUpdate()
        let json = try encode(update)
        #expect(json.isEmpty)
    }

    @Test("Update with .some(nil) provider encodes provider: null (clears)")
    func providerClear() throws {
        let update = AIProviderUpdate(provider: .some(nil))
        let json = try encode(update)
        #expect(json["provider"] is NSNull)
    }

    @Test("Update with .some(.some(value)) encodes provider: value (sets)")
    func providerSet() throws {
        let update = AIProviderUpdate(provider: .some("OPENAI"))
        let json = try encode(update)
        #expect(json["provider"] as? String == "OPENAI")
    }

    @Test("Update with .none (default) skips the provider field entirely")
    func providerSkipped() throws {
        let update = AIProviderUpdate(model: .some("provider-model"))
        let json = try encode(update)
        // No `provider` key at all — server treats absence as "leave it alone".
        #expect(json["provider"] == nil)
        #expect(json["model"] as? String == "provider-model")
    }

    @Test("AIProviderUpdate.setProvider helper maps to .some(wireValue)")
    func setProviderHelper() throws {
        let openai = AIProviderUpdate.setProvider(.openai)
        let openaiJSON = try encode(openai)
        #expect(openaiJSON["provider"] as? String == "OPENAI")

        let cleared = AIProviderUpdate.setProvider(.unconfigured)
        let clearedJSON = try encode(cleared)
        #expect(clearedJSON["provider"] is NSNull)
    }

    @Test("All optional key fields can be cleared independently")
    func clearKeyFields() throws {
        let update = AIProviderUpdate(
            anthropicKey: .some(nil),
            openaiKey: .some(nil),
            localKey: .some(nil)
        )
        let json = try encode(update)
        #expect(json["anthropicKey"] is NSNull)
        #expect(json["openaiKey"] is NSNull)
        #expect(json["localKey"] is NSNull)
    }
}

/// Locks `Insight.providerLabel` mapping continues to surface friendly labels
/// for every wire vocabulary the server might emit, even after the iOS
/// `AIProvider` enum pivoted to the server's provider vocabulary. The label is
/// what shows in the briefing badge — we must not
/// regress it during the B2 refactor.
@Suite("Insight.providerLabel after AIProvider B2 pivot")
struct InsightProviderLabelAfterPivotTests {
    private func insight(provider: String) -> Insight {
        Insight(id: "i", title: "T", summary: "S", severity: .info, generatedAt: Date(), provider: provider)
    }

    @Test(
        "Known family labels still resolve",
        arguments: [
            ("anthropic", "Anthropic"),
            ("claude_haiku", "Anthropic"),
            ("openai", "OpenAI"),
            ("gpt_4o_mini", "OpenAI"),
            ("gemini", "Gemini"),
            ("google", "Gemini")
        ]
    )
    func familyLabels(raw: String, expected: String) {
        #expect(insight(provider: raw).providerLabel == expected)
    }

    @Test("Unknown providers tidy underscores + dashes")
    func unknownProviderTidied() {
        let label = insight(provider: "future-model_2027").providerLabel
        #expect(label.contains("Future"))
        #expect(label.contains("Model"))
        #expect(!label.contains("_"))
        #expect(!label.contains("-"))
    }
}
