import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog

    /// Tests for `NotificationService.resolveReminderPhrase(outcome:fallbackTitle:fallbackBody:)`.
    /// The actual `UNUserNotificationCenter.add(...)` call is unreachable in the
    /// host-app-less test runner — the pure resolution helper is the unit-
    /// testable seam.
    ///
    /// Coverage:
    ///   * FM success uses the generated phrase verbatim
    ///   * FM success with empty body keeps the generated title + empty body
    ///   * FM success with empty title falls back to static title but keeps
    ///     the generated body if present
    ///   * Every `FallbackReason` value maps to the static template
    ///   * `safetyRefused` specifically (regression-anchor for the MDR
    ///     contract — we MUST NOT ship a refused phrase even if it looks
    ///     populated)
    @Suite("NotificationService — smart-reminder phrase resolution (D-1)")
    @MainActor
    struct NotificationServiceSmartReminderTests {
        // MARK: - FM happy path

        @Test("FM success uses generated title + body verbatim")
        func fmSuccessUsesGeneratedPair() {
            let phrase = ReminderPhrase(title: "Schon Mittag — denk an Trulicity", body: "Drei Tage in Folge pünktlich.")
            let outcome = ReminderPhraseOutcome.success(phrase)
            let pair = NotificationService.resolveReminderPhrase(
                outcome: outcome,
                fallbackTitle: "Medikation",
                fallbackBody: "Erinnerung an deine Dosis"
            )
            #expect(pair.title == "Schon Mittag — denk an Trulicity")
            #expect(pair.body == "Drei Tage in Folge pünktlich.")
        }

        @Test("FM success with empty body keeps generated title + empty body")
        func fmSuccessEmptyBodyKeepsTitle() {
            let phrase = ReminderPhrase(title: "Trulicity Reminder", body: "")
            let outcome = ReminderPhraseOutcome.success(phrase)
            let pair = NotificationService.resolveReminderPhrase(
                outcome: outcome,
                fallbackTitle: "Medikation",
                fallbackBody: "Erinnerung an deine Dosis"
            )
            #expect(pair.title == "Trulicity Reminder")
            #expect(pair.body.isEmpty)
        }

        @Test("FM success with empty title falls back to static title")
        func fmSuccessEmptyTitleFallsBack() {
            // Defensive: model returned an empty title field. The MDR pre-
            // filter does not check for emptiness. We must not ship "" as a
            // notification title — fall back to the static template.
            let phrase = ReminderPhrase(title: "   ", body: "Sanfter Nachhol-Hinweis")
            let outcome = ReminderPhraseOutcome.success(phrase)
            let pair = NotificationService.resolveReminderPhrase(
                outcome: outcome,
                fallbackTitle: "Medikation",
                fallbackBody: "Erinnerung an deine Dosis"
            )
            #expect(pair.title == "Medikation")
            #expect(pair.body == "Sanfter Nachhol-Hinweis")
        }

        @Test("FM success with empty title + empty body fully falls back")
        func fmSuccessEmptyPairFullyFallsBack() {
            let phrase = ReminderPhrase(title: "", body: "  \n  ")
            let outcome = ReminderPhraseOutcome.success(phrase)
            let pair = NotificationService.resolveReminderPhrase(
                outcome: outcome,
                fallbackTitle: "Medikation",
                fallbackBody: "Erinnerung an deine Dosis"
            )
            #expect(pair.title == "Medikation")
            #expect(pair.body == "Erinnerung an deine Dosis")
        }

        // MARK: - Fallback paths (every reason maps to static template)

        @Test(
            "Every FallbackReason ships the static fallback pair",
            arguments: ReminderPhraseOutcome.FallbackReason.allCases
        )
        func fallbackPathsShipStaticTemplate(reason: ReminderPhraseOutcome.FallbackReason) {
            let outcome = ReminderPhraseOutcome.fallback(reason)
            let pair = NotificationService.resolveReminderPhrase(
                outcome: outcome,
                fallbackTitle: "Statische Medikation",
                fallbackBody: "Erinnerung an deine Dosis"
            )
            #expect(pair.title == "Statische Medikation")
            #expect(pair.body == "Erinnerung an deine Dosis")
        }

        // MARK: - Safety regression-anchor

        @Test("safetyRefused must never ship a phrase even if the outcome were populated")
        func safetyRefusedShipsStaticTemplate() {
            // The service contract is that `.refused` paths never populate
            // `outcome.phrase`. Belt-and-braces: even if a future bug populated
            // both, the resolver must take the fallback because `phrase` is
            // the only signal. Here we assert the canonical shape.
            let outcome = ReminderPhraseOutcome.fallback(.safetyRefused)
            let pair = NotificationService.resolveReminderPhrase(
                outcome: outcome,
                fallbackTitle: "Sicheres Statisches",
                fallbackBody: "Body"
            )
            #expect(pair.title == "Sicheres Statisches")
            #expect(pair.body == "Body")
            #expect(outcome.phrase == nil)
        }
    }

    /// Make `FallbackReason` iterable for the parameterised test. The enum is
    /// already `String`-raw so this is a free conformance.
    extension ReminderPhraseOutcome.FallbackReason: @retroactive CaseIterable {
        public static var allCases: [ReminderPhraseOutcome.FallbackReason] {
            [
                .deviceIneligible,
                .appleIntelligenceDisabled,
                .modelNotReady,
                .featureFlagDisabled,
                .safetyRefused,
                .generationFailed,
                .frameworkUnavailable,
                .emptyInput
            ]
        }
    }
#endif
