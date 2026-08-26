import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

// Structured coach insight surfaced through the AskCoach hero.
//
// **v0.5.7 G.2 — first structured-output prompt for `LocalLLMService`.**
// The shape mirrors the AskCoach kill-card so the SwiftUI consumers in
// G.3 can render a stable surface (`title` headline, `body` paragraph,
// `suggestedActions` bullet-list) without re-shuffling the contract once
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
// The `@Guide` strings are German because the AskCoach hero is
// German-primary (R5 felt-quality target — the German body text is what
// the operator walkthroughs, EN is secondary today). The model picks up
// language from the guide hint + the prompt language; we don't force
// `responseLanguage` until G.4 wires the privacy-first prompt builder.
#if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    public struct CoachInsight: Equatable, Sendable {
        @Guide(description: "Kurze Headline, max 50 Zeichen, deutsch")
        public var title: String

        @Guide(description: "2-3 Sätze die den Befund einordnen, deutsch")
        public var body: String

        @Guide(description: "1-3 konkrete Handlungsvorschläge, deutsch")
        public var suggestedActions: [String]

        public init(
            title: String,
            body: String,
            suggestedActions: [String]
        ) {
            self.title = title
            self.body = body
            self.suggestedActions = suggestedActions
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
        public var suggestedActions: [String]

        public init(
            title: String,
            body: String,
            suggestedActions: [String]
        ) {
            self.title = title
            self.body = body
            self.suggestedActions = suggestedActions
        }
    }
#endif
