import Foundation

/// **N1 — who delivers medication reminders: this phone or the server.**
///
/// The app plans medication reminders as local notifications (SpeziScheduler,
/// AlarmKit for critical medications). The server sends `MEDICATION_REMINDER`
/// over APNs as well unless the account says `notificationPrefs.medication.
/// clientManaged: true` (`client-managed-apns.ts` at server v1.39.3). The flag
/// is **account-wide** and silences the APNs leg only: Telegram, ntfy, webhook,
/// e-mail and Web Push keep sending. Without it a phone with local reminders
/// announces every dose twice; with it on a phone that does NOT deliver
/// locally, that phone gets no reminder at all.
///
/// The value type below is what the server reports; the policy decides, from
/// that report and from what this device can actually do, whether the app
/// writes the flag. The write is always the smallest one that makes the
/// server match this device's truth, and never a write the server already
/// agrees with.
public struct MedicationReminderServerDelivery: Sendable, Equatable {
    /// `notificationPrefs.medication.clientManaged`, already resolved by the
    /// server (it folds `deliveryDefault: "client"` into it).
    public let clientManaged: Bool
    /// `notificationPrefs.medication.deliveryDefault`, `"server"` or
    /// `"client"`; `nil` when the server omits it.
    public let deliveryDefault: String?

    public init(clientManaged: Bool, deliveryDefault: String?) {
        self.clientManaged = clientManaged
        self.deliveryDefault = deliveryDefault
    }

    /// `deliveryDefault: "client"` makes the server resolve `clientManaged` to
    /// `true` whatever the stored boolean says (`applyDeliveryDefaultMapping`),
    /// so a `clientManaged: false` write cannot lift it. The app never writes
    /// `deliveryDefault`: it is an account-level choice made elsewhere.
    public var isPinnedToClient: Bool {
        deliveryDefault == "client"
    }
}

/// What one evaluation asks the device to do.
enum MedicationReminderDeliveryDecision: Equatable, Sendable {
    /// Nothing to write, nothing to remember.
    case none
    /// `PATCH clientManaged: true`, then remember that this device relies on it.
    case claim
    /// `PATCH clientManaged: false`, then forget the claim.
    case release
    /// The server already says `true`; remember that this device relies on it,
    /// so it takes the flag back when it stops delivering.
    case noteClaim
    /// Forget the claim without writing (the server is already `false`, or
    /// `deliveryDefault: "client"` pins it and a write would change nothing).
    case dropClaim
}

enum MedicationReminderDeliveryPolicy {
    /// Whether the local planner arms a reminder for `medication`. The same
    /// predicate `MedicationsSchedulerModule.reconcile` uses, so the claim can
    /// never assert a local reminder the planner does not arm: active, reminders
    /// switched on for it, intake tracked (v1.39.1), and a real schedule (an
    /// as-needed medication or one without a plan has nothing to remind of, on
    /// either side).
    static func plansLocalReminder(for medication: Medication) -> Bool {
        medication.active && medication.notificationsEnabled && medication.tracksIntake
    }

    /// Whether this device delivers medication reminders itself: the user
    /// allowed notifications for the app (`.authorized`, `.provisional` or
    /// `.ephemeral`), the account has at least one medication the planner
    /// arms, and the armed reminders reach far enough ahead. Without the
    /// permission a local reminder is never shown, so the server must not be
    /// told to stay quiet.
    ///
    /// **R5 — coverage.** A medication armed as single occurrences runs dry
    /// when the app gets no reconcile in time (no foreground, no background
    /// wake). The local plan shares 48 pending requests, so with several such
    /// courses at once it can reach only days ahead. The server stays quiet
    /// only while every medication whose runway was cut short is armed at least
    /// ``MedicationReminderRunway/minimumClaimCoverage`` ahead; below that this
    /// device stops claiming, and a claim it holds is released, so APNs
    /// reminders resume next to the local ones.
    static func deliversLocally(
        notificationsAuthorized: Bool,
        medications: [Medication],
        now: Date = .now,
        timeZone: TimeZone = .current
    ) -> Bool {
        guard notificationsAuthorized else { return false }
        let plansAny = medications.contains { medication in
            plansLocalReminder(for: medication) && !medication.asNeeded && !medication.schedule.entries.isEmpty
        }
        guard plansAny else { return false }
        return coversMinimum(medications: medications, now: now, timeZone: timeZone)
    }

    /// Whether the local plan reaches ``MedicationReminderRunway/minimumClaimCoverage``
    /// ahead for every medication whose runway was cut short.
    static func coversMinimum(medications: [Medication], now: Date, timeZone: TimeZone = .current) -> Bool {
        let plan = MedicationReminderRunway.plan(for: medications, now: now, timeZone: timeZone)
        guard let end = plan.coverageEnd else { return true }
        return end.timeIntervalSince(now) >= MedicationReminderRunway.minimumClaimCoverage
    }

    /// The decision table.
    ///
    /// - `server == nil` (the server does not report the field): nothing, ever.
    /// - Delivers locally and the server still pushes: claim.
    /// - Delivers locally and the server is already quiet: remember the claim.
    /// - Does not deliver locally: take the flag back only if THIS device set or
    ///   relied on it. A device that never claimed leaves it alone, because the
    ///   flag is account-wide and another phone may be the one delivering. That
    ///   is also what keeps two devices from overwriting each other on every
    ///   foreground: a release clears the claim, so it happens once.
    static func decide(
        server: MedicationReminderServerDelivery?,
        deliversLocally: Bool,
        claimedHere: Bool
    ) -> MedicationReminderDeliveryDecision {
        guard let server else { return .none }
        if deliversLocally {
            if !server.clientManaged { return .claim }
            return claimedHere ? .none : .noteClaim
        }
        guard claimedHere else { return .none }
        guard server.clientManaged, !server.isPinnedToClient else { return .dropClaim }
        return .release
    }
}

/// The device-local memory of "this device relies on `clientManaged`", keyed
/// to the account that relied on it. One key, holding the owner id, so a
/// different account signing in on the same device never inherits the claim.
struct MedicationReminderClaimMarker {
    static let defaultsKey = "hl.medicationReminder.clientManagedClaimOwner"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func isClaimed(by ownerID: String) -> Bool {
        defaults.string(forKey: Self.defaultsKey) == ownerID
    }

    func claim(for ownerID: String) {
        defaults.set(ownerID, forKey: Self.defaultsKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
