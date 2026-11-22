#if canImport(ActivityKit)
    import ActivityKit
    import Foundation

    /// **#190 — the app's side of the Activities the relay starts.**
    ///
    /// Forwards the push-to-start token of ``HealthLogDoseAttributes`` and
    /// the update token of every Activity the relay started to
    /// ``PushRelayStore`` (they reach the own server with `relayStart: true`),
    /// and fills the name of the started dose locally once the server says
    /// which one it is.
    @MainActor
    final class RelayDoseActivityObserver {
        private weak var store: PushRelayStore?
        private var tokens: [String: String] = [:]
        private var observed: Set<String> = []
        private var started = false

        init(store: PushRelayStore) {
            self.store = store
        }

        func start() {
            guard !started else { return }
            started = true
            Task { [weak self] in
                for await data in Activity<HealthLogDoseAttributes>.pushToStartTokenUpdates {
                    await self?.store?.notePushToStartToken(data.relayHex)
                }
            }
            Task { [weak self] in
                for await activity in Activity<HealthLogDoseAttributes>.activityUpdates {
                    self?.observe(activity)
                }
            }
            for activity in Activity<HealthLogDoseAttributes>.activities {
                observe(activity)
            }
        }

        private func observe(_ activity: Activity<HealthLogDoseAttributes>) {
            let id = activity.id
            guard observed.insert(id).inserted else { return }
            let counters = store?.deliveryCounters ?? PushDeliveryCounters()
            counters.note(.received, pushClass: .liveActivity)
            // D1 (9): without consent the relay's start does not stay.
            guard store?.allowsRelayActivities == true else {
                counters.note(.discarded, pushClass: .liveActivity)
                observed.remove(id)
                Task { await Self.endActivity(id: id) }
                return
            }
            counters.note(.opened, pushClass: .liveActivity)
            Task { [weak self] in
                // Every update the relay pushes counts as one delivery; one
                // after the consent went ends the Activity (D1 (9)).
                for await _ in activity.contentUpdates {
                    counters.note(.received, pushClass: .liveActivity)
                    guard self?.store?.allowsRelayActivities == true else {
                        counters.note(.discarded, pushClass: .liveActivity)
                        await Self.endActivity(id: id)
                        return
                    }
                    counters.note(.opened, pushClass: .liveActivity)
                }
            }
            Task { [weak self] in
                for await token in activity.pushTokenUpdates {
                    self?.tokens[id] = token.relayHex
                    await self?.publish()
                }
            }
            Task { [weak self] in
                for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                    self?.tokens.removeValue(forKey: id)
                    self?.observed.remove(id)
                    self?.dropLabelIfNoneRunning()
                    await self?.publish()
                }
            }
        }

        /// Ends one Activity of the relay by id. `nonisolated`, so the
        /// non-`Sendable` `Activity` is looked up and ended in one region and
        /// never crosses from the main actor (as in
        /// `MarkDoseFromLiveActivityIntent`).
        nonisolated static func endActivity(id: String) async {
            guard let activity = Activity<HealthLogDoseAttributes>.activities.first(where: { $0.id == id }) else { return }
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        /// R1 (3): the name belongs to the running Activity; once none runs,
        /// it goes, so the next start shows nothing of the last dose.
        private func dropLabelIfNoneRunning() {
            let running = Activity<HealthLogDoseAttributes>.activities.contains {
                $0.activityState == .active || $0.activityState == .stale
            }
            if !running { RelayLiveActivityLabel.write(nil) }
        }

        /// The consent went (switch off, relay off): every running Activity
        /// of the relay ends at once.
        func endAllWithoutConsent() async {
            guard store?.allowsRelayActivities != true else { return }
            for activity in Activity<HealthLogDoseAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        /// R1 (3): sign-out ends every Activity the relay started and removes
        /// the name of its dose.
        func endAllOnSignOut() async {
            RelayLiveActivityLabel.write(nil)
            for activity in Activity<HealthLogDoseAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            tokens = [:]
            await publish()
        }

        /// R1 (12): "Hide names" changed. The name goes at once and the
        /// running Activities render again; the widget checks the setting on
        /// every render as well.
        static func applyLockScreenPrivacy(hideNames: Bool) async {
            guard hideNames else { return }
            RelayLiveActivityLabel.write(nil)
            for activity in Activity<HealthLogDoseAttributes>.activities {
                await activity.update(activity.content)
            }
        }

        private func publish() async {
            await store?.noteRelayStartedActivityTokens(Array(tokens.values))
        }

        /// The started dose from `push.device.liveActivityStarted`: the name
        /// comes from the local medication list (or stays neutral when names
        /// stay off the lock screen), and the running Activities render again.
        func applyStartedDose(_ dose: RelayCapability.Device.StartedDose?, medications: [Medication]) async {
            let label = dose.flatMap { dose -> RelayLiveActivityLabel? in
                guard !LockScreenPrivacy.hideMedicationName(),
                      let medication = medications.first(where: { $0.id == dose.medicationId }) else { return nil }
                return RelayLiveActivityLabel(
                    medicationId: dose.medicationId,
                    slotInstant: dose.slotInstant,
                    title: medication.name,
                    detail: medication.dose
                )
            }
            guard label != RelayLiveActivityLabel.read() else { return }
            RelayLiveActivityLabel.write(label)
            for activity in Activity<HealthLogDoseAttributes>.activities {
                await activity.update(activity.content)
            }
        }
    }
#endif
