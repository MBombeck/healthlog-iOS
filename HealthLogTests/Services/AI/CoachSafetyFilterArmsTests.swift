import Foundation
@testable import HealthLog
import Testing

#if canImport(SpeziChat)
    import SpeziChat
#endif

/// **R11 (1.0.3, App Review 1.4.1) — the coach's output passes the MDR filter,
/// on every arm.**
///
/// The 1.4.1 audit found `MDRSafetyFilter` wired into six AI output paths and
/// into **none of the three coach arms** — on-device (`CoachConversationStore`
/// streaming `CoachInsight` partials), BYO (device → the user's own provider)
/// and server (SSE). The conversational surface, where the model is asked the
/// most open-ended questions, was the one shipping raw model text into a
/// bubble.
///
/// Two of the three arms are driven here end-to-end through the seams the app
/// itself ships (a seeded SSE body; the real `BYOLLMService` over
/// `MockURLProtocol`), so the assertion is about the transcript a person would
/// actually read. The on-device arm has no such seam — `streamResponse` hands
/// back a concrete `LanguageModelSession.ResponseStream` and needs Apple
/// Intelligence — so its DECISION is driven directly and its WIRING is pinned
/// against the source text. That is the same split
/// `emptyGenerationOutcome(didRenderAnything:)` uses, for the same reason: a
/// modelled fix must not be able to stand in for a real one.
@MainActor
@Suite("Coach — MDR safety filter on every arm (R11)", .serialized)
struct CoachSafetyFilterArmsTests {
    /// The copy a refused turn renders. Same resolver the store uses, so the
    /// test cannot drift from the shipped string by pinning a literal.
    ///
    /// **R19a (fix round 1)** — this was `MiniCoachPrompt.refusalCopy`, an
    /// *input* refusal ("I can only explain the data you logged"). It said the
    /// question was out of bounds when the question was fine and the answer was
    /// withheld. The key is the coach's own output-filter copy now.
    private static var refusal: String {
        String(localized: "coach.filtered.refusal")
    }

    @Test("the refusal copy resolves to real text, not the key")
    func refusalCopyResolves() {
        #expect(!Self.refusal.isEmpty)
        #expect(Self.refusal != "coach.filtered.refusal", "the catalog must carry the key")
        // It has to say the answer was withheld — not that the question was
        // wrong. The distinction is the whole point of R19a.
        #expect(
            Self.refusal.localizedCaseInsensitiveContains("held back")
                || Self.refusal.localizedCaseInsensitiveContains("zurückgehalten")
        )
    }

    /// A German dose recommendation — matrix row 8 (`prescriptive`).
    private static let prescriptiveDE = "Ich empfehle dir eine hoehere Dosis."
    /// The English shape of the same thing — matrix row 8 (`must_take_now`).
    private static let prescriptiveEN = "You should now take another tablet."
    /// Descriptive prose the filter has no business touching.
    private static let benign = "Dein Blutdruck lag zuletzt bei 122/76 mmHg."

    // MARK: - The decision

    @Test("a descriptive reply passes through unchanged")
    func benignReplyPasses() async {
        let text = await CoachConversationStore.safeReplyText(
            Self.benign,
            refusal: "REFUSED",
            filter: MDRSafetyFilter()
        )
        #expect(text == Self.benign)
    }

    @Test("a prescriptive reply is replaced wholesale, in both languages")
    func prescriptiveReplyIsRefused() async {
        for fixture in [Self.prescriptiveDE, Self.prescriptiveEN] {
            let text = await CoachConversationStore.safeReplyText(
                fixture,
                refusal: "REFUSED",
                filter: MDRSafetyFilter()
            )
            #expect(text == "REFUSED", "\(fixture) must not reach a bubble")
            // Wholesale, not edited: no fragment of the flagged sentence
            // survives to stand next to the refusal.
            #expect(!text.contains("Dosis"))
            #expect(!text.contains("tablet"))
        }
    }

    // MARK: - Server arm (SSE) — end to end

    /// The streaming arm is the interesting one: tokens are painted as they
    /// arrive and the filter never sees them individually. It does not have to.
    /// The server's `done` frame carries the authoritative reply, the arm
    /// already overwrites the accumulated bubble with it, and THAT text — the
    /// one that both settles on screen and is written to disk — is filtered.
    @Test("the server arm's final bubble is the filtered one")
    func serverArmFiltersFinalReply() async {
        let store = CoachConversationStoreTests.makeServerArmStore(.answer(Self.prescriptiveDE))
        await store.send("Soll ich mehr nehmen?")

        #expect(store.lastError == nil)
        #expect(store.chat.count == 2)
        #if canImport(SpeziChat)
            let last = store.chat.last
            #expect(last?.role == .assistant)
            #expect(last?.content == Self.refusal)
            #expect(last?.content.contains("Dosis") == false)
        #endif
    }

    @Test("the server arm leaves a descriptive reply alone")
    func serverArmPassesDescriptiveReply() async {
        let store = CoachConversationStoreTests.makeServerArmStore(.answer(Self.benign))
        await store.send("Wie war mein Blutdruck?")

        #expect(store.lastError == nil)
        #if canImport(SpeziChat)
            #expect(store.chat.last?.content == Self.benign)
        #endif
    }

    // MARK: - BYO arm — end to end

    /// Device → the user's own provider. We control neither the model nor the
    /// system prompt it honours, so this arm is the one where a post-hoc filter
    /// earns its keep most plainly.
    @Test("the BYO arm's reply is filtered before it reaches the transcript")
    func byoArmFiltersReply() async throws {
        let keychain = InMemoryKeychain()
        let keyStore = BYOKeyStore(keychain: keychain)
        try keyStore.setKey("sk-stored", for: .openAI)
        // Per-instance transport (`MockURLProtocolSession`), not the global
        // handler slot: this suite must not race the BYO suite next door for a
        // process-wide closure.
        let transport = MockURLProtocolSession()
        transport.install { _ in
            let json = #"{"choices":[{"message":{"content":"You should now take another tablet."}}]}"#
            let response = HTTPURLResponse(
                url: URL(fileURLWithPath: "/byo"),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
            return (response ?? HTTPURLResponse(), Data(json.utf8))
        }
        defer { transport.invalidate() }

        let store = CoachConversationStore(service: LocalLLMService())
        store.byoService = BYOLLMService(
            keyStore: keyStore,
            session: URLSession(configuration: transport.configuration),
            consentGate: { _ in true }
        )
        store.byoProviderResolver = { .openAI }

        await store.send("Was soll ich tun?")

        #expect(store.lastError == nil)
        #expect(store.chat.count == 2)
        #if canImport(SpeziChat)
            #expect(store.chat.last?.content == Self.refusal)
            #expect(store.chat.last?.content.contains("tablet") == false)
        #endif
    }

    // MARK: - On-device arm — the wiring, pinned

    /// No seam exists for the on-device arm (it needs Apple Intelligence and a
    /// concrete `ResponseStream`), so the pin is the source text: the final
    /// rendered text goes through `filteredReply` and the FILTERED value — not
    /// `lastRendered` — is what reaches the bubble and the persistence layer.
    @Test("every arm routes its final text through filteredReply before persisting")
    func everyArmIsWired() throws {
        let source = try CoachConversationStoreTests.source(
            "HealthLog/Services/AI/CoachConversationStore.swift"
        )
        // On-device: filter the accumulated stream, overwrite the bubble, persist
        // the filtered text.
        #expect(source.contains("let finalText = await filteredReply(lastRendered)"))
        #expect(source.contains("persistMessage(role: .assistant, text: finalText)"))
        #expect(source.contains("upsertStreamingAssistant(finalText, isFirstPartial: false)"))
        // Server: filter the authoritative `done` text, render + persist that.
        #expect(source.contains("let replyText = await filteredReply(reply.text)"))
        #expect(source.contains("persistMessage(role: .assistant, text: replyText)"))
        #expect(!source.contains("persistMessage(role: .assistant, text: reply.text)"))
        // BYO: filter the provider's single-shot reply.
        #expect(source.contains("let text = await filteredReply(raw)"))
        // I1 (fix round 1) — the SSE arm re-checks cancellation between the
        // filter (a suspension point) and the transcript mutation, like the
        // other two arms. No seam can drive a cancel INTO that window: the
        // filter is a concrete actor the store owns outright (no protocol, no
        // injection point), and the seeded SSE transport resolves without one
        // either, so there is nowhere to hold the turn mid-window. Ordering in
        // the source is what can honestly be checked, so it is what is checked.
        let filterCall = try #require(source.range(of: "let replyText = await filteredReply(reply.text)"))
        let settle = try #require(source.range(of: "if streamRender.didAppend {"))
        let guardCall = try #require(
            source.range(of: "if Task.isCancelled { return }", range: filterCall.upperBound ..< settle.lowerBound)
        )
        #expect(guardCall.lowerBound > filterCall.upperBound)
        // No arm may persist the raw stream accumulator any more.
        #expect(!source.contains("persistMessage(role: .assistant, text: lastRendered)"))
    }
}
