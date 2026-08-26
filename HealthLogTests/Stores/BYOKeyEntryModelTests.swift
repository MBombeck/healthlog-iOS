import Foundation

// swiftlint:disable force_unwrapping large_tuple
@testable import HealthLog
import Testing

/// v0.13 W4 — the `BYOKeyEntryModel` validate → save → grant flow (the View-free
/// engine behind `BYOKeyEntryCard`). The `BYOLLMService` validation runs through
/// a stubbed `URLSession` (`MockURLProtocol`, never a mock server); the keychain
/// + consent store are in-memory doubles.
@MainActor
@Suite("BYOKeyEntryModel — validate/save/grant", .serialized)
struct BYOKeyEntryModelTests {
    private func makeSession() -> URLSession {
        URLSession(configuration: .mock())
    }

    private func makeModel(keychain: InMemoryKeychain) -> (BYOKeyEntryModel, AIConsentStore, BYOKeyStore) {
        let keyStore = BYOKeyStore(keychain: keychain)
        let service = BYOLLMService(keyStore: keyStore, session: makeSession())
        let consent = AIConsentStore(keychain: keychain, defaults: UserDefaults(suiteName: "byo.entry.\(UUID())")!)
        let model = BYOKeyEntryModel(service: service, keyStore: keyStore, consent: consent)
        return (model, consent, keyStore)
    }

    @Test("validate success saves key + clears draft + awaits consent")
    func validateSavesAndAwaitsConsent() async {
        let keychain = InMemoryKeychain()
        let (model, consent, keyStore) = makeModel(keychain: keychain)
        model.provider = .openAI
        model.keyDraft = "sk-good"

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":[]}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        await model.validateAndSave()

        #expect(model.phase == .awaitingConsent)
        #expect(keyStore.key(for: .openAI) == "sk-good")
        #expect(model.keyDraft.isEmpty, "secret draft must be cleared after save")
        // Consent NOT yet granted — only the sheet-accept grants it.
        #expect(consent.hasBYOConsent(for: .openAI) == false)

        // Accept consent → grant lands, aiMode flips to .byoKey.
        model.confirmConsent()
        #expect(model.phase == .saved)
        #expect(consent.hasBYOConsent(for: .openAI))
        #expect(consent.aiMode == .byoKey)
    }

    @Test("validate failure surfaces honest error, no save, no grant")
    func validateFailureNoSave() async {
        let keychain = InMemoryKeychain()
        let (model, consent, keyStore) = makeModel(keychain: keychain)
        model.provider = .openAI
        model.keyDraft = "sk-bad"

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }
        defer { MockURLProtocol.handler = nil }

        await model.validateAndSave()

        guard case .invalid = model.phase else {
            Issue.record("expected .invalid, got \(model.phase)")
            return
        }
        #expect(keyStore.key(for: .openAI) == nil)
        #expect(consent.hasBYOConsent(for: .openAI) == false)
    }

    @Test("decline after save rolls back the key (no dangling key without consent)")
    func declineRollsBack() async {
        let keychain = InMemoryKeychain()
        let (model, consent, keyStore) = makeModel(keychain: keychain)
        model.provider = .openAI
        model.keyDraft = "sk-good"
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":[]}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        await model.validateAndSave()
        model.cancelConsent()

        #expect(model.phase == .editing)
        #expect(keyStore.key(for: .openAI) == nil, "key must roll back when consent declined")
        #expect(consent.hasBYOConsent(for: .openAI) == false)
    }

    @Test("remove key wipes key + revokes consent")
    func removeKey() throws {
        let keychain = InMemoryKeychain()
        let (model, consent, keyStore) = makeModel(keychain: keychain)
        model.provider = .openAI
        try keyStore.setKey("sk-good", for: .openAI)
        consent.grantBYO(for: .openAI)
        #expect(consent.aiMode == .byoKey)

        model.removeKey()
        #expect(keyStore.key(for: .openAI) == nil)
        #expect(consent.hasBYOConsent(for: .openAI) == false)
        #expect(model.phase == .editing)
    }

    @Test("openAICompatible requires an https base URL to submit")
    func compatibleRequiresHTTPS() {
        let keychain = InMemoryKeychain()
        let (model, _, _) = makeModel(keychain: keychain)
        model.provider = .openAICompatible
        model.keyDraft = "k"
        #expect(model.canSubmit == false, "no base URL → cannot submit")
        model.baseURLDraft = "http://192.168.1.5:11434"
        #expect(model.canSubmit == false, "http base URL rejected (https-only)")
        model.baseURLDraft = "https://gateway.example.com"
        #expect(model.canSubmit, "https base URL accepted")
    }
}
