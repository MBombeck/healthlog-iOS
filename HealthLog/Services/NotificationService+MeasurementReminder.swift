import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    /// **W-B189 (#23) — `MEASUREMENT_REMINDER` (preventive-care / Vorsorge)
    /// action handlers**, split out of `NotificationService.swift` to keep the
    /// parent file under the SwiftLint LOC ceiling.
    ///
    /// The server (v1.17.1) rides the generic APNs category for these reminders
    /// today (plain-alert fallback); the dedicated `categoryMeasurementReminder`
    /// adds an "Erledigt"/complete action for parity with the med/mood reminder
    /// pattern. Two entry points wire into `NotificationService.dispatchAction`:
    ///
    /// - `measurement.done` → `handleMeasurementDone(payload:)` — the user tapped
    ///   "Erledigt". There is **no confirmed server completion route** in the
    ///   v1.17.1 contract (the server only asked for the category for parity, and
    ///   the LIVE confirmation never published a complete/done endpoint or
    ///   payload). So this is treated as the body-tap: route to the measurement
    ///   capture deep-link. **Server-route gap — see the doc-comment below.**
    /// - body-tap (default action) → `handleMeasurementBodyTap(payload:)` — deep-
    ///   links to the measurement capture via the server-supplied `deepLink`,
    ///   falling back to the dashboard when the push carries none.
    extension NotificationService {
        /// `measurement.done` — "Erledigt"/complete on a preventive-care
        /// reminder.
        ///
        /// **v1.18.6 (#32) — server-authoritative completion.** The server now
        /// publishes `POST /api/measurement-reminders/{id}/complete` (idempotent,
        /// owner-scoped, fires no notification) — the explicit user-action twin
        /// of `satisfy`. When the push carries a resolvable `reminderId` AND the
        /// `measurementReminderCompleter` seam is wired, "Erledigt" POSTs the
        /// completion so the server marks the reminder done (the old behaviour
        /// only dismissed the banner locally).
        ///
        /// **Graceful fallback (never dead-ends).** If the push has no
        /// `reminderId` (the server's apns `IOS_METADATA_ALLOWLIST` must add it —
        /// server coord), the completer is unwired (tests / macOS), or the POST
        /// fails (offline / 404 already-resolved), the handler falls back to the
        /// measurement-capture deep-link so the user can still record the reading
        /// — which is itself the real completion (a matching reading auto-satisfies
        /// the reminder server-side).
        @MainActor
        func handleMeasurementDone(payload: APNsPayload?) async {
            guard let reminderId = payload?.reminderId, let complete = measurementReminderCompleter else {
                HLLog.notifications.info(
                    "measurement.done — no reminderId/completer; routing to capture deep-link"
                )
                handleMeasurementBodyTap(payload: payload)
                return
            }
            let ok = await complete(reminderId)
            // reminderId is an enum-grade opaque id, no PII.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.notifications.info(
                "measurement.done — server complete ok=\(ok, privacy: .public)"
            )
            if !ok {
                // Server completion failed (offline / transient) — fall back to
                // the capture deep-link so the action never dead-ends. Recording
                // the reading there auto-satisfies the reminder server-side.
                handleMeasurementBodyTap(payload: payload)
            }
        }

        /// Body-tap on a preventive-care reminder. Deep-links to the measurement
        /// capture surface via the server-supplied `deepLink`; falls back to the
        /// dashboard when the push carries none so an "Erledigt" tap or body-tap
        /// never dead-ends. Synchronous + fire-and-forget — pure UI routing, no
        /// network roundtrip (mirrors the mood body-tap shape).
        @MainActor
        func handleMeasurementBodyTap(payload: APNsPayload?) {
            if let url = payload?.deepLink {
                deepLinks.handle(url)
                return
            }
            HLLog.notifications.info(
                "MEASUREMENT_REMINDER body-tap without deepLink — falling back to dashboard"
            )
            if let url = URL(string: "healthlog://dashboard") {
                deepLinks.handle(url)
            }
        }
    }

    /// **W-B189 (#23) — UserDefaults mirror of the server's
    /// `notificationPrefs.measurementReminder.clientManaged` flag.**
    ///
    /// **CU-26: this is a SUPPRESSION flag, not an opt-in.** Server-side
    /// `clientManaged == true` means "do not deliver" — until v1.33.1 on every
    /// channel, since v1.33.1 on APNs only. The card used to be labelled
    /// "Erinnerungen", so switching it ON to *receive* preventive-care reminders
    /// silently switched them OFF, and the app schedules no local
    /// `MEASUREMENT_REMINDER` to take over. The toggle now says what it does
    /// ("mute push on Apple devices"); the binding is unchanged on purpose,
    /// because inverting it would flip every stored preference.
    ///
    /// Mirrors the `LowStockRunwayPrefStore` / `MoodReminderPrefStore` precedent:
    /// the server is the authority for *firing* the preventive-care reminder, but
    /// the Settings toggle wants the last-known value immediately (before the
    /// prefs payload loads, or offline / standalone). The Settings card + the
    /// prefs cold-read write it whenever the server value is known; the card
    /// reads it back. Default **off** when never written (no key) — opt-in,
    /// matching the medication precedent.
    public enum MeasurementReminderPrefStore {
        private static let enabledKey = "hl.measurementReminder.clientManaged"

        /// The mirrored opt-in, defaulting to `false` when never written.
        public static func clientManaged(defaults: UserDefaults = .standard) -> Bool {
            guard defaults.object(forKey: enabledKey) != nil else { return false }
            return defaults.bool(forKey: enabledKey)
        }

        /// Mirror the (server-authoritative) opt-in locally.
        public static func setClientManaged(_ enabled: Bool, defaults: UserDefaults = .standard) {
            defaults.set(enabled, forKey: enabledKey)
        }
    }

#endif
