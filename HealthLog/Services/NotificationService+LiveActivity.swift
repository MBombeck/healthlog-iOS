#if canImport(ActivityKit) && canImport(UserNotifications) && canImport(UIKit)
    import ActivityKit
    import Foundation

    /// **Live-Activity push-token sink.**
    ///
    /// `MedicationLiveActivityController` forwards two kinds of ActivityKit
    /// push tokens here:
    /// - a **push-to-start** token (one per app install, lets the server
    ///   *start* a Live Activity remotely), and
    /// - per-activity **update** tokens (one per running Activity, lets the
    ///   server push `update` / `end` to that specific Activity).
    ///
    /// The local lifecycle does **not** depend on this — the controller
    /// starts / updates / ends Activities itself. This sink only prepares
    /// the *push* path so the server can later drive Live Activities over
    /// the existing APNs pipeline.
    ///
    /// **Server contract (LIVE on server ≥ v1.17.1 — W-B189 / #22):** the
    /// Live-Activity push token reaches the server next to the existing APNs
    /// device token via `POST /api/devices` (optional `liveActivityPushToken`
    /// field). When present, the server sends a direct
    /// `apns-push-type: liveactivity` `end`/`update` push to the running
    /// Activity (topic `dev.healthlog.app.push-type.liveactivity`) so a remote
    /// intake clears the lock-screen countdown even with the app fully closed.
    /// Each new token arriving here triggers an idempotent re-registration
    /// (`reRegisterForLiveActivityTokenChange()`), whose dedup is keyed on the
    /// LA token so only a *changed* token re-POSTs.
    extension NotificationService: LiveActivityPushTokenSink {
        func didReceivePushToStartToken(_ tokenHex: String) async {
            let changed = liveActivityPushToStartToken != tokenHex
            liveActivityPushToStartToken = tokenHex
            HLLog.notifications.info(
                "LiveActivity push-to-start token received len=\(tokenHex.count)"
            )
            // Forward the current LA token to POST /api/devices.
            // Re-register only on an actual token change so we never spam the
            // endpoint with an unchanged token (the register(...) dedup also
            // guards this — belt-and-suspenders).
            if changed {
                await reRegisterForLiveActivityTokenChange()
            }
        }

        func didReceiveActivityUpdateToken(_ tokenHex: String, owner: LiveActivityTokenOwner) async {
            let changed = liveActivityUpdateTokens.upsert(tokenHex, owner: owner)
            HLLog.notifications.info(
                "LiveActivity update token received med=\(owner.medicationId, privacy: .private) len=\(tokenHex.count)"
            )
            // The per-activity update token is the one that can
            // push to a *running* Activity, so forward it to POST /api/devices.
            // Re-register only when this Activity's token actually changed.
            if changed {
                await reRegisterForLiveActivityTokenChange()
            }
        }

        func didEndActivity(activityID: String) async {
            guard liveActivityUpdateTokens.remove(activityID: activityID) else { return }
            await reRegisterForLiveActivityTokenChange()
        }

        func retainActivities(ids: Set<String>) async {
            guard liveActivityUpdateTokens.retain(activityIDs: ids) else { return }
            await reRegisterForLiveActivityTokenChange()
        }

        /// The Live-Activity push token forwarded to the server
        /// on `POST /api/devices`. Prefers a per-activity **update** token (the
        /// only token that can push to a *running* Activity); the push-to-start
        /// token is a device-level fallback so the field is non-nil as soon as
        /// ActivityKit has delivered anything.
        ///
        /// **#188 (2):** the update token is the one of a *running* Activity,
        /// the earliest slot (``LiveActivityTokenRegistry/primaryToken``), never
        /// an arbitrary `.values.first` of a map that kept ended Activities.
        /// The per-Activity list rides next to it (``currentLiveActivityTokens``).
        ///
        /// A device that does not plan reminders (an iPad next to an active
        /// iPhone, ``ReminderDevicePolicy``) sends none, so the server does not
        /// start a second Live Activity there.
        var currentLiveActivityPushToken: String? {
            guard plansLocalReminders() else { return nil }
            return liveActivityUpdateTokens.primaryToken ?? liveActivityPushToStartToken
        }

        /// **#191 — every running Activity's token**, with its medication and
        /// slot, for `POST /api/devices`. The list is the device's full current
        /// set: the server replaces what it stored, an empty list clears it.
        /// `nil` (field omitted, stored list unchanged) only while
        /// ``MedicationCapability/liveActivityTokensPerActivity`` is shut. A
        /// device that plans no reminders sends the empty list.
        var currentLiveActivityTokens: [LiveActivityTokenWire]? {
            guard LiveActivityPerActivityTokens.isAvailable() else { return nil }
            guard plansLocalReminders() else { return [] }
            return LiveActivityPerActivityTokens.wireEntries(liveActivityUpdateTokens)
        }

        /// Re-issue `POST /api/devices` after a new Live-Activity
        /// push token arrives at the sink, so the server holds the *current*
        /// token to push the running Activity. Reuses the cached APNs token; the
        /// `register(...)` dedup (now keyed on the LA token too) drops the call
        /// when the LA token is unchanged — so repeated identical tokens never
        /// spam the endpoint, only a genuine token change re-registers. No-op
        /// until the OS has delivered an APNs token at least once (the LA token
        /// rides on the same device row, so there is nothing to send alone).
        func reRegisterForLiveActivityTokenChange() async {
            guard let snapshot = lastRegistrationSnapshot,
                  let tokenHex = snapshot.fullTokenHex,
                  let env = APNsEnvironment(rawValue: snapshot.environment ?? "") else
            {
                HLLog.notifications.debug(
                    "LA token change: no cached APNs token yet — deferring re-registration."
                )
                return
            }
            await register(tokenHex: tokenHex, env: env, forceFresh: false)
        }
    }
#endif
