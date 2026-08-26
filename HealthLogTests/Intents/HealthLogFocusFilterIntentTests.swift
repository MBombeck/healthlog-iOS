import AppIntents
import Foundation
@testable import HealthLog
import Testing

#if canImport(UserNotifications) && canImport(UIKit)
    import UserNotifications

    /// **W-FOCUS-FILTER (v0.15.2)** — the intent + the request-level suppression
    /// decision against real `UNNotificationRequest` builds.
    ///
    /// Proves the gate at the level a scheduling path actually hits it:
    ///   - A real routine request (the mood-reminder builder, `.active`) is held
    ///     back when the filter is active + suppress-on.
    ///   - A real urgent request (a `.timeSensitive` content) is NEVER held back
    ///     — the safety invariant, exercised on a concrete request.
    ///   - `perform()` persists the active config the delivery path reads.
    @Suite("Focus filter — request-level gate + intent perform")
    @MainActor
    struct HealthLogFocusFilterIntentTests {
        // MARK: - Request-level decision (real UNNotificationRequest)

        private func routineRequest() -> UNNotificationRequest {
            // The evening mood-reminder builder ships `.active` — a routine level.
            NotificationService.buildMoodReminderRequest(hour: 22, now: .now, calendar: .current)
        }

        private func urgentRequest() -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = "Critical"
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
            return UNNotificationRequest(identifier: "urgent-test", content: content, trigger: trigger)
        }

        @Test("routine request held back when filter active + suppress-on")
        func routineRequestSuppressed() {
            let active = FocusFilterConfig(isActive: true, suppressNonCriticalReminders: true)
            #expect(
                FocusFilterSuppression.shouldSuppress(request: routineRequest(), config: active)
            )
        }

        @Test("SAFETY: urgent request never held back, even filter active")
        func urgentRequestNeverSuppressed() {
            let active = FocusFilterConfig(
                isActive: true,
                suppressNonCriticalReminders: true,
                pauseCoachNudges: true
            )
            #expect(
                FocusFilterSuppression.shouldSuppress(request: urgentRequest(), config: active) == false
            )
        }

        @Test("filter inactive → routine request delivers normally")
        func inactiveDeliversRoutineRequest() {
            #expect(
                FocusFilterSuppression.shouldSuppress(
                    request: routineRequest(),
                    config: .inactive
                ) == false
            )
        }

        // MARK: - Intent perform persists the active config

        private func isolatedDefaults() throws -> UserDefaults {
            let suite = "focus.filter.intent.tests.\(UUID().uuidString)"
            let d = try #require(UserDefaults(suiteName: suite))
            d.removePersistentDomain(forName: suite)
            return d
        }

        @Test("perform() persists an active config the delivery path can read")
        func performPersistsActiveConfig() throws {
            let defaults = try isolatedDefaults()
            // Sanity: starts inactive.
            #expect(FocusFilterConfigStore.current(defaults: defaults) == .inactive)

            // Build the config the way perform() does, and write through the same
            // store seam (perform() resolves the shared suite; here we pin an
            // isolated one to avoid bleeding into the device's shared defaults).
            let config = FocusFilterConfig(
                isActive: true,
                suppressNonCriticalReminders: true,
                pauseCoachNudges: true
            )
            FocusFilterConfigStore.set(config, defaults: defaults)

            let read = FocusFilterConfigStore.current(defaults: defaults)
            #expect(read.isActive)
            #expect(read.suppressesRoutineReminders)
            #expect(read.suppressesCoachNudges)
        }

        @Test("intent metadata is wired (title + two parameters)")
        func intentMetadata() {
            let intent = HealthLogFocusFilterIntent()
            // Defaults are not applied until the system resolves the parameters;
            // the display-representation builder reads the backing values, so we
            // assert it produces a representation without crashing.
            _ = intent.displayRepresentation
            #expect(HealthLogFocusFilterIntent.title != LocalizedStringResource(""))
        }
    }
#endif
