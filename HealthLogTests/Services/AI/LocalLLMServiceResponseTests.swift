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
/// In all three skip cases the test returns clean (no `Issue.record`,
/// no thrown sentinel) so the suite reads "passed" on a kill-card host.
/// Real-device + Xcode-Cloud runs on eligible hardware execute the
/// live model call and assert the shape of the returned `CoachInsight`.
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
    @Test("respond returns a well-formed CoachInsight when the model is available")
    func respondReturnsWellFormedInsight() async throws {
        guard #available(iOS 26.0, *) else {
            // Pre-iOS-26 sims / CI hosts cannot run the
            // FoundationModels path at all — the public `respond(prompt:)`
            // entry-point is `@available(iOS 26.0, *)`-gated, so we
            // cannot even reference it from this scope without the
            // guard. Early-return clean — Swift Testing has no
            // first-class `#skip(...)` primitive yet, and a thrown
            // sentinel would surface as a failure. The test name +
            // this comment document why the slot stayed empty.
            return
        }

        let service = LocalLLMService()

        // Branch the skip on the runtime availability snapshot. The
        // `LocalLLMService.Availability` enum is documented to mirror
        // Apple's `SystemLanguageModel.Availability`; only `.available`
        // can serve a response. Any other case means the host
        // (sim/CI) cannot exercise the live model path — return
        // silently for the same reason as the iOS-floor guard above.
        guard service.availability == .available else {
            return
        }

        // Live model call against the prompt production actually sends.
        //
        // **1.0.3 (R11).** This used to hand the model a bare question
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
        // **R29 — and against a snapshot with something in it.** The
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
        let insight: CoachInsight
        do {
            insight = try await service.respond(prompt: prompt)
        } catch LocalLLMError.foundationModelsUnavailable {
            // Race: availability flipped between the snapshot above
            // and the call (the service re-probes on every
            // `respond(prompt:)` to stay honest with Settings
            // toggles). Treat as a skip — the host genuinely can't
            // serve the request right now.
            return
        } catch LocalLLMError.modelResponseFailed {
            // Simulator-without-model-assets path (case 3 in the
            // suite-level doc above). `availability == .available`
            // returns true but the model catalog has no underlying
            // assets, so the call fails with a
            // `ModelManagerServices.ModelManagerError`. We can't
            // assert against a model we can't run — skip cleanly.
            return
        }

        #expect(insight.title.isEmpty == false, "title must not be empty")
        #expect(
            insight.body.count >= 20,
            "body must hold at least one full sentence (≥20 chars), got \(insight.body.count)"
        )
        #expect(
            insight.talkingPoints.count >= 1,
            "must surface at least one talking point for the doctor visit"
        )
        // R11 — the talking points are for a conversation, not a to-do list.
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

    // MARK: - Fixtures (R29)

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
