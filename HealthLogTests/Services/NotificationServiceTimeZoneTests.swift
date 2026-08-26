import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    /// v0.7.1 QoL-3-H-2 — timezone contract for the calendar-trigger path.
    ///
    /// `UNCalendarNotificationTrigger` interprets its matched
    /// `DateComponents` in whatever timezone the device is in **at fire
    /// time** unless the components themselves carry a `timeZone`. A
    /// reminder built at 09:00 Berlin would otherwise fire at 09:00 in New
    /// York after the traveller's device crosses zones — a multi-hour
    /// drift. The fix pins `comps.timeZone = calendar.timeZone` (captured
    /// at scheduling time), so the trigger fixes the exact instant the
    /// operator intended.
    ///
    /// Contract chosen: **explicit scheduling-zone instant** (not a
    /// floating wall-clock). The medication-reminder intent is the dose
    /// time the user configured; pinning the zone makes the projection
    /// deterministic and unit-testable. These tests exercise the pure
    /// `buildLocalReminderRequest(...)` factory with an injected
    /// `Calendar`, so they need no `UNUserNotificationCenter`
    /// authorization.
    @Suite("NotificationService — calendar-trigger timezone contract (QoL-3-H-2)")
    @MainActor
    struct NotificationServiceTimeZoneTests {
        // swiftlint:disable force_unwrapping

        private func calendar(tzIdentifier: String) -> Calendar {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: tzIdentifier)!
            return cal
        }

        @Test("Far-future calendar trigger stamps an explicit timeZone on the components")
        func farFutureStampsTimeZone() throws {
            let berlin = calendar(tzIdentifier: "Europe/Berlin")
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            let target = now.addingTimeInterval(60 * 60) // 1 h out → calendar branch
            let req = NotificationService.buildLocalReminderRequest(
                id: "tz",
                title: "Dose",
                body: "Take",
                at: target,
                now: now,
                calendar: berlin
            )
            let trigger = try #require(req.trigger as? UNCalendarNotificationTrigger)
            let comps = trigger.dateComponents
            #expect(comps.timeZone == TimeZone(identifier: "Europe/Berlin"))
        }

        @Test("Pinned timezone produces the same fire instant regardless of device zone")
        func pinnedZoneIsDeterministicAcrossDeviceZone() throws {
            // Schedule the same wall-clock dose against the same source
            // calendar; the trigger's next-fire instant must be identical
            // no matter what the host runner's local zone is, because the
            // components now carry their own timezone.
            let berlin = calendar(tzIdentifier: "Europe/Berlin")
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            let target = now.addingTimeInterval(3 * 60 * 60) // 3 h out

            let req = NotificationService.buildLocalReminderRequest(
                id: "instant",
                title: "Dose",
                body: "Take",
                at: target,
                now: now,
                calendar: berlin
            )
            let trigger = try #require(req.trigger as? UNCalendarNotificationTrigger)

            // Resolve the matched components back to an absolute instant
            // using the pinned zone — it must equal the source target to
            // the second. (`nextTriggerDate` would depend on the live
            // clock, so we resolve the components directly instead.)
            var resolveCal = Calendar(identifier: .gregorian)
            resolveCal.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
            let resolved = try #require(resolveCal.date(from: trigger.dateComponents))
            #expect(abs(resolved.timeIntervalSince(target)) < 1)
        }

        @Test("Different scheduling zones yield different absolute instants for the same wall-clock")
        func differentZonesDifferentInstants() throws {
            // 09:00 wall-clock on the same calendar day in two zones must
            // map to two different absolute instants — proving the zone is
            // actually honoured, not dropped.
            let berlin = calendar(tzIdentifier: "Europe/Berlin")
            let newYork = calendar(tzIdentifier: "America/New_York")
            // A fixed wall-clock target: 2026-06-01 09:00 local.
            var comps = DateComponents()
            comps.year = 2026
            comps.month = 6
            comps.day = 1
            comps.hour = 9
            comps.minute = 0
            let berlinTarget = try #require(berlin.date(from: comps))
            let nyTarget = try #require(newYork.date(from: comps))

            let reqBerlin = NotificationService.buildLocalReminderRequest(
                id: "b", title: "Dose", body: "Take",
                at: berlinTarget, now: Date(timeIntervalSince1970: 0), calendar: berlin
            )
            let reqNY = NotificationService.buildLocalReminderRequest(
                id: "n", title: "Dose", body: "Take",
                at: nyTarget, now: Date(timeIntervalSince1970: 0), calendar: newYork
            )
            let tB = try #require((reqBerlin.trigger as? UNCalendarNotificationTrigger)?.dateComponents.timeZone)
            let tN = try #require((reqNY.trigger as? UNCalendarNotificationTrigger)?.dateComponents.timeZone)
            #expect(tB == TimeZone(identifier: "Europe/Berlin"))
            #expect(tN == TimeZone(identifier: "America/New_York"))
            // Same wall-clock, different zones → different absolute instants.
            #expect(berlinTarget != nyTarget)
        }

        @Test("Near-future schedule still uses the time-interval trigger (no zone needed)")
        func nearFutureUnaffected() throws {
            let berlin = calendar(tzIdentifier: "Europe/Berlin")
            let now = Date(timeIntervalSince1970: 1_779_710_400)
            let target = now.addingTimeInterval(30)
            let req = NotificationService.buildLocalReminderRequest(
                id: "near",
                title: "Dose",
                body: "Take",
                at: target,
                now: now,
                calendar: berlin
            )
            // Time-interval triggers fire at an absolute offset, so they are
            // already zone-independent — the contract leaves them untouched.
            _ = try #require(req.trigger as? UNTimeIntervalNotificationTrigger)
        }

        // swiftlint:enable force_unwrapping
    }
#endif
