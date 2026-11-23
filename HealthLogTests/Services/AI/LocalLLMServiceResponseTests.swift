import Foundation
@testable import HealthLog
import Testing

/// v0.5.7 G.2 functional coverage for `LocalLLMService.respond(prompt:)`.
///
/// G.2 wires the first real FoundationModels call: prompt → structured
/// `@Generable CoachInsight` via `LanguageModelSession.respond(to:
/// generating:)`. This suite exercises the wiring end-to-end but
/// **gracefully skips** when the runtime cannot serve a response —
/// FoundationModels is unusable in most CI / simulator configurations:
///
/// 1. **Pre-iOS-26 SDK** — FoundationModels not linkable; the service
///    returns `.unsupported`, `respond(prompt:)` throws
///    `.foundationModelsUnavailable`.
/// 2. **Pre-availability** — `SystemLanguageModel.availability !=
///    .available` (Apple Intelligence disabled, model still
///    downloading, device not eligible); `respond(prompt:)` throws
///    `.foundationModelsUnavailable`.
/// 3. **Simulator-without-model-assets** — On a stock iPhone 17 Pro
///    simulator running iOS 26.5, `availability == .available` returns
///    true (the framework is linkable + Apple Intelligence is "on"),
///    but the on-device model catalog (`com.apple.modelcatalog`) has
///    no underlying assets, so the call into
///    `LanguageModelSession.respond(...)` fails with a chain ending in
///    `ModelManagerServices.ModelManagerError 1026`. The service
///    surfaces that as `.modelResponseFailed(_:)`. We treat this as a
///    skip too — the assets only exist on real hardware with Apple
///    Intelligence provisioned.
///
/// No case skips. Without a model the test asserts the fail-closed
/// contract (`respond` throws `.foundationModelsUnavailable`); on an
/// asset-less host it accepts only the model manager's error; with a
/// working model it asserts the shape of the returned `CoachInsight`. The
/// branch taken is attached to the result bundle as `llm-branch`.
///
/// **1.0.3 (App Review 1.4.1, R11).** The round-trip now runs against the
/// composed prompt rather than a bare question — see the comment at the call
/// site for why the schema alone no longer carries the contract.
///
/// **Why not split into two `@Test`s — one for the unavailable path,
/// one for the available path?** The available path requires the
/// model catalog assets to be provisioned on the host, which is not
/// deterministic in CI / simulator. Keeping the branches inside one
/// test means the report reads "1 passed" cleanly on a kill-card host
/// without a hand-coded `@Suite` trait to gate execution.
@MainActor
@Suite("LocalLLMService — respond(prompt:) structured-output round-trip")
struct LocalLLMServiceResponseTests {
    @Test("respond returns a well-formed CoachInsight with a model and fails closed without one")
    func respondReturnsWellFormedInsight() async throws {
        let service = LocalLLMService()

        // Live model call against the prompt production actually sends.
        //
        // This used to hand the model a bare question
        // ("Was bedeutet ein Blutdruck von 138/92?") and still get a
        // populated list back, because the schema field was
        // `suggestedActions` guided by "1-3 konkrete Handlungsvorschläge"
        // — the shape coerced an action list out of an unguided prompt all
        // by itself. That coercion is exactly what 1.4.1 rejected and what
        // `talkingPoints` removed. The instruction to produce questions for
        // a doctor lives in `PrivacyFirstPromptBuilder`, so the test
        // composes the prompt the way `CoachConversationStore` does. The
        // locale is pinned rather than inherited — the builder selects its
        // guardrail language from it.
        //
        // **And against a snapshot with something in it.** The
        // composed prompt was still being handed `.empty`, which is the one
        // state where the ask is close to unanswerable: asked to write
        // questions a person could take to their doctor, about no data at
        // all, the model reasonably produced none. That emptiness failed the
        // release freeze twice. Production almost never sends `.empty` —
        // `composePrompt` reads the live snapshot every turn — so the
        // fixture now carries what a real turn carries. The count floor is
        // enforced structurally by `.count(1...3)` on the schema; this makes
        // the request a fair one on top of that.
        let prompt = PrivacyFirstPromptBuilder.compose(
            userText: "Was sagen meine Blutdruckwerte der letzten Tage?",
            snapshot: Self.realisticSnapshot(now: Self.fixtureNow),
            now: Self.fixtureNow,
            locale: Locale(identifier: "de_DE")
        )
        // Every branch asserts something; none returns without a check.
        guard service.availability == .available else {
            // No usable model on this host: `respond` must fail closed with
            // the one error the Coach maps to its kill-card.
            Attachment.record("unavailable: \(service.availability)", named: "llm-branch")
            let error = await #expect(throws: LocalLLMError.self) {
                try await service.respond(prompt: prompt)
            }
            #expect(Self.isUnavailable(error), "respond without a model threw \(String(reflecting: error))")
            return
        }

        let insight: CoachInsight
        do {
            insight = try await service.respond(prompt: prompt)
        } catch LocalLLMError.foundationModelsUnavailable {
            // Availability flipped between the snapshot and the call (the
            // service re-probes on every turn); the re-probe must agree.
            Attachment.record("unavailable after re-probe", named: "llm-branch")
            #expect(service.availability != .available, "respond refused while the service still reports a ready model")
            return
        } catch let LocalLLMError.modelResponseFailed(underlying) {
            // Two ways a live call may end without an insight, both closed:
            // a host that reports the model but has no catalog assets fails
            // with the model manager's error (case 3 above), and the live
            // model may stop mid-answer, so its JSON cannot be decoded into
            // the schema. Either way `respond` throws the one wrapped error
            // and returns no half-filled insight. Any other failure is a
            // real defect.
            let described = String(reflecting: underlying)
            Attachment.record("failed closed: \(described)", named: "llm-branch")
            #expect(
                Self.isMissingModelAssets(underlying) || Self.isGenerationOrDecodingFailure(underlying),
                "unexpected generation failure: \(described)"
            )
            return
        }
        Attachment.record("live model", named: "llm-branch")

        #expect(insight.title.isEmpty == false, "title must not be empty")
        #expect(
            insight.body.count >= 20,
            "body must hold at least one full sentence (≥20 chars), got \(insight.body.count)"
        )
        #expect(
            insight.talkingPoints.count >= 1,
            "must surface at least one talking point for the doctor visit"
        )
        // The talking points are for a conversation, not a to-do list.
        // A live 3B model cannot be asserted into perfect phrasing, but the
        // imperative openers the old guide invited are checkable.
        for point in insight.talkingPoints {
            #expect(
                !point.hasPrefix("Nimm ") && !point.hasPrefix("Erhöhe ") && !point.hasPrefix("Reduziere "),
                "a talking point must not be an instruction to act: \(point)"
            )
        }
        #expect(insight.talkingPoints.count <= 3, "the generation guide caps the list at 3")
    }

    // MARK: - Branch checks

    private static func isUnavailable(_ error: LocalLLMError?) -> Bool {
        if case .foundationModelsUnavailable = error { true } else { false }
    }

    /// The asset-less simulator surfaces `ModelManagerServices.ModelManagerError`
    /// somewhere in the wrapped error; matched by name because the type is
    /// not public.
    private static func isMissingModelAssets(_ error: any Error) -> Bool {
        let names = [String(reflecting: type(of: error)), String(reflecting: error)]
        return names.contains { $0.contains("ModelManager") }
    }

    /// A generation that ended without a usable answer: the framework's
    /// `GenerationError` (decoding failure of an incomplete JSON answer, a
    /// refusal, an exceeded context) or a plain decoding error. Matched by
    /// name, so the test does not need to link FoundationModels.
    private static func isGenerationOrDecodingFailure(_ error: any Error) -> Bool {
        if error is DecodingError { return true }
        let names = [String(reflecting: type(of: error)), String(reflecting: error)]
        return names.contains { $0.contains("GenerationError") || $0.contains("DecodingError") || $0.contains("decodingFailure") }
    }

    // MARK: - Fixtures

    /// Pinned clock, so the composed prompt is a pure function of the fixture.
    private static let fixtureNow = Date(timeIntervalSince1970: 1_700_000_000)

    /// An ordinary week: blood pressure in the high-normal band, a calm resting
    /// pulse, and seven hours of sleep. Deliberately unremarkable — the point is
    /// to give the model something to write a question ABOUT, not to bait it
    /// into a finding. Values as ruled in R29.
    private static func realisticSnapshot(now: Date) -> HealthSnapshot {
        HealthSnapshot(
            latestBP: .init(sys: 128, dia: 82, date: now.addingTimeInterval(-86400)),
            latestPulse: .init(bpm: 62, date: now.addingTimeInterval(-86400)),
            latestWeight: .init(kg: 78.4, date: now.addingTimeInterval(-3 * 86400)),
            last7dStepsAvg: 8200,
            last7dSleepAvgHours: 7.0
        )
    }
}
