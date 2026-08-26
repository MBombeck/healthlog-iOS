import Foundation
@testable import HealthLog
import Testing

/// **W-THRESHOLD-NUDGE — the coordinator + the persistence stores.**
///
/// Exercises the full decision-to-delivery wiring with injected seams (no
/// `UNUserNotificationCenter`, no network): opt-in gating, server-escalation
/// deference, the debounce record/skip cycle, the in-range clear, and the
/// pref / debounce UserDefaults stores in isolation.
@Suite("W-THRESHOLD-NUDGE — coordinator + stores")
@MainActor
struct ThresholdNudgeCoordinatorTests {
    // MARK: - Fixtures + a recording fake

    private func lab(
        analyte: String = "Glucose",
        value: Double = 250,
        referenceLow: Double? = 70,
        referenceHigh: Double? = 180,
        biomarkerId: String? = "bm-1",
        rangeStatus: LabRangeStatus
    ) -> LabResultDTO {
        LabResultDTO(
            id: UUID().uuidString,
            biomarkerId: biomarkerId,
            panel: nil,
            analyte: analyte,
            value: value,
            unit: "mg/dL",
            referenceLow: referenceLow,
            referenceHigh: referenceHigh,
            takenAt: "2026-06-21T08:00:00Z",
            source: "MANUAL",
            hasNote: false,
            rangeStatus: rangeStatus,
            createdAt: "2026-06-21T08:00:00Z",
            updatedAt: "2026-06-21T08:00:00Z"
        )
    }

    /// Mutable scratch state so the injected closures behave like the real
    /// stores within a single test.
    private final class Recorder {
        var scheduled: [(ThresholdNudgeContent, String)] = []
        var nudgedKeys: Set<String> = []
        var clearedKeys: [String] = []
    }

    private func makeCoordinator(
        optedIn: Bool,
        escalated: Bool,
        recorder: Recorder
    ) -> ThresholdNudgeCoordinator {
        ThresholdNudgeCoordinator(
            isOptedIn: { optedIn },
            serverHasEscalated: { _ in escalated },
            isDebounced: { recorder.nudgedKeys.contains($0) },
            recordNudge: { recorder.nudgedKeys.insert($0) },
            clearDebounce: { recorder.clearedKeys.append($0)
                recorder.nudgedKeys.remove($0)
            },
            schedule: { content, key in
                recorder.scheduled.append((content, key))
                return true
            }
        )
    }

    // MARK: - Decision-to-delivery

    @Test("Opted-in out-of-range reading schedules exactly one nudge + records debounce")
    func optedInSchedulesOnce() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(optedIn: true, escalated: false, recorder: recorder)
        let decision = await coordinator.handleCreatedLab(lab(rangeStatus: .above))
        guard case .nudge = decision else {
            Issue.record("expected a nudge")
            return
        }
        #expect(recorder.scheduled.count == 1)
        #expect(recorder.nudgedKeys.count == 1)
    }

    @Test("Standing breach does NOT re-schedule on a second reading")
    func standingBreachDebounced() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(optedIn: true, escalated: false, recorder: recorder)
        _ = await coordinator.handleCreatedLab(lab(rangeStatus: .above))
        let second = await coordinator.handleCreatedLab(lab(rangeStatus: .above))
        #expect(second == .suppress(.debounced))
        #expect(recorder.scheduled.count == 1) // still just the first
    }

    @Test("Server escalation suppresses delivery (no double-nudge)")
    func serverEscalationDefers() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(optedIn: true, escalated: true, recorder: recorder)
        let decision = await coordinator.handleCreatedLab(lab(rangeStatus: .above))
        #expect(decision == .suppress(.serverEscalated))
        #expect(recorder.scheduled.isEmpty)
    }

    @Test("Opt-in off schedules nothing")
    func optedOutSchedulesNothing() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(optedIn: false, escalated: false, recorder: recorder)
        _ = await coordinator.handleCreatedLab(lab(rangeStatus: .above))
        #expect(recorder.scheduled.isEmpty)
    }

    @Test("An in-range reading clears the standing debounce so a relapse can re-nudge")
    func inRangeClearsDebounceForRelapse() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(optedIn: true, escalated: false, recorder: recorder)
        // First breach nudges.
        _ = await coordinator.handleCreatedLab(lab(rangeStatus: .above))
        #expect(recorder.scheduled.count == 1)
        // Recovery clears both directions.
        _ = await coordinator.handleCreatedLab(lab(value: 100, rangeStatus: .inRange))
        #expect(recorder.clearedKeys.contains { $0.hasSuffix("#above") })
        // A relapse breach nudges again (debounce was cleared).
        _ = await coordinator.handleCreatedLab(lab(rangeStatus: .above))
        #expect(recorder.scheduled.count == 2)
    }

    // MARK: - Pref store

    @Test("Opt-in pref defaults OFF + round-trips")
    func prefStoreRoundTrip() throws {
        let defaults = try makeDefaults("pref")
        #expect(ThresholdNudgePrefStore.isEnabled(defaults: defaults) == false)
        ThresholdNudgePrefStore.setEnabled(true, defaults: defaults)
        #expect(ThresholdNudgePrefStore.isEnabled(defaults: defaults) == true)
        ThresholdNudgePrefStore.setEnabled(false, defaults: defaults)
        #expect(ThresholdNudgePrefStore.isEnabled(defaults: defaults) == false)
    }

    // MARK: - Debounce store

    @Test("Debounce store: records, holds within cool-down, clears, expires")
    func debounceStoreLifecycle() throws {
        let defaults = try makeDefaults("debounce")
        let key = "bm-1#above"
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ThresholdNudgeDebounceStore.isDebounced(key: key, now: now, defaults: defaults) == false)
        ThresholdNudgeDebounceStore.recordNudge(key: key, now: now, defaults: defaults)
        // Within the cool-down → debounced.
        #expect(ThresholdNudgeDebounceStore.isDebounced(
            key: key, now: now.addingTimeInterval(3600), defaults: defaults
        ) == true)
        // After the cool-down → free again.
        #expect(ThresholdNudgeDebounceStore.isDebounced(
            key: key, now: now.addingTimeInterval(25 * 3600), defaults: defaults
        ) == false)
        // Explicit clear releases it immediately.
        ThresholdNudgeDebounceStore.recordNudge(key: key, now: now, defaults: defaults)
        ThresholdNudgeDebounceStore.clear(key: key, defaults: defaults)
        #expect(ThresholdNudgeDebounceStore.isDebounced(
            key: key, now: now.addingTimeInterval(60), defaults: defaults
        ) == false)
    }

    @Test("Debounce clearAll wipes the map (logout)")
    func debounceClearAll() throws {
        let defaults = try makeDefaults("debounce.clear")
        let now = Date(timeIntervalSince1970: 1_000_000)
        ThresholdNudgeDebounceStore.recordNudge(key: "a#above", now: now, defaults: defaults)
        ThresholdNudgeDebounceStore.recordNudge(key: "b#below", now: now, defaults: defaults)
        ThresholdNudgeDebounceStore.clearAll(defaults: defaults)
        #expect(ThresholdNudgeDebounceStore.isDebounced(key: "a#above", now: now, defaults: defaults) == false)
        #expect(ThresholdNudgeDebounceStore.isDebounced(key: "b#below", now: now, defaults: defaults) == false)
    }

    private func makeDefaults(_ tag: String) throws -> UserDefaults {
        let suite = "test.thresholdNudge.\(tag).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

#if canImport(UserNotifications) && canImport(UIKit)
    import UserNotifications

    /// **W-THRESHOLD-NUDGE — the delivered banner is NEVER urgent.** The hard
    /// safety property: an out-of-range nudge fires at `.passive` so it is
    /// informational + Focus-suppressible, never `.timeSensitive` / `.critical`.
    @Suite("W-THRESHOLD-NUDGE — notification level is never urgent")
    @MainActor
    struct ThresholdNudgeNotificationTests {
        @Test("The built request is .passive (never timeSensitive/critical) + Focus-routine")
        func levelIsPassiveAndRoutine() {
            let content = ThresholdNudgeContent(
                title: "A reading is outside your range",
                body: "Your Glucose reading of 250 mg/dL is above the range you set (70–180).\nThis is an informational reminder, not medical advice.",
                deepLink: URL(string: "healthlog://labs")
            )
            let request = NotificationService.buildThresholdNudgeRequest(content, breachKey: "bm-1#above")
            #expect(request.content.interruptionLevel == .passive)
            #expect(request.content.interruptionLevel != .timeSensitive)
            #expect(request.content.interruptionLevel != .critical)
            // The Focus filter classifies it routine, so a HealthLog Focus filter
            // can hold it back (never gains urgent exemption).
            let urgency = FocusFilterSuppression.urgency(for: request.content.interruptionLevel)
            #expect(urgency == .routine)
            #expect(request.content.categoryIdentifier == NotificationService.categoryThresholdNudge)
        }

        @Test("Focus filter holds back the out-of-range nudge when suppress-on")
        func focusFilterSuppressesNudge() {
            let content = ThresholdNudgeContent(
                title: "t", body: "b", deepLink: nil
            )
            let request = NotificationService.buildThresholdNudgeRequest(content, breachKey: "k#above")
            let active = FocusFilterConfig(
                isActive: true,
                suppressNonCriticalReminders: true,
                pauseCoachNudges: false
            )
            #expect(FocusFilterSuppression.shouldSuppress(request: request, config: active) == true)
        }
    }
#endif
