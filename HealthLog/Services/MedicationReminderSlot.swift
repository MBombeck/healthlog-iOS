import Foundation

/// Which server slot a fired local reminder stands for.
///
/// Local reminders fire in the device zone; the server keeps every slot in the
/// account zone. At home both agree, and the delivery instant is the slot.
/// After a trip west the 08:00 reminder fires at 08:00 local, hours after the
/// account's 08:00 slot, and booking the delivery instant missed that slot by
/// more than the server's tolerance: the action created a stray row and left
/// the real slot open.
enum MedicationReminderSlot {
    /// How far back the account slot may lie. Beyond it the mapping is no
    /// longer obviously the same dose, so the delivery instant stays.
    static let maxLookback: TimeInterval = 12 * 60 * 60

    /// The account-zone instant with the delivery's wall-clock time, on the
    /// latest account day where it is not in the future. A slot ahead of the
    /// delivery (after a trip east) is never chosen: the server refuses to
    /// put a take onto a future slot, so the delivery instant is kept there.
    ///
    /// The action handler passes every delivery date through here; only
    /// SpeziScheduler banners read it (server pushes carry their own slot).
    static func accountSlot(
        deliveredAt: Date,
        deviceTimeZone: TimeZone = .current,
        accountTimeZone: TimeZone = ProfileTimeZoneBox.shared.current
    ) -> Date {
        guard deviceTimeZone.secondsFromGMT(for: deliveredAt) != accountTimeZone.secondsFromGMT(for: deliveredAt) else { return deliveredAt }
        var device = Calendar(identifier: .gregorian)
        device.timeZone = deviceTimeZone
        var account = Calendar(identifier: .gregorian)
        account.timeZone = accountTimeZone
        let clock = device.dateComponents([.hour, .minute, .second, .nanosecond], from: deliveredAt)
        let accountDay = account.startOfDay(for: deliveredAt)
        for dayOffset in [0, -1] {
            guard let day = account.date(byAdding: .day, value: dayOffset, to: accountDay),
                  let candidate = account.date(
                      bySettingHour: clock.hour ?? 0,
                      minute: clock.minute ?? 0,
                      second: clock.second ?? 0,
                      of: day
                  ) else { continue }
            let slot = candidate.addingTimeInterval(Double(clock.nanosecond ?? 0) / 1_000_000_000)
            let lead = deliveredAt.timeIntervalSince(slot)
            if lead >= 0, lead <= maxLookback { return slot }
        }
        return deliveredAt
    }

    // MARK: - D3 #6: one zone for the booking

    /// What a take from a local reminder or alarm sends: the slot it names and,
    /// on a device away from the account zone, the pin onto that slot.
    struct Booking: Equatable, Sendable {
        let scheduledFor: Date
        /// `forceSlotInstant`; `nil` at home, where the server's own
        /// attribution by `takenAt` already finds the slot.
        let pin: Date?
        /// What to send as `takenAt`: the moment of the take when pinned, the
        /// usual clamp otherwise.
        func takenAt(now: Date) -> Date {
            pin == nil ? min(scheduledFor, now) : now
        }
    }

    /// **One zone, the account's.** Local reminders and the critical alarms
    /// fire on the device's wall clock; the server keeps every slot in the
    /// account zone. Away from home the 08:00 reminder in Bangkok fires at
    /// 02:00 Berlin: booked by `takenAt` it matched no slot, was stored as an
    /// extra dose, and the account's 08:00 slot opened six hours later with a
    /// follow-up, a Live Activity saying "due", and the alarm path a second
    /// dose. West of home the alarm's take lay past the window and the slot
    /// was missed.
    ///
    /// The reminders stay on the device clock (the dose is taken when the
    /// phone rings, and AlarmKit's weekly alarms know no other zone); the
    /// booking is what moves: away from home it pins the take onto the
    /// account slot with the same wall-clock time, the one nearest the
    /// delivery, ahead or behind, within ``maxLookback``. The server checks
    /// that the pin is a real slot and refuses one another dose holds.
    static func booking(
        deliveredAt: Date,
        deviceTimeZone: TimeZone = .current,
        accountTimeZone: TimeZone = ProfileTimeZoneBox.shared.current
    ) -> Booking {
        guard let pin = foreignZonePin(
            deliveredAt: deliveredAt,
            deviceTimeZone: deviceTimeZone,
            accountTimeZone: accountTimeZone
        ) else {
            return Booking(scheduledFor: deliveredAt, pin: nil)
        }
        return Booking(scheduledFor: pin, pin: pin)
    }

    /// The account-zone instant with the delivery's wall-clock time nearest to
    /// the delivery; `nil` when both zones agree or nothing lies within
    /// ``maxLookback``.
    static func foreignZonePin(
        deliveredAt: Date,
        deviceTimeZone: TimeZone,
        accountTimeZone: TimeZone
    ) -> Date? {
        guard deviceTimeZone.secondsFromGMT(for: deliveredAt) != accountTimeZone.secondsFromGMT(for: deliveredAt) else { return nil }
        var device = Calendar(identifier: .gregorian)
        device.timeZone = deviceTimeZone
        var account = Calendar(identifier: .gregorian)
        account.timeZone = accountTimeZone
        let clock = device.dateComponents([.hour, .minute], from: deliveredAt)
        let accountDay = account.startOfDay(for: deliveredAt)
        let candidates = [-1, 0, 1].compactMap { offset -> Date? in
            guard let day = account.date(byAdding: .day, value: offset, to: accountDay) else { return nil }
            return account.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: day)
        }
        guard let nearest = candidates.min(by: {
            abs($0.timeIntervalSince(deliveredAt)) < abs($1.timeIntervalSince(deliveredAt))
        }), abs(nearest.timeIntervalSince(deliveredAt)) <= maxLookback else { return nil }
        return nearest
    }
}
