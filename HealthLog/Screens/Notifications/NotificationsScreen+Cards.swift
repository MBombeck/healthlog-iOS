import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(UserNotifications)
    import UserNotifications
#endif

/// `NotificationsScreen` reminder + permission card subviews (W1-5).
/// Extracted from `NotificationsScreen.swift` (file_length discipline — pure
/// move, no behaviour change).
extension NotificationsScreen {
    // MARK: - Cards (W1-5)

    var systemPermissionCard: some View {
        HLSettingsCard(icon: "bell.badge.fill", title: "Device permission") {
            HStack {
                Image(systemName: systemAuthorizationStatus.symbol)
                    .foregroundStyle(systemAuthorizationStatus.tint)
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(systemAuthorizationStatus.title)
                        .font(.hlSubhead.weight(.semibold))
                    Text(systemAuthorizationStatus.subtitle)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
                Spacer(minLength: HLSpace.sm)
            }
            // v0.6.0.8 Issue #10 fix A — the server-branch onboarding
            // flips AuthStore.phase to `.authenticated` before the
            // NotificationsPermissionStep can render, so the system
            // prompt is never shown. This card now exposes the
            // re-trigger directly: `.notDetermined` → call
            // requestAuthorization, `.denied` → deep-link to iOS
            // Settings, `.authorized` / `.provisional` → no button.
            if systemAuthorizationStatus == .notDetermined {
                Button {
                    Task { await requestSystemAuthorization() }
                } label: {
                    Label("Enable notifications", systemImage: "bell.fill")
                        .font(.hlSubhead)
                }
                .accessibilityIdentifier("notifications.systemPermission.request")
            }
            if systemAuthorizationStatus == .denied {
                Button {
                    openSystemSettings()
                } label: {
                    Label("Enable in Settings", systemImage: "arrow.up.right.square")
                        .font(.hlSubhead)
                }
                .accessibilityIdentifier("notifications.systemPermission.openSettings")
            }
        }
    }

    /// v0.6.0.8 — drives the system-permission prompt when the
    /// onboarding step never got a chance to fire it (server-branch
    /// race documented in Issue #10). Re-reads the status after the
    /// dialog closes so the card updates without a manual refresh.
    func requestSystemAuthorization() async {
        #if canImport(UserNotifications) && canImport(UIKit)
            guard let notif = container?.notifications else { return }
            _ = await notif.requestAuthorization()
            await refreshSystemStatus()
        #endif
    }

    /// v0.5.4.3 HP5 — opt-in card for the daily mood-reminder cron
    /// (server PR #190). Toggling the switch fires `PATCH /api/user/profile`
    /// with `{ moodReminderEnabled: true|false }`. On a fresh server
    /// (which surfaces the field) the toggle reflects the persisted
    /// state. On a legacy server that omits `moodReminderEnabled`, the
    /// toggle reads as off + flipping it on lands the value at next
    /// PATCH — older servers will reject the unknown key but newer ones
    /// will store it.
    ///
    /// Distinct from the per-event preferences card below: this gates
    /// whether the cron _generates_ a `MOOD_REMINDER` push at all, while
    /// the preferences toggles gate whether APNs delivers events that
    /// were generated. Both have to be on for the user to see a banner.
    @ViewBuilder
    var moodReminderCard: some View {
        let settingsStore = container?.settingsStore
        let currentValue = settingsStore?.profile?.moodReminderEnabled ?? false
        // UI-Standard R3/R7 (U6) — diese Karte ist die Heimat der Aussage über
        // die Stimmungs-Erinnerung; der Ereignis-Hint in der Kanal-Karte und
        // die Unterzeile „Abend-Erinnerung" am Schalter sind entfallen.
        //
        // **R7 — was der Footer nicht mehr behauptet.** Er sagte „nur an Tagen,
        // an denen du es noch nicht getan hast". Seit v0.14.1 H2 ist die
        // Erinnerung ein *repeating* `UNCalendarNotificationTrigger`, den iOS
        // ohne Zutun der App zustellt; die „heute schon erfasst"-Unterdrückung
        // sitzt im Vordergrund-Delegate (`willPresent`). Läuft die App zur
        // Auslösezeit im Hintergrund — der Normalfall abends —, kommt der
        // Hinweis auch dann, wenn die Stimmung längst erfasst ist. Der Satz
        // war also in genau dem häufigen Fall falsch und ist gefallen; was
        // bleibt, ist die Uhrzeit, und die stellt der DatePicker unten ein.
        HLSettingsCard(
            icon: "face.smiling",
            title: "Mood reminder",
            footer: "A gentle nudge at the reminder time you set."
        ) {
            Toggle(
                isOn: Binding(
                    get: { currentValue },
                    set: { newValue in
                        Task {
                            moodReminderInFlight = true
                            await settingsStore?.updateMoodReminderEnabled(newValue)
                            moodReminderInFlight = false
                        }
                    }
                )
            ) {
                HStack(spacing: HLSpace.sm) {
                    Text("Daily reminder")
                        .font(.hlHeadline)
                    if moodReminderInFlight {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .disabled(settingsStore == nil || moodReminderInFlight)
            .accessibilityIdentifier("NotificationsScreen.moodReminderToggle")

            // v0.10.0 W-Mood-B — the user-settable reminder time (server
            // `notificationPrefs.mood.reminderHour`, the source of truth for
            // the iOS-local trigger). Only shown when the reminder is on.
            if currentValue {
                Divider().opacity(0.5)
                DatePicker(
                    selection: Binding(
                        get: { moodReminderTimeBinding },
                        set: { newDate in
                            let hour = Calendar.current.component(.hour, from: newDate)
                            moodReminderHourSelection = hour
                            Task { await store?.setMoodReminderHour(hour) }
                        }
                    ),
                    displayedComponents: .hourAndMinute
                ) {
                    Text("Reminder time")
                        .font(.hlHeadline)
                }
                .accessibilityIdentifier("NotificationsScreen.moodReminderTime")
            }
        }
    }

    /// Resolve the reminder-time `Date` for the picker from the selected hour
    /// (local state) falling back to the store's server-mirrored hour. Minute
    /// is fixed at :00 — the reminder is hour-granular.
    var moodReminderTimeBinding: Date {
        let hour = moodReminderHourSelection ?? store?.moodReminderHour ?? 22
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        comps.hour = max(0, min(23, hour))
        comps.minute = 0
        return Calendar.current.date(from: comps) ?? .now
    }

    /// **MED-4 / AUDIT-PARITY C3 — low-supply alert.** Opt-in threshold for the
    /// runway warning: when a medication's projected days-of-supply drops to or
    /// below this many days, the server cron pushes a low-supply notification
    /// (deep-linking to that medication) and the medication card/detail render
    /// the runway ("≈ X Tage"). Toggling on lands the server default (7 days);
    /// the stepper tunes 1–60. Off sends an explicit `null` so the alert stops.
    @ViewBuilder
    var lowStockCard: some View {
        let isOn = store?.lowStockRunwayDays != nil
        HLSettingsCard(
            icon: "shippingbox",
            title: LocalizedStringKey("med.lowstock.title"),
            footer: LocalizedStringKey("med.lowstock.footer")
        ) {
            Toggle(
                isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        let target = newValue ? lowStockDaysSelection : nil
                        Task {
                            lowStockInFlight = true
                            await store?.setLowStockRunwayDays(target)
                            lowStockInFlight = false
                        }
                    }
                )
            ) {
                HStack(spacing: HLSpace.sm) {
                    Text(verbatim: String(localized: "med.lowstock.toggle.label"))
                        .font(.hlHeadline)
                    if lowStockInFlight {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .disabled(store == nil || lowStockInFlight)
            .accessibilityIdentifier("NotificationsScreen.lowStockToggle")

            if isOn {
                Divider().opacity(0.5)
                Stepper(
                    value: Binding(
                        get: { store?.lowStockRunwayDays ?? lowStockDaysSelection },
                        set: { newValue in
                            let clamped = max(medicationLowStockRunwayMin, min(medicationLowStockRunwayMax, newValue))
                            lowStockDaysSelection = clamped
                            Task { await store?.setLowStockRunwayDays(clamped) }
                        }
                    ),
                    in: medicationLowStockRunwayMin ... medicationLowStockRunwayMax
                ) {
                    HStack {
                        Text(verbatim: String(localized: "med.lowstock.threshold.label"))
                            .font(.hlHeadline)
                        Spacer(minLength: HLSpace.sm)
                        Text(
                            verbatim: String(
                                format: String(localized: "med.lowstock.threshold.value"),
                                store?.lowStockRunwayDays ?? lowStockDaysSelection
                            )
                        )
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .monospacedDigit()
                    }
                }
                .disabled(lowStockInFlight)
                .accessibilityIdentifier("NotificationsScreen.lowStockThreshold")
            }
        }
        .onAppear {
            if let days = store?.lowStockRunwayDays {
                lowStockDaysSelection = days
            }
        }
    }

    /// **W-B189 (#23) — preventive-care (Vorsorge) client-managed gate.** Mirrors
    /// the medication opt-in precedent: toggling fires
    /// `PATCH /api/auth/me/notification-prefs` with
    /// `{ measurementReminder: { clientManaged } }`. On a v1.17.1+ server the
    /// toggle reflects the persisted state; a legacy server rejects the key and
    /// the local mirror stays. Default off.
    ///
    /// **CU-26 / B1 — what the flag really does (server v1.33.1+).** It is a
    /// *suppression* flag, not an opt-in: `clientManaged = true` tells the server
    /// that this client owns the reminder, so the dispatcher skips the send.
    /// Until v1.33.1 that skip sat in the `measurement-reminder` cron and killed
    /// the **whole** dispatch — Telegram, ntfy, webhook, email and Web Push went
    /// silent with it. Since v1.33.1 the gate lives next to the channel loop
    /// (`lib/notifications/client-managed-apns.ts`) and suppresses exactly the
    /// **APNs** leg; every relay channel delivers again. The copy on this card
    /// says that, and it also says the part iOS has to own up to: the app
    /// schedules **no** local `MEASUREMENT_REMINDER` — there is no
    /// `UNCalendarNotificationTrigger` for it anywhere, unlike mood + low-supply.
    /// So flipping this on trades the Apple push for nothing on this platform.
    ///
    /// The per-event preferences card below is the separate, per-(channel ×
    /// event) switch — it gates whether a channel *delivers* the event at all.
    var measurementReminderCard: some View {
        HLSettingsCard(
            icon: "stethoscope",
            title: LocalizedStringKey("measurement.reminder.title"),
            footer: LocalizedStringKey("measurement.reminder.footer")
        ) {
            Toggle(
                isOn: Binding(
                    get: { store?.measurementReminderClientManaged ?? false },
                    set: { newValue in
                        Task {
                            measurementReminderInFlight = true
                            await store?.setMeasurementReminderClientManaged(newValue)
                            measurementReminderInFlight = false
                        }
                    }
                )
            ) {
                HStack(spacing: HLSpace.sm) {
                    Text(LocalizedStringKey("measurement.reminder.toggle.label"))
                        .font(.hlHeadline)
                    if measurementReminderInFlight {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
            .disabled(store == nil || measurementReminderInFlight)
            .accessibilityIdentifier("NotificationsScreen.measurementReminderToggle")

            // W-REMINDERS (#23 v1.18.1) — link into the live manage-reminders
            // list (GET /api/measurement-reminders). The toggle above gates
            // whether the cron *fires* the push; this surface lists + manages
            // the actual reminder rows (type / schedule / next-due / provenance)
            // and the manual "Erledigt" + delete + create actions.
            Divider().opacity(0.5)
            NavigationLink {
                MeasurementRemindersScreen()
            } label: {
                Label("reminders.manage.entry", systemImage: "list.bullet.clipboard")
                    .font(.hlSubhead)
            }
            .accessibilityIdentifier("NotificationsScreen.manageReminders")
        }
    }

    /// **W-B188 (AUDIT-SEC-b187 High) — lock-screen privacy.** Opt-in to hide
    /// the medication name on lock-screen surfaces (the medication-reminder
    /// notification title/body + the medication Live Activity). Default OFF —
    /// when ON, those surfaces render a generic "Medication reminder" label
    /// instead of the real drug name, so a stranger glancing at the locked
    /// phone can't read a sensitive medication. The Taken/Snooze/Skipped
    /// actions still work — only the visible text changes.
    var lockScreenPrivacyCard: some View {
        HLSettingsCard(
            icon: "lock.shield",
            title: LocalizedStringKey("notif.lockscreen.privacy.title"),
            footer: LocalizedStringKey("notif.lockscreen.hideName.footer")
        ) {
            Toggle(
                isOn: Binding(
                    get: { hideMedicationNameOnLockScreen },
                    set: { newValue in
                        hideMedicationNameOnLockScreen = newValue
                        LockScreenPrivacy.setHideMedicationName(newValue)
                    }
                )
            ) {
                Text(LocalizedStringKey("notif.lockscreen.hideName.label"))
                    .font(.hlHeadline)
            }
            .accessibilityIdentifier("NotificationsScreen.hideMedicationNameToggle")
        }
    }

    /// **W-THRESHOLD-NUDGE — opt-in out-of-range nudge.** A calm, retrospective
    /// reminder when a just-logged reading falls outside a range the user / their
    /// own data define. Default OFF. The footer copy sets expectations: what it
    /// does, that it is NOT medical advice, and that it only uses the user's /
    /// their data's own ranges. Device-local opt-in (`ThresholdNudgePrefStore`).
    var outOfRangeNudgeCard: some View {
        HLSettingsCard(
            icon: "ruler",
            title: LocalizedStringKey("threshold.nudge.settings.title"),
            footer: LocalizedStringKey("threshold.nudge.settings.footer")
        ) {
            Toggle(
                isOn: Binding(
                    get: { outOfRangeNudgeEnabled },
                    set: { newValue in
                        outOfRangeNudgeEnabled = newValue
                        ThresholdNudgePrefStore.setEnabled(newValue)
                    }
                )
            ) {
                Text(LocalizedStringKey("threshold.nudge.settings.label"))
                    .font(.hlHeadline)
            }
            .accessibilityIdentifier("NotificationsScreen.outOfRangeNudgeToggle")

            // Standing non-diagnostic disclaimer, surfaced right at the toggle so
            // the user understands the framing before opting in (MDR posture).
            Text(LocalizedStringKey("threshold.nudge.settings.disclaimer"))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("NotificationsScreen.outOfRangeNudgeDisclaimer")
        }
    }

    /// **W-FOCUS-FILTER** — honest explanation of the HealthLog Focus filter.
    /// The filter itself is configured in iOS Settings → Focus (not here); this
    /// read-only card tells the user what attaching it does, and that urgent
    /// health alerts are never held back.
    var focusFilterInfoCard: some View {
        HLSettingsCard(
            icon: "moon.circle",
            title: LocalizedStringKey("focus.filter.card.title"),
            footer: LocalizedStringKey("focus.filter.card.footer")
        ) {
            Text(LocalizedStringKey("focus.filter.card.body"))
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("NotificationsScreen.focusFilterInfo")
        }
    }
}
