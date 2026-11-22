import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif

// **#189 — a dose taken elsewhere, as the phone learns it.**
//
// Foundation-only and shared by the app, the widget extension and the
// Notification Service Extension: the push parser, the App Group ledger the
// extension writes, the gate the app opens, and the pure decision which
// reminders a resolved dose withdraws. Nothing here touches the network.

/// One resolved dose: the medication, the slot instant, and what is known
/// about the take. `outcome` and `intakeId` came with server 1.49.0 (#191); a
/// ledger written before them decodes with both `nil` (read as a take).
public struct ResolvedDose: Codable, Sendable, Equatable {
    public let medicationId: String
    public let slotAt: Date
    public let slotId: String?
    public let takenAt: Date?
    /// `takenVia` of the push (`WEB`, `IOS`, `TELEGRAM`, `INTEGRATION`, `AUTO`).
    public let source: String?
    public let recordedAt: Date
    public let intakeId: String?
    public let outcome: MedicationIntakeOutcome?

    public init(
        medicationId: String,
        slotAt: Date,
        slotId: String? = nil,
        takenAt: Date? = nil,
        source: String? = nil,
        recordedAt: Date = .now,
        intakeId: String? = nil,
        outcome: MedicationIntakeOutcome? = nil
    ) {
        self.medicationId = medicationId
        self.slotAt = slotAt
        self.slotId = slotId
        self.takenAt = takenAt
        self.source = source
        self.recordedAt = recordedAt
        self.intakeId = intakeId
        self.outcome = outcome
    }

    /// `true` unless the push said `skipped`.
    public var wasTaken: Bool {
        outcome != .skipped
    }
}

/// **The `MEDICATION_INTAKE_RECORDED` confirmation push (#189, final in #191).**
///
/// Flat fields, exactly these: `medicationId`, `intakeId`, `slotInstant`
/// (ISO 8601), `outcome` (`taken` or `skipped`), `takenAt` (ISO 8601, null on
/// a skip) and `takenVia`. There is no nested slot and no `source`. No
/// medication name travels. A payload without a medication, a slot instant or
/// a known outcome is no confirmation and yields `nil`.
///
/// Takes a plain dictionary, so the push relay's decrypted plaintext (#190)
/// goes through the same parser as `userInfo`.
public enum MedicationIntakeRecordedPush {
    public static let eventType = "MEDICATION_INTAKE_RECORDED"

    public static func parse(userInfo: [AnyHashable: Any], now: Date = .now) -> ResolvedDose? {
        guard userInfo["eventType"] as? String == eventType,
              let medicationId = string(userInfo["medicationId"]), medicationId.count <= 128,
              let slotAt = date(userInfo["slotInstant"]),
              let rawOutcome = userInfo["outcome"] as? String,
              let outcome = MedicationIntakeOutcome(rawValue: rawOutcome.lowercased()) else { return nil }
        return ResolvedDose(
            medicationId: medicationId,
            slotAt: slotAt,
            takenAt: outcome == .skipped ? nil : date(userInfo["takenAt"]),
            source: string(userInfo["takenVia"]),
            recordedAt: now,
            intakeId: string(userInfo["intakeId"]).flatMap { $0.count <= 128 ? $0 : nil },
            outcome: outcome
        )
    }

    /// The notification thread the server sets (`thread-id`), rebuilt for a
    /// relayed push whose `aps` the extension discards (#190 §5.3).
    public static func threadIdentifier(medicationId: String) -> String {
        "medication-\(medicationId)"
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds) }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// **Capability gate for the confirmation push.** Open once `/api/auth/me`
/// `features` reported ``MedicationCapability/intakeRecordedPush``; the
/// extension reads it from the App Group, because it cannot ask the server.
/// The 1.7 draft opened it by server version; that key is removed on the
/// first record (``MedicationCapabilities/record(_:defaults:)``).
public enum MedicationIntakeRecordedGate {
    public static func isOpen(defaults: UserDefaults? = MedicationCapabilities.appGroupDefaults) -> Bool {
        MedicationCapabilities.isOpen(.intakeRecordedPush, defaults: defaults)
    }
}

/// **The App Group ledger of resolved doses.** The extension writes every
/// confirmation here; the app's foreground presentation and the widget read
/// it. Entries older than a day and a half are dropped on write.
public struct ResolvedDoseLedger: Sendable {
    public static let filename = "resolved-doses.json"
    static let maxAge: TimeInterval = 36 * 60 * 60

    private let url: URL?

    public init(url: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroup.identifier)?
        .appendingPathComponent(ResolvedDoseLedger.filename, isDirectory: false))
    {
        self.url = url
    }

    public func record(_ dose: ResolvedDose, now: Date = .now) {
        var entries = read().filter { now.timeIntervalSince($0.recordedAt) <= Self.maxAge }
        entries.removeAll { $0.medicationId == dose.medicationId && abs($0.slotAt.timeIntervalSince(dose.slotAt)) < 1 }
        entries.append(dose)
        write(entries)
    }

    public func read() -> [ResolvedDose] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ResolvedDose].self, from: data)) ?? []
    }

    /// Whether `medicationId`'s slot at `slotAt` is in the ledger.
    ///
    /// **1.7:** an entry speaks only when it is newer than the state it is
    /// held against (`recordedAfter`, e.g. the widget snapshot's
    /// `generatedAt`): a newer snapshot already carries the server's answer,
    /// and a take deleted on the web must not stay "taken" for 36 hours.
    public func contains(medicationId: String, slotAt: Date, recordedAfter: Date? = nil) -> Bool {
        read().contains { dose in
            dose.medicationId == medicationId
                && abs(dose.slotAt.timeIntervalSince(slotAt)) <= ResolvedReminderPlan.driftTolerance
                && recordedAfter.map { dose.recordedAt > $0 } ?? true
        }
    }

    /// Entries newer than `instant`, or all of them without one.
    public func entries(recordedAfter instant: Date?) -> [ResolvedDose] {
        let all = read()
        guard let instant else { return all }
        return all.filter { $0.recordedAt > instant }
    }

    /// **1.7:** drops every entry recorded before `instant`, the moment a
    /// fresh today answer from the server superseded them: a dose that is
    /// open again on the server (a take deleted on the web) is open again
    /// everywhere. Returns how many were dropped.
    @discardableResult
    public func prune(recordedBefore instant: Date) -> Int {
        let entries = read()
        let kept = entries.filter { $0.recordedAt >= instant }
        guard kept.count != entries.count else { return 0 }
        write(kept)
        return entries.count - kept.count
    }

    private func write(_ entries: [ResolvedDose]) {
        guard var url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// **#189 (1, 2, 3) — which reminders a resolved dose withdraws.**
///
/// A reminder of a resolved slot is any banner or pending request of that
/// medication whose slot lies within ``driftTolerance`` of the resolved slot:
/// the Spezi reminder (its slot is the delivery or trigger date), a snooze or
/// a reopen reminder (their slot travels in `userInfo.scheduledFor`). A
/// repeating Spezi trigger whose next date is the resolved slot cannot skip
/// one day; it is replaced by single requests for the following occurrences,
/// which the app's next scheduler pass replaces again.
public enum ResolvedReminderPlan {
    /// Same tolerance as the reminder completion: two doses of one
    /// medication can lie half an hour apart.
    public static let driftTolerance: TimeInterval = 5 * 60

    /// How far ahead a replaced repeating reminder is planned as single
    /// requests at least. The app re-plans the repeating one on its next run.
    public static let carryHorizonDays = 7

    /// **1.7 (D3 #7)** — how far the single requests may reach when the
    /// pending budget allows. Without an app run nothing refills them, so a
    /// pill box that records every dose used to empty the seven requests and
    /// leave day 8 on silent.
    public static let carryMaximumDays = 60

    /// iOS keeps at most this many pending requests per app.
    public static let pendingRequestLimit = 64

    /// Requests kept free for whatever else the app plans.
    public static let pendingReserve = 4

    /// **Pure — how many single requests each withdrawn repeating trigger may
    /// use:** the free pending budget (limit minus what stays pending, minus
    /// the reserve), shared evenly, at least one, never more than
    /// ``carryMaximumDays`` per trigger.
    public static func carryBudget(pendingAfterWithdrawal: Int, repeatingWithdrawn: Int) -> Int {
        guard repeatingWithdrawn > 0 else { return 0 }
        let free = max(0, pendingRequestLimit - pendingReserve - pendingAfterWithdrawal)
        return min(carryMaximumDays, max(1, free / repeatingWithdrawn))
    }

    /// One notification or pending request, reduced to what matching reads.
    public struct Reminder: Equatable, Sendable {
        public let identifier: String
        public let medicationId: String?
        /// The slot the reminder stands for; `nil` when it cannot be told.
        public let slotAt: Date?
        /// `true` for a repeating calendar trigger.
        public let repeats: Bool

        public init(identifier: String, medicationId: String?, slotAt: Date?, repeats: Bool = false) {
            self.identifier = identifier
            self.medicationId = medicationId
            self.slotAt = slotAt
            self.repeats = repeats
        }
    }

    /// Builds the descriptor from a notification's content: `userInfo`
    /// carries `medicationId` and `scheduledFor`; Spezi-built banners
    /// (`speziScheduled`) stand for their delivery or trigger date instead.
    public static func reminder(
        identifier: String,
        userInfo: [AnyHashable: Any],
        firesAt: Date?,
        repeats: Bool = false
    ) -> Reminder {
        let medicationId = userInfo["medicationId"] as? String
        let isSpezi = userInfo["speziScheduled"] as? Bool == true
        let slot = isSpezi || repeats ? firesAt : (MedicationIntakeRecordedPush.date(userInfo["scheduledFor"]) ?? firesAt)
        return Reminder(identifier: identifier, medicationId: medicationId, slotAt: slot, repeats: repeats)
    }

    public static func isResolved(_ reminder: Reminder, by doses: [ResolvedDose]) -> Bool {
        guard let medicationId = reminder.medicationId, let slotAt = reminder.slotAt else { return false }
        return doses.contains {
            $0.medicationId == medicationId && abs($0.slotAt.timeIntervalSince(slotAt)) <= driftTolerance
        }
    }

    /// The identifiers of `reminders` that `doses` withdraw.
    public static func identifiersToRemove(_ reminders: [Reminder], doses: [ResolvedDose]) -> [String] {
        reminders.filter { isResolved($0, by: doses) }.map(\.identifier)
    }

    /// The body of the last single request: the reminder's own line, then
    /// the hint to open the app (the same words as the runway's end).
    public static func carryTailBody(_ body: String, hint: String) -> String {
        body.isEmpty ? hint : "\(body)\n\(hint)"
    }

    /// The single-request dates that replace a withdrawn repeating trigger:
    /// its matches after `slotAt`, at most `limit` of them and within
    /// ``carryMaximumDays`` (1.7: the budget decides the reach, not a week).
    /// The last one carries the hint to open the app (``carryTailBody(_:hint:)``).
    public static func carryDates(
        matching components: DateComponents,
        after slotAt: Date,
        calendar: Calendar,
        limit: Int = 14
    ) -> [Date] {
        guard let horizon = calendar.date(byAdding: .day, value: carryMaximumDays, to: slotAt) else { return [] }
        var dates: [Date] = []
        var cursor = slotAt
        while dates.count < limit,
              let next = calendar.nextDate(after: cursor, matching: components, matchingPolicy: .nextTime),
              next <= horizon
        {
            dates.append(next)
            cursor = next
        }
        return dates
    }
}

#if canImport(UserNotifications)
    /// **#189 (1, 2, 3) — withdraw the reminders of resolved doses.**
    ///
    /// Removes the delivered banners of `doses` (Spezi reminder, snooze,
    /// reopen) and their pending requests. `.includingScheduler` (the
    /// extension, no app process) also withdraws SpeziScheduler's own pending
    /// request and replaces a repeating one with single requests for the
    /// following occurrences, under an identifier with Spezi's prefix, so the
    /// app's next scheduler pass purges them. `.outsideScheduler` (the app)
    /// leaves Spezi's requests to the reminder completion, which re-plans them.
    ///
    /// Callback APIs, with the closures built here outside any actor: they run
    /// on the notification center's queue.
    public enum ResolvedReminderWithdrawal {
        public enum PendingScope: Sendable {
            case includingScheduler
            case outsideScheduler
        }

        static let schedulerPrefix = "edu.stanford.spezi.scheduler.notification"

        public static func withdraw(
            doses: [ResolvedDose],
            pending scope: PendingScope,
            done: @escaping @Sendable () -> Void = {}
        ) {
            guard !doses.isEmpty else {
                done()
                return
            }
            // The center is fetched inside each callback rather than captured:
            // it is not `Sendable`, and `current()` is the same object.
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let reminders = delivered.map {
                    ResolvedReminderPlan.reminder(
                        identifier: $0.request.identifier,
                        userInfo: $0.request.content.userInfo,
                        firesAt: $0.date
                    )
                }
                let gone = ResolvedReminderPlan.identifiersToRemove(reminders, doses: doses)
                if !gone.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone) }
                UNUserNotificationCenter.current().getPendingNotificationRequests { pending in
                    replacePending(pending, of: doses, scope: scope, center: .current())
                    done()
                }
            }
        }

        private static func replacePending(
            _ pending: [UNNotificationRequest],
            of doses: [ResolvedDose],
            scope: PendingScope,
            center: UNUserNotificationCenter
        ) {
            var withdrawn: [String] = []
            var carried: [Carried] = []
            for request in pending {
                let isScheduler = request.identifier.hasPrefix(schedulerPrefix)
                if isScheduler, scope == .outsideScheduler { continue }
                let calendarTrigger = request.trigger as? UNCalendarNotificationTrigger
                let firesAt = calendarTrigger?.nextTriggerDate()
                    ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
                let reminder = ResolvedReminderPlan.reminder(
                    identifier: request.identifier,
                    userInfo: request.content.userInfo,
                    firesAt: firesAt,
                    repeats: calendarTrigger?.repeats == true
                )
                guard let dose = doses.first(where: { ResolvedReminderPlan.isResolved(reminder, by: [$0]) }) else { continue }
                withdrawn.append(request.identifier)
                guard let calendarTrigger, calendarTrigger.repeats else { continue }
                carried.append(Carried(request: request, trigger: calendarTrigger, dose: dose))
            }
            if !withdrawn.isEmpty { center.removePendingNotificationRequests(withIdentifiers: withdrawn) }
            // 1.7 (D3 #7): the free budget decides how far the single requests
            // reach; the last one asks to open the app, like the runway's end.
            let budget = ResolvedReminderPlan.carryBudget(
                pendingAfterWithdrawal: pending.count - withdrawn.count,
                repeatingWithdrawn: carried.count
            )
            let calendar = Calendar.current
            for item in carried {
                let request = item.request
                let dates = ResolvedReminderPlan.carryDates(
                    matching: item.trigger.dateComponents, after: item.dose.slotAt, calendar: calendar, limit: budget
                )
                for date in dates {
                    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                    center.add(UNNotificationRequest(
                        identifier: "\(request.identifier).carry-\(Int(date.timeIntervalSince1970))",
                        content: date == dates.last ? tailContent(request.content) : request.content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    ))
                }
            }
        }

        /// A withdrawn repeating request with the dose that withdrew it.
        private struct Carried {
            let request: UNNotificationRequest
            let trigger: UNCalendarNotificationTrigger
            let dose: ResolvedDose
        }

        /// The last single request: the reminder plus the line that asks to
        /// open the app (``ResolvedReminderPlan/carryTailBody(_:hint:)``).
        static func tailContent(_ content: UNNotificationContent) -> UNNotificationContent {
            guard let tail = content.mutableCopy() as? UNMutableNotificationContent else { return content }
            tail.body = ResolvedReminderPlan.carryTailBody(content.body, hint: String(localized: "notif.med.runwayTail.hint"))
            return tail
        }
    }
#endif
