import Foundation
import Testing

// W-FOCUS-FILTER — this suite touches app-only types (`FocusFilterConfig`,
// `CoachNudgeStore`, `CoachCadenceSuggestionsStore`), so it compiles only in the
// app test target, never the platform-free `HealthLogCore` SPM build.
#if !SWIFT_PACKAGE
    @testable import HealthLog

    /// **W-FOCUS-FILTER (v0.15.2)** — proves the proactive coach surfaces honour
    /// the Focus filter's "pause coach nudges" while never touching server state.
    ///
    /// The config is **injected** into the stores (not read from the shared App
    /// Group suite) so the suite stays fully isolated — no global mutation, no
    /// bleed into other coach tests. The suppression gate sits BEFORE the network
    /// leg, so a seeded surface is cleared with no repo call (render-suppression,
    /// not data loss).
    @Suite("Focus filter — coach nudge suppression")
    @MainActor
    struct CoachFocusFilterSuppressionTests {
        private static func suggestion(_ id: String) -> CoachCadenceSuggestion {
            CoachCadenceSuggestion(
                id: id,
                cadenceId: id,
                measurementType: "WEIGHT",
                label: "coach.reminderSuggestion.cadence.weightDaily"
            )
        }

        private let paused = FocusFilterConfig(
            isActive: true,
            suppressNonCriticalReminders: true,
            pauseCoachNudges: true
        )

        @Test("an inline cadence suggestion is held back while filter pauses coach nudges")
        func cadenceSuppressedWhenPaused() {
            let api = StubAPIClient()
            let paused = paused
            let store = CoachCadenceSuggestionsStore(
                repo: CoachCadenceSuggestionsRepository(api: api),
                focusFilterConfig: { paused }
            )

            // The pause gate short-circuits `present(_:)` — the card never lands.
            store.present(Self.suggestion("cad1"))
            #expect(store.suggestions.isEmpty)
        }

        @Test("coach unread dot stays dark while filter pauses coach nudges")
        func nudgeDotDarkWhenPaused() async {
            let paused = paused
            let store = CoachNudgeStore(
                fetchStatus: { CoachNudgeStatus(nudgedAt: .now, unread: true) },
                postSeen: {},
                focusFilterConfig: { paused }
            )
            await store.refresh(coachEnabled: true, online: true)
            #expect(store.unread == false)
        }

        @Test("coach unread dot resolves normally when filter does not pause coach")
        func nudgeDotFlowsWhenNotPaused() async {
            let notPaused = FocusFilterConfig(
                isActive: true,
                suppressNonCriticalReminders: true,
                pauseCoachNudges: false
            )
            let store = CoachNudgeStore(
                fetchStatus: { CoachNudgeStatus(nudgedAt: .now, unread: true) },
                postSeen: {},
                focusFilterConfig: { notPaused }
            )
            await store.refresh(coachEnabled: true, online: true)
            #expect(store.unread)
        }
    }
#endif
