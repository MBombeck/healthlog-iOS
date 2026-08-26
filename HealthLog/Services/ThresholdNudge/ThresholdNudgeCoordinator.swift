import Foundation

/// **W-THRESHOLD-NUDGE (v0.15.2) — wires the pure decision to delivery on a
/// successful lab log.**
///
/// Called from ``LabsStore`` right after a lab result lands (and the
/// server-resolved row, carrying the server's `rangeStatus`, is back). It runs
/// the pure ``ThresholdNudgeEvaluator`` decision, then — only on a `.nudge` —
/// delivers ONE calm banner via the injected scheduler and records the debounce.
///
/// Every collaborator is an injected seam (the opt-in read, the
/// server-escalation probe, the debounce read/record, the scheduler, the clock)
/// so the coordinator is fully unit-testable without `UNUserNotificationCenter`,
/// without a network, and without `UIKit`.
///
/// **MDR posture.** This type adds NO clinical knowledge — it only routes the
/// server's own out-of-range verdict to a factual, retrospective, non-diagnostic
/// banner, and defers to the server when the server already escalated.
@MainActor
struct ThresholdNudgeCoordinator {
    /// Reads the opt-in (default off). Injected so tests don't touch
    /// `UserDefaults`.
    var isOptedIn: () -> Bool
    /// Probes whether the SERVER has already escalated this kind of reading
    /// (e.g. an active illness episode, a recent `MEASUREMENT_ANOMALY` /
    /// `SYSTEM_ALERT`). When `true` the client DEFERS — no double-nudge. The
    /// probe takes the lab so a future, kind-specific escalation map can refine
    /// it; today it is a conservative app-wide "is the server already
    /// escalating?" signal.
    var serverHasEscalated: (LabResultDTO) -> Bool
    /// `true` when this breach key already nudged within the cool-down.
    var isDebounced: (String) -> Bool
    /// Record that a breach key nudged now.
    var recordNudge: (String) -> Void
    /// Clear a breach key (called when a reading returns in-range, so a relapse
    /// can nudge again).
    var clearDebounce: (String) -> Void
    /// Delivers the decided content as a local banner. Returns whether it was
    /// added (false ⇒ Focus filter held it back). Async + injected.
    var schedule: (ThresholdNudgeContent, String) async -> Bool

    /// Run the decision for a freshly-created lab result. Returns the
    /// ``ThresholdNudgeEvaluator/Decision`` taken (for diagnostics / tests).
    ///
    /// Side effects, only on `.nudge`: deliver the banner + record the debounce.
    /// On an IN-RANGE reading it CLEARS any standing debounce for that
    /// kind/direction, so a future relapse can nudge again — never as an
    /// "all-clear" signal to the user, purely internal bookkeeping.
    @discardableResult
    func handleCreatedLab(_ lab: LabResultDTO) async -> ThresholdNudgeEvaluator.Decision {
        // In-range bookkeeping: a recovered reading clears BOTH breach directions
        // for this kind so the next genuine breach is treated as fresh. This is
        // internal only — it never surfaces a "you're fine" message.
        if lab.rangeStatus == .inRange {
            let marker = lab.biomarkerId ?? lab.analyte.lowercased()
            if !marker.isEmpty {
                clearDebounce("\(marker)#below")
                clearDebounce("\(marker)#above")
            }
        }

        let key = ThresholdNudgeEvaluator.debounceKey(for: lab)
        let decision = ThresholdNudgeEvaluator.evaluate(
            lab: lab,
            isOptedIn: isOptedIn(),
            serverHasEscalated: serverHasEscalated(lab),
            alreadyNudgedForBreach: key.map(isDebounced) ?? false
        )

        if case let .nudge(content) = decision, let key {
            // Record FIRST so a concurrent second log for the same standing
            // breach sees the debounce even if delivery is slow.
            recordNudge(key)
            _ = await schedule(content, key)
        }
        return decision
    }
}

#if canImport(UserNotifications) && canImport(UIKit)
    import UIKit
    import UserNotifications

    extension ThresholdNudgeCoordinator {
        /// Production wiring: opt-in from ``ThresholdNudgePrefStore``, debounce
        /// from ``ThresholdNudgeDebounceStore``, the server-escalation probe from
        /// the live ``IllnessStore`` (an active episode means the server is
        /// already in an escalated posture — defer), and delivery via
        /// ``NotificationService/scheduleThresholdNudge(_:breachKey:)``.
        static func live(
            notifications: NotificationService,
            illnessStore: IllnessStore?,
            defaults: UserDefaults = .standard
        ) -> ThresholdNudgeCoordinator {
            ThresholdNudgeCoordinator(
                isOptedIn: { ThresholdNudgePrefStore.isEnabled(defaults: defaults) },
                serverHasEscalated: { [weak illnessStore] _ in
                    // Conservative app-wide deference: while the server is
                    // escalating an illness episode, suppress the client nudge so
                    // the two never stack. (A future kind-specific map can narrow
                    // this; deferring more than necessary is the MDR-safe error.)
                    illnessStore?.hasActiveEpisode ?? false
                },
                isDebounced: { ThresholdNudgeDebounceStore.isDebounced(key: $0, defaults: defaults) },
                recordNudge: { ThresholdNudgeDebounceStore.recordNudge(key: $0, defaults: defaults) },
                clearDebounce: { ThresholdNudgeDebounceStore.clear(key: $0, defaults: defaults) },
                schedule: { [weak notifications] content, key in
                    guard let notifications else { return false }
                    return await notifications.scheduleThresholdNudge(content, breachKey: key)
                }
            )
        }
    }
#endif
