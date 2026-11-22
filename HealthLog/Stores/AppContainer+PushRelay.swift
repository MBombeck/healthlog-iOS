import Foundation
import UserNotifications
#if canImport(WidgetKit)
    import WidgetKit
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    // MARK: - Push relay (#190) and per-device delivery (#179)

    extension AppContainer {
        /// The relay store, hooked into the notification service: the
        /// registration body, the silent-push and tap gates, and the re-post.
        static func makePushRelay(
            api: APIClientProtocol,
            keychain: KeychainStoring,
            notifications: NotificationService
        ) -> PushRelayStore {
            let store = PushRelayStore(api: api, accountKey: {
                // R1 (5): `nil` without a signed-in account; the store then
                // keeps the key of the account it saw last (the sign-out
                // cascade runs after the user id left the keychain).
                guard let user = keychain.getString(forKey: KeychainKey.userID), !user.isEmpty else { return nil }
                let server = keychain.getString(forKey: KeychainKey.serverURL).flatMap { URL(string: $0)?.host } ?? ""
                return PushRelayStore.accountKey(userID: user, serverHost: server)
            })
            store.reRegister = { [weak notifications] in await notifications?.reRegisterWithCachedToken() }
            store.openHome = { [weak notifications] in
                if let url = URL(string: "healthlog://dashboard") { notifications?.deepLinks.handle(url) }
            }
            notifications.relayRegistrationProvider = { [weak store] tokenHex in
                store?.registrationFields(apnsTokenHex: tokenHex) ?? DeviceRegistrationPushFields()
            }
            notifications.relayActivityProof = { [weak store] laToken in
                store?.activityProof(liveActivityTokenHex: laToken)
            }
            notifications.relayRegistrationAnswer = { [weak store] device in
                store?.noteRegistrationAnswer(device)
            }
            notifications.relayRegistrationRejected = { [weak store] code in
                await store?.registrationRejected(code: code)
            }
            notifications.relayRegistrationAccepted = { [weak store] fields in
                store?.registrationAccepted(fields)
            }
            notifications.relayRegistrationFailed = { [weak store] in
                store?.registrationFailed()
            }
            store.onEnvelopeModeChanged = { [weak notifications] in notifications?.registerCategories() }
            store.liveActivityFeature = { RelayFeatures.contains(RelayFeatures.liveActivityRelay) }
            notifications.relaySilentGate = { [weak store] userInfo in
                await store?.silentDecision(userInfo: userInfo) ?? .notInEnvelopeMode
            }
            notifications.relayTapGate = { [weak store] identifier, isRemote, userInfo in
                store?.allowsTap(requestIdentifier: identifier, isRemote: isRemote, userInfo: userInfo) ?? true
            }
            return store
        }

        /// #179: the reminder planning's answer reaches `POST /api/devices`.
        /// #190 5.5: every logout path revokes the relay binding directly,
        /// without the server, and deletes the relay keys. It rides the
        /// notification purge at the tail of the logout cascade, which runs
        /// for every reason the session ended.
        func wireDeviceMedicationDelivery() {
            let service = notifications
            medicationReminderDelivery.onDeviceDelivery = { report in
                Task { await service.noteMedicationDelivery(report) }
            }
            wireRelayDataChanged()
            wireRelayFollowUps()
            wireRelayDoseActivities()
            let relay = pushRelay
            let purge = notificationClearOnLogoutHook
            notificationClearOnLogoutHook = { [weak relay] in
                await relay?.handleSignOut()
                await purge?()
            }
        }

        /// #191 `DATA_CHANGED`: the dashboard and the measurements reload, the
        /// widgets and the Watch follow from the stores' own hooks and are
        /// nudged once more. At most once every two minutes.
        func wireRelayDataChanged() {
            let dashboard = dashboardStore
            let measurements = measurementsStore
            let watch = watchSession
            let gate = RelayDataChangeGate()
            notifications.relayDataChanged = { [weak dashboard, weak measurements, weak watch] in
                guard gate.claim(now: .now) else { return false }
                await dashboard?.refresh(force: true)
                await measurements?.load(force: true)
                watch?.pushCurrentCoalesced()
                #if canImport(WidgetKit)
                    WidgetCenter.shared.reloadAllTimelines()
                #endif
                return true
            }
        }
    }

    extension AppContainer {
        /// #190 5.6: on every intake change, the local follow-up stages (a
        /// `client` device) or the fallback (a `server` device) are planned
        /// anew for today's open slots, while the relay is on. Taking a dose
        /// withdraws them through the slot in `userInfo`.
        func wireRelayFollowUps() {
            let relay = pushRelay
            let service = notifications
            let planner = RelayFollowUpPlanner()
            let previous = medicationsStore.onIntakesDidChange
            medicationsStore.onIntakesDidChange = { [weak medicationsStore, weak relay, weak service] in
                previous?()
                guard let medicationsStore, let relay, let service else { return }
                let mode = RelayFollowUps.mode(relayOn: relay.isOn, delivery: service.medicationDeliveryReport)
                let planned = Set(medicationsStore.medications
                    .filter(MedicationReminderDeliveryPolicy.plansLocalReminder(for:)).map(\.id))
                let open = Self.relayOpenDoses(in: medicationsStore.derivedTodayIntakes, planned: planned.contains)
                let requests = RelayFollowUps.plan(
                    open: open,
                    mode: mode,
                    now: .now,
                    delivered: mode == .fallback ? RelayDeliveredReminders().identifiers() : []
                )
                let medications = medicationsStore.medications
                planner.schedule { isCurrent in
                    await Self.applyRelayFollowUps(requests, medications: medications, isCurrent: isCurrent)
                }
            }
        }

        /// #190: Activities the relay starts (``HealthLogDoseAttributes``):
        /// their tokens go to the store, the started dose's name is filled
        /// locally from `push.device.liveActivityStarted`.
        func wireRelayDoseActivities() {
            #if canImport(ActivityKit)
                // #190 (20:09): the app's own Activity times its stale date and
                // its local changes on the server's window of the slot.
                medicationLiveActivityController.doseBand = { [weak medicationsStore] medicationId, slot in
                    medicationsStore?.derivedTodayIntakes.first {
                        $0.medicationId == medicationId && abs($0.scheduledAt.timeIntervalSince(slot)) < 60
                    }?.doseState
                }
                let observer = RelayDoseActivityObserver(store: pushRelay)
                pushRelay.retainedHelpers.append(observer)
                observer.start()
                // R1 (3): on sign-out the relay's Activities end too, and the
                // name of their dose goes with them.
                pushRelay.onSignOut = { [weak observer] in await observer?.endAllOnSignOut() }
                // D1 (9): without the consent no relay Activity stays.
                pushRelay.onLiveActivityConsentWithdrawn = { [weak observer] in await observer?.endAllWithoutConsent() }
                let medications = medicationsStore
                pushRelay.onLiveActivityStarted = { [weak observer, weak medications] dose in
                    let list = medications?.medications ?? []
                    Task { await observer?.applyStartedDose(dose, medications: list) }
                }
            #endif
        }

        /// Today's open slots with the server's window (`doseState`), the
        /// same source the medication cards grade by.
        ///
        /// **D3 (5), (11).** A missed dose is not open any more; a medication
        /// whose reminders are off (`planned` says no) gets no follow-up; and
        /// each dose carries its `missedAfter` and the medication's next slot,
        /// past which no stage fires.
        nonisolated static func relayOpenDoses(
            in intakes: [MedicationIntake],
            planned: (String) -> Bool = { _ in true }
        ) -> [RelayFollowUps.OpenDose] {
            intakes
                .filter { ($0.status == .pending || $0.status == .snoozed) && $0.doseState?.state != "missed" && planned($0.medicationId) }
                .map { intake in
                    let slot = MedicationReminderReopen.Slot(medicationId: intake.medicationId, scheduledAt: intake.scheduledAt)
                    let next = intakes
                        .filter { $0.medicationId == intake.medicationId && $0.scheduledAt > intake.scheduledAt }
                        .map(\.scheduledAt)
                        .min()
                    return RelayFollowUps.OpenDose(
                        medicationId: slot.medicationId,
                        slot: slot.scheduledAt,
                        overdueSince: intake.doseState?.overdueSince,
                        missedAfter: intake.doseState?.missedAfter,
                        nextSlot: next
                    )
                }
        }

        static func applyRelayFollowUps(
            _ requests: [RelayFollowUps.Request],
            medications: [Medication],
            isCurrent: @MainActor () -> Bool = { true }
        ) async {
            let center = UNUserNotificationCenter.current()
            let planned = Set(requests.map(\.identifier))
            // Only what is no longer planned goes; a planned id is replaced in
            // place by the add below.
            let stale = await center.pendingNotificationRequests().map(\.identifier)
                .filter { $0.hasPrefix(RelayFollowUps.prefix) && !planned.contains($0) }
            // R1 (7): a newer plan took over while this one waited; it owns
            // the pending requests now.
            guard isCurrent() else { return }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            for request in requests {
                guard isCurrent() else { return }
                guard let medication = medications.first(where: { $0.id == request.medicationId }) else { continue }
                let content = MedicationReminderReopen.content(
                    for: medication,
                    slot: .init(medicationId: request.medicationId, scheduledAt: request.slot)
                )
                try? await center.add(UNNotificationRequest(
                    identifier: request.identifier,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, request.fireAt.timeIntervalSinceNow), repeats: false)
                ))
            }
        }
    }

    /// **R1 (7) — the relay follow-ups are planned one plan at a time.**
    ///
    /// Every intake change plans anew. Run side by side, an older plan could
    /// add its requests after a newer one had removed them. Here a plan waits
    /// for the one before it, and a newer plan makes every older one stop at
    /// its next step.
    @MainActor
    final class RelayFollowUpPlanner {
        private var generation = 0
        private var tail: Task<Void, Never>?

        /// The newest plan; `isCurrent` turns false once a newer one arrives.
        @discardableResult
        func schedule(_ apply: @escaping @MainActor (_ isCurrent: @MainActor () -> Bool) async -> Void) -> Task<Void, Never> {
            generation += 1
            let mine = generation
            let previous = tail
            let task = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, mine == generation else { return }
                await apply { [weak self] in self?.generation == mine }
            }
            tail = task
            return task
        }
    }

    /// Remembers the last data-change reload.
    @MainActor
    final class RelayDataChangeGate {
        private var last: Date?

        func claim(now: Date) -> Bool {
            guard RelayDataChange.shouldReload(lastReload: last, now: now) else { return false }
            last = now
            return true
        }
    }

#endif
