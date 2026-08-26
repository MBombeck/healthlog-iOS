import Foundation

// swiftlint:disable force_unwrapping
@testable import HealthLog
import Testing

/// v0.13 W2 — ``BYOKeyStore`` per-provider round-trip + teardown coverage. The
/// secret key bytes must round-trip per provider and be fully wiped by
/// ``BYOKeyStore/wipeAll()`` (the logout / delete-account hook).
@Suite("BYOKeyStore")
struct BYOKeyStoreTests {
    private func makeStore() -> (BYOKeyStore, InMemoryKeychain) {
        let keychain = InMemoryKeychain()
        return (BYOKeyStore(keychain: keychain), keychain)
    }

    /// Force-unwraps a known-good URL literal. A plain returning helper (not an
    /// inline `try #require(...)`) so swiftformat does not rewrite it into a
    /// `#require` the compiler then flags as redundant for a constant string.
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test("Key round-trips per provider, isolated by id")
    func keyRoundTrip() throws {
        let (store, _) = makeStore()
        try store.setKey("sk-openai", for: .openAI)
        try store.setKey("sk-ant-anthropic", for: .anthropic)
        #expect(store.key(for: .openAI) == "sk-openai")
        #expect(store.key(for: .anthropic) == "sk-ant-anthropic")
        #expect(store.key(for: .gemini) == nil)
        #expect(store.hasKey(for: .openAI))
        #expect(!store.hasKey(for: .gemini))
    }

    @Test("setKey trims whitespace and rejects blank")
    func trimAndReject() throws {
        let (store, _) = makeStore()
        try store.setKey("  sk-padded  ", for: .openAI)
        #expect(store.key(for: .openAI) == "sk-padded")
        #expect(throws: BYOLLMError.self) {
            try store.setKey("   ", for: .openAI)
        }
        // Existing key survives a rejected blank write.
        #expect(store.key(for: .openAI) == "sk-padded")
    }

    @Test("removeKey clears a single provider")
    func removeKey() throws {
        let (store, _) = makeStore()
        try store.setKey("sk-a", for: .openAI)
        try store.setKey("sk-b", for: .anthropic)
        try store.removeKey(for: .openAI)
        #expect(store.key(for: .openAI) == nil)
        #expect(store.key(for: .anthropic) == "sk-b")
    }

    @Test("Model override resolves, clears to default")
    func modelOverride() throws {
        let (store, _) = makeStore()
        #expect(store.resolvedModel(for: .openAI) == BYOProviderID.openAI.defaultModel)
        try store.setModel("gpt-4o", for: .openAI)
        #expect(store.model(for: .openAI) == "gpt-4o")
        #expect(store.resolvedModel(for: .openAI) == "gpt-4o")
        try store.setModel(nil, for: .openAI)
        #expect(store.resolvedModel(for: .openAI) == BYOProviderID.openAI.defaultModel)
    }

    @Test("Base URL round-trips for openAICompatible")
    func baseURL() throws {
        let (store, _) = makeStore()
        let gateway = url("https://gateway.example.com")
        try store.setBaseURL(gateway, for: .openAICompatible)
        #expect(store.baseURL(for: .openAICompatible) == gateway)
        try store.setBaseURL(nil, for: .openAICompatible)
        #expect(store.baseURL(for: .openAICompatible) == nil)
    }

    @Test("wipeAll removes every key, model, and base URL")
    func wipeAll() throws {
        let (store, keychain) = makeStore()
        try store.setKey("sk-openai", for: .openAI)
        try store.setKey("sk-ant", for: .anthropic)
        try store.setKey("AIza", for: .gemini)
        try store.setModel("gpt-4o", for: .openAI)
        try store.setBaseURL(url("https://x.example.com"), for: .openAICompatible)
        try store.setKey("compat", for: .openAICompatible)

        store.wipeAll()

        for provider in BYOProviderID.allCases {
            #expect(store.key(for: provider) == nil)
            #expect(store.model(for: provider) == nil)
            #expect(store.baseURL(for: provider) == nil)
        }
        // No BYO residue at all in the keychain double.
        #expect(keychain.getString(forKey: BYOKeyStore.keyPrefix + "openai") == nil)
        #expect(keychain.getString(forKey: BYOKeyStore.modelPrefix + "openai") == nil)
    }
}
