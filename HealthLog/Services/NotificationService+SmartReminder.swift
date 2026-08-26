import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    /// D-1 — Smart-reminder scheduling extension for `NotificationService`.
    ///
    /// Wraps the existing static-template `scheduleLocalReminder(...)` with an
    /// on-device `SmartReminderPhraseService` call. The flow is:
    ///
    /// 1. Caller hands over a `ReminderPhraseContext` (medication name, slot,
    ///    streak, missed-previous flag) plus the *static* fallback title/body
    ///    that should ship if anything in the FM path falls back.
    /// 2. We ask `SmartReminderPhraseService` for a phrase. On any fallback
    ///    reason — device-ineligible (iOS 18-25 / non-Apple-Intelligence),
    ///    Apple Intelligence disabled, model not ready, feature flag off,
    ///    safety refused, framework unavailable, generation failed, empty
    ///    input — we use the static fallback as-is.
    /// 3. On success we use the FM-generated `title` + `body`. If the FM
    ///    decided to leave the body empty (preferred when there is nothing
    ///    contextual to add), we still ship the title — the static body is
    ///    NOT mixed in to avoid a hybrid voice.
    /// 4. The actual `UNUserNotificationCenter.add(...)` call delegates to
    ///    the existing `scheduleLocalReminder(id:title:body:at:)` so all
    ///    category/sound/trigger semantics stay identical.
    ///
    /// **MDR boundary (R4 §5):** the smart phrase is a scheduling reminder,
    /// never a clinical instruction. The `MDRSafetyFilter` already filtered
    /// the FM output before we see it — if any forbidden pattern slipped
    /// through, the service returns `.fallback(.safetyRefused)` and we ship
    /// the static template instead.
    extension NotificationService {
        /// Schedules a local medication reminder using on-device-AI-generated
        /// phrasing where available, falling back to a static template on
        /// older OS / disabled Apple Intelligence / off feature-flag / safety
        /// refusal / generation error.
        ///
        /// - Parameters:
        ///   - id: Identifier handed to `UNUserNotificationCenter.add(...)`.
        ///   - context: `ReminderPhraseContext` for the FM pass.
        ///   - fallbackTitle: Static title shipped on any fallback path.
        ///   - fallbackBody: Static body shipped on any fallback path.
        ///   - date: Scheduled fire date (passed through to the trigger).
        ///   - phraseService: Injection seam — defaults to a fresh actor
        ///     instance. AppContainer owns the long-lived service in prod;
        ///     tests inject stubs.
        ///   - locale: Locale for the FM prompt + instructions. Defaults to
        ///     the device locale.
        /// - Returns: The `ReminderPhraseOutcome` so callers can log which
        ///   path was taken without re-running the service. Useful for
        ///   tests + the eventual analytics card.
        @discardableResult
        func scheduleSmartLocalReminder(
            id: String,
            context: ReminderPhraseContext,
            fallbackTitle: String,
            fallbackBody: String,
            at date: Date,
            category: String? = nil,
            userInfo: [String: Any] = [:],
            phraseService: SmartReminderPhraseService = SmartReminderPhraseService(),
            locale: Locale = .current
        ) async throws -> ReminderPhraseOutcome {
            let outcome = await phraseService.generate(context: context, locale: locale)
            let (title, body) = resolvePhrase(
                outcome: outcome,
                fallbackTitle: fallbackTitle,
                fallbackBody: fallbackBody
            )
            // Fallback-reason enum raw value — operator-grade.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.notifications.info(
                "scheduleSmartLocalReminder fallback=\(outcome.fallbackReason?.rawValue ?? "none", privacy: .public)"
            )
            // W-MED (v0.5.5): forward category + userInfo so the banner
            // carries the 3-button MEDICATION_REMINDER chrome when used
            // by the medication-reminder orchestrator. Defaults preserve
            // the legacy non-categorised reminder shape.
            try await scheduleLocalReminder(
                id: id,
                title: title,
                body: body,
                at: date,
                category: category,
                userInfo: userInfo
            )
            return outcome
        }

        /// Pure helper — given a `ReminderPhraseOutcome` and the static
        /// fallback strings, returns the final `(title, body)` pair.
        ///
        /// Exposed at internal-scope so the unit tests can exercise the
        /// resolution table without touching `UNUserNotificationCenter`
        /// (which is unavailable in the host-app-less test runner for the
        /// `add(...)` happy path).
        static func resolveReminderPhrase(
            outcome: ReminderPhraseOutcome,
            fallbackTitle: String,
            fallbackBody: String
        ) -> (title: String, body: String) {
            resolvePhrase(outcome: outcome, fallbackTitle: fallbackTitle, fallbackBody: fallbackBody)
        }
    }

    /// Free-function alias so the instance + static surfaces stay in lock-step.
    /// File-private to keep the resolution rule in one place.
    private func resolvePhrase(
        outcome: ReminderPhraseOutcome,
        fallbackTitle: String,
        fallbackBody: String
    ) -> (title: String, body: String) {
        guard let phrase = outcome.phrase else {
            return (fallbackTitle, fallbackBody)
        }
        // FM happy path. Prefer the generated title; the body may be empty by
        // design (model decided no contextual line is needed) — we honour
        // that rather than splicing in the static body.
        let title = phrase.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = phrase.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            // Defensive: the FM emitted an empty title. The MDR safety
            // pre-filter does not check for emptiness, so this is the one
            // legitimate fallback within the success branch.
            return (fallbackTitle, body.isEmpty ? fallbackBody : body)
        }
        return (title, body)
    }

#endif
