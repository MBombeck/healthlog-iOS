import Foundation
@testable import HealthLog
import Testing

#if canImport(UserNotifications) && canImport(UIKit)
    import UserNotifications

    /// **W-FOCUS-FILTER (v0.15.2)** — coverage for the HealthLog Focus filter.
    ///
    /// Three load-bearing contracts:
    ///   1. **Safety invariant** — an urgent (`.timeSensitive` / `.critical`)
    ///      reminder is NEVER held back, even when the filter is active with
    ///      suppress-on. A routine (`.active` / `.passive`) reminder IS held back.
    ///   2. **Filter off / suppress off** — routine reminders deliver normally.
    ///   3. **Config persistence** — the intent's config round-trips through the
    ///      shared store, clears cleanly, and carries no PHI.
    ///
    /// The pure `FocusFilterSuppression.shouldSuppress(config:urgency:)` decision
    /// is exercised directly (no `UNUserNotificationCenter` needed); the
    /// interruption-level mapping is pinned against the real `UN…` levels.
    @Suite("Focus filter — suppression gate + config")
    @MainActor
    struct FocusFilterSuppressionTests {
        // MARK: - Safety invariant (urgent is NEVER suppressed)

        /// The hard safety invariant: with the filter active + suppress-on, an
        /// urgent escalation still comes through. This must never regress.
        @Test("URGENT is never suppressed — even filter-active + suppress-on")
        func urgentNeverSuppressed() {
            let active = FocusFilterConfig(
                isActive: true,
                suppressNonCriticalReminders: true,
                pauseCoachNudges: true
            )
            #expect(
                FocusFilterSuppression.shouldSuppress(config: active, urgency: .urgent) == false
            )
        }

        /// Both urgent interruption levels (`.critical`, `.timeSensitive`) map to
        /// the urgent class and thus are exempt from suppression.
        @Test("critical + timeSensitive levels classify URGENT and pass the gate")
        func criticalAndTimeSensitiveExempt() {
            let active = FocusFilterConfig(isActive: true, suppressNonCriticalReminders: true)
            for level: UNNotificationInterruptionLevel in [.critical, .timeSensitive] {
                #expect(FocusFilterSuppression.urgency(for: level) == .urgent)
                let urgency = FocusFilterSuppression.urgency(for: level)
                #expect(
                    FocusFilterSuppression.shouldSuppress(config: active, urgency: urgency) == false
                )
            }
        }

        // MARK: - Routine reminders ARE gated when active + suppress-on

        @Test("ROUTINE reminder is held back when filter active + suppress-on")
        func routineSuppressedWhenActive() {
            let active = FocusFilterConfig(isActive: true, suppressNonCriticalReminders: true)
            #expect(
                FocusFilterSuppression.shouldSuppress(config: active, urgency: .routine) == true
            )
        }

        @Test("active + passive levels classify ROUTINE")
        func activeAndPassiveAreRoutine() {
            for level: UNNotificationInterruptionLevel in [.active, .passive] {
                #expect(FocusFilterSuppression.urgency(for: level) == .routine)
            }
        }

        // MARK: - Filter off / suppress off → normal delivery

        @Test("filter inactive → routine delivers normally")
        func inactiveDeliversRoutine() {
            #expect(
                FocusFilterSuppression.shouldSuppress(
                    config: .inactive,
                    urgency: .routine
                ) == false
            )
        }

        @Test("filter active but suppress OFF → routine delivers normally")
        func activeSuppressOffDeliversRoutine() {
            let activeNoSuppress = FocusFilterConfig(
                isActive: true,
                suppressNonCriticalReminders: false
            )
            #expect(
                FocusFilterSuppression.shouldSuppress(
                    config: activeNoSuppress,
                    urgency: .routine
                ) == false
            )
        }

        // MARK: - Config helper flags

        @Test("suppressesRoutineReminders mirrors active ∧ suppress-on")
        func suppressesRoutineFlag() {
            #expect(FocusFilterConfig.inactive.suppressesRoutineReminders == false)
            #expect(
                FocusFilterConfig(isActive: true, suppressNonCriticalReminders: true)
                    .suppressesRoutineReminders == true
            )
            #expect(
                FocusFilterConfig(isActive: true, suppressNonCriticalReminders: false)
                    .suppressesRoutineReminders == false
            )
            #expect(
                FocusFilterConfig(isActive: false, suppressNonCriticalReminders: true)
                    .suppressesRoutineReminders == false
            )
        }

        @Test("suppressesCoachNudges requires active ∧ suppress ∧ pauseCoach")
        func suppressesCoachFlag() {
            #expect(
                FocusFilterConfig(
                    isActive: true,
                    suppressNonCriticalReminders: true,
                    pauseCoachNudges: true
                ).suppressesCoachNudges == true
            )
            // pauseCoach off → coach not suppressed even if reminders are.
            #expect(
                FocusFilterConfig(
                    isActive: true,
                    suppressNonCriticalReminders: true,
                    pauseCoachNudges: false
                ).suppressesCoachNudges == false
            )
            // suppress off → coach not suppressed.
            #expect(
                FocusFilterConfig(
                    isActive: true,
                    suppressNonCriticalReminders: false,
                    pauseCoachNudges: true
                ).suppressesCoachNudges == false
            )
        }

        // MARK: - Config persistence (round-trip / clear / no PHI)

        private func isolatedDefaults() throws -> UserDefaults {
            let suite = "focus.filter.tests.\(UUID().uuidString)"
            let d = try #require(UserDefaults(suiteName: suite))
            d.removePersistentDomain(forName: suite)
            return d
        }

        @Test("config round-trips through the store")
        func configRoundTrips() throws {
            let defaults = try isolatedDefaults()
            // Default (never written) → inactive.
            #expect(FocusFilterConfigStore.current(defaults: defaults) == .inactive)

            let config = FocusFilterConfig(
                isActive: true,
                suppressNonCriticalReminders: true,
                pauseCoachNudges: false
            )
            FocusFilterConfigStore.set(config, defaults: defaults)
            let read = FocusFilterConfigStore.current(defaults: defaults)
            #expect(read == config)
            #expect(read.isActive)
            #expect(read.suppressesRoutineReminders)
            #expect(read.suppressesCoachNudges == false)
        }

        @Test("clear() resets the store to inactive")
        func clearResetsToInactive() throws {
            let defaults = try isolatedDefaults()
            FocusFilterConfigStore.set(
                FocusFilterConfig(isActive: true, suppressNonCriticalReminders: true),
                defaults: defaults
            )
            #expect(FocusFilterConfigStore.current(defaults: defaults).isActive)

            FocusFilterConfigStore.clear(defaults: defaults)
            let read = FocusFilterConfigStore.current(defaults: defaults)
            #expect(read.isActive == false)
            #expect(read.suppressesRoutineReminders == false)
            #expect(read.suppressesCoachNudges == false)
        }

        /// The persisted blob is exactly the three config flags — no PHI. We
        /// assert the encoded JSON keys are the known UI-pref fields only.
        @Test("persisted config carries no PHI — only the three UI flags")
        func configHasNoPHI() throws {
            let defaults = try isolatedDefaults()
            FocusFilterConfigStore.set(
                FocusFilterConfig(
                    isActive: true,
                    suppressNonCriticalReminders: true,
                    pauseCoachNudges: true
                ),
                defaults: defaults
            )
            let data = try #require(defaults.data(forKey: FocusFilterConfigStore.configKey))
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let keys = try Set(#require(object).keys)
            #expect(keys == ["isActive", "suppressNonCriticalReminders", "pauseCoachNudges"])
        }
    }
#endif
