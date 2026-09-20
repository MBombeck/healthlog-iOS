import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

// Structured coach insight surfaced through the AskCoach hero.
//
// **v0.5.7 G.2 — first structured-output prompt for `LocalLLMService`.**
// The shape mirrors the AskCoach kill-card so the SwiftUI consumers in
// G.3 can render a stable surface (`title` headline, `body` paragraph,
// `talkingPoints` bullet-list) without re-shuffling the contract once
// streaming + chat history land.
//
// **Why `@Generable` here, not a Plain-Old-Data mirror like
// `OnDeviceBriefing`?** This is the first surface where the on-device
// model directly drives a top-level user-facing object. Wrapping the
// `@Generable` declaration in `#if canImport(FoundationModels)` keeps
// the type compilable on the iOS 18 / 25 floor — the macro itself only
// expands when FoundationModels is linkable. The struct is `Equatable +
// Sendable` so the `@Observable` `AskCoachStore` (G.3) can diff
// re-renders and the LocalLLMService can return values across actor
// hops without `@unchecked`.
//
// **R11 (1.0.3, App Review 1.4.1) — the schema no longer asks for actions.**
// `suggestedActions` ("1-3 konkrete Handlungsvorschläge") pinned the whole
// surface to concrete action advice: whatever the prompt said, the schema
// demanded a to-do list. The field is now `talkingPoints` — questions and
// observations for the person's next doctor visit — and `body` describes
// rather than delivers a "Befund".
//
// The `@Guide` descriptions are **bilingual in one string**, EN first. A
// `@Guide` description is baked into the generation schema at compile time,
// so it cannot branch on the session locale the way
// ``PrivacyFirstPromptBuilder`` does; carrying both languages is how the
// guardrail reaches an English session too (the App-Review reviewer's). The
// prompt supplies the locale-selected instruction on top.
#if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    public struct CoachInsight: Equatable, Sendable {
        @Guide(description: "Short headline, max 50 characters, in the language of the prompt. "
            + "Kurze Headline, max 50 Zeichen, in der Sprache des Prompts.")
        public var title: String

        @Guide(description: "2-3 sentences that describe and place the value in context — "
            + "no diagnosis, no therapy or dose recommendation. "
            + "2-3 Sätze, die den Wert beschreibend einordnen — keine Diagnose, "
            + "keine Therapie- oder Dosisempfehlung.")
        public var body: String

        /// **R29 — the count is a constraint, not a request.**
        ///
        /// R11 took the count out of the schema along with the action framing:
        /// `suggestedActions` had coerced a list out of any prompt, and losing
        /// that coercion was the point. But the *count* was collateral. A 3B
        /// model does not reliably honour "1-3" from prose, and the live
        /// round-trip test failed the release freeze twice with an empty array
        /// (2 of 3 runs). `.count(1...3)` puts the floor back into the
        /// generation schema where the runtime enforces it, while the
        /// description keeps doing the R11 work — questions and observations for
        /// a clinician, never an instruction. Constraining the shape is not the
        /// same as dictating the content, which is the distinction R11 turned on.
        @Guide(
            description: "1-3 questions or observations the person can discuss with their doctor. "
                + "Never an instruction to act. "
                + "1-3 Fragen oder Beobachtungen, die die Person mit Ärztin oder Arzt besprechen kann. "
                + "Niemals eine Handlungsanweisung.",
            .count(1 ... 3)
        )
        public var talkingPoints: [String]

        public init(
            title: String,
            body: String,
            talkingPoints: [String]
        ) {
            self.title = title
            self.body = body
            self.talkingPoints = talkingPoints
        }
    }
#else
    /// iOS 18 / 25 fallback shape. Keeps the public API symbol resolvable
    /// from non-FoundationModels build configurations (Mac Catalyst, sim
    /// without Apple Intelligence). Call-sites that branch on
    /// `LocalLLMService.availability` never reach the
    /// `@available(iOS 26.0, *)` `respond(_:)` path on these builds, so
    /// this fallback exists purely so type-name references compile.
    public struct CoachInsight: Equatable, Sendable {
        public var title: String
        public var body: String
        public var talkingPoints: [String]

        public init(
            title: String,
            body: String,
            talkingPoints: [String]
        ) {
            self.title = title
            self.body = body
            self.talkingPoints = talkingPoints
        }
    }
#endif
