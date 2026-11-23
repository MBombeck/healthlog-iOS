import Foundation

// **The plaintext templates the device reads (#190 §7, §8; #191).**
//
// `t` names a fixed template. Fields beyond the ones named here are ignored,
// so a later server can add some without breaking the device.

public enum RelayTemplate {
    public static let medicationReminder = "MEDICATION_REMINDER"
    /// Every alert in discreet mode: `t`, `ui.category` and `ui.thread`.
    public static let discreetReminder = "REMINDER"
    public static let systemAlert = "SYSTEM_ALERT"
    public static let securityAlert = "SECURITY_ALERT"
    public static let intakeRecorded = "MEDICATION_INTAKE_RECORDED"
    public static let intakeSync = "MEDICATION_INTAKE_SYNC"

    /// **D1 (13).** The alert templates v1 shows. Any other `t` opens, is
    /// recorded, and shows the placeholder: a template this build does not
    /// know gets no text of its own.
    public static let knownAlerts: Set<String> = [
        medicationReminder, discreetReminder, systemAlert, securityAlert, intakeRecorded,
        "MOOD_REMINDER", "MEASUREMENT_REMINDER", "DAILY_BRIEFING_NUDGE", "MEDICATION_LOW_STOCK", "THRESHOLD_NUDGE"
    ]

    /// **D1 (13).** The silent templates v1 acts on. Any other `t` starts
    /// nothing (no sync, no HealthKit run).
    public static let knownSilent: Set<String> = ["SYNC", intakeSync, "DATA_CHANGED", "HEALTHKIT_CATCH_UP"]

    public static func isKnownAlert(_ type: String) -> Bool {
        knownAlerts.contains(type)
    }

    public static func isKnownSilent(_ type: String) -> Bool {
        knownSilent.contains(type)
    }

    /// §8: `time-sensitive` only for these; any other `t` with it is read as
    /// `active`.
    public static let timeSensitiveAllowed: Set<String> = [medicationReminder, systemAlert, securityAlert, discreetReminder]

    /// §8: exactly `passive`, `active`, `time-sensitive`; anything else is
    /// absent.
    public enum Level: String, Sendable {
        case passive
        case active
        case timeSensitive = "time-sensitive"
    }

    public static func level(_ raw: String?, type: String) -> Level? {
        guard let raw, let level = Level(rawValue: raw) else { return nil }
        if level == .timeSensitive, !timeSensitiveAllowed.contains(type) { return .active }
        return level
    }

    /// The web path the security settings answer to (`DeepLinkRoute`).
    public static let securitySettingsPath = "/settings/security"
    /// #191 `d.securityKind` values.
    public static let securityKinds: Set<String> = ["new_device", "passkey_added", "passkey_removed", "token_revoked", "refresh_reuse"]

    /// `SECURITY_ALERT`, or `REMINDER` in discreet mode with a known
    /// `d.securityKind`.
    public static func isSecurityAlert(_ plaintext: RelayPlaintext) -> Bool {
        if plaintext.type == securityAlert { return true }
        guard plaintext.type == discreetReminder, let kind = plaintext.data?["securityKind"]?.stringValue else { return false }
        return securityKinds.contains(kind)
    }

    /// A reminder for a dose: `MEDICATION_REMINDER`, or `REMINDER` in discreet
    /// mode when `d` still names the medication and the slot (§7).
    public static func isDoseReminder(_ plaintext: RelayPlaintext) -> Bool {
        switch plaintext.type {
        case medicationReminder:
            true
        case discreetReminder:
            plaintext.data?["medicationId"]?.stringValue != nil && plaintext.data?["scheduledAt"]?.stringValue != nil
        default:
            false
        }
    }
}

/// **#191 (17:41) — `DATA_CHANGED`, a silent wake after new readings on the
/// server.** `d.domains` is a sorted subset of `measurements`, `sleep`,
/// `workouts`, `nutrition`, with `d.changedAt`; lifetime 3600 s. The server
/// coalesces per device (at once, then over 5 minutes, at most 3 an hour);
/// the device does not reload more often than every two minutes either.
public struct RelayDataChange: Sendable, Equatable {
    public static let template = "DATA_CHANGED"
    /// The server coalesces per user; the device does not reload more often
    /// than this either.
    public static let minimumInterval: TimeInterval = 120

    public let domains: [String]

    public init(domains: [String]) {
        self.domains = domains
    }

    public init(plaintext: RelayPlaintext) {
        let candidates = ["domains"].compactMap { plaintext.data?[$0] }
        var domains: [String] = []
        for case let .array(items) in candidates {
            domains += items.compactMap(\.stringValue)
        }
        self.domains = Array(Set(domains)).sorted()
    }

    /// Whether a reload runs now, given the last one: never twice within
    /// ``minimumInterval``. The next wake or foreground catches up.
    public static func shouldReload(lastReload: Date?, now: Date) -> Bool {
        guard let lastReload else { return true }
        return now.timeIntervalSince(lastReload) >= minimumInterval || now < lastReload
    }
}

/// **#190 5.3 — the secret action category of dose reminders.**
///
/// With envelope mode on, the actions Taken, Later and Skipped are registered
/// under a random per-install identifier kept in the push keychain group, and
/// every local dose reminder uses it too. A plaintext push that names
/// `MEDICATION_REMINDER` then finds no category and shows no buttons. Without
/// envelope mode everything stays on the plain name, as before.
public enum RelayCategoryIdentity {
    public static let plainMedication = RelayTemplate.medicationReminder

    public static func medication(
        envelopeMode: Bool = RelayEnvelopeMode.isOn(),
        secret: () -> String? = { RelayKeyring.production().secretCategory(for: RelayTemplate.medicationReminder) }
    ) -> String {
        guard envelopeMode, let secret = secret(), !secret.isEmpty else { return plainMedication }
        return secret
    }
}

/// **#190 5.6 — local follow-up stages and the server-mode fallback.**
///
/// Over the relay, follow-up reminders of a dose that is still open reach
/// only devices that say `server` (#190 §11). A `client` device with the relay
/// on therefore plans them itself: at the end of the intake window and 240
/// minutes later. A `server` device gets a local fallback 10 minutes after the
/// due time, which the extension removes once the server's reminder arrives.
/// Every request carries the slot in `userInfo`, so a recorded dose withdraws
/// it like any other reminder of that slot.
public enum RelayFollowUps {
    /// Only for a server that sends no dose window (no `overdueSince`).
    public static let intakeWindow: TimeInterval = 60 * 60
    public static let secondStageDelay: TimeInterval = 240 * 60
    public static let fallbackDelay: TimeInterval = 10 * 60
    /// Room left for the regular reminders in the 64 pending requests.
    public static let maxRequests = 12
    public static let prefix = "dev.healthlog.med.followup."

    public enum Mode: Sendable, Equatable {
        case none
        case followUps
        case fallback
    }

    public struct Request: Sendable, Equatable {
        public let identifier: String
        public let medicationId: String
        public let slot: Date
        public let fireAt: Date
    }

    public static func mode(relayOn: Bool, delivery: DeviceMedicationDeliveryReport?) -> Mode {
        guard relayOn else { return .none }
        switch delivery {
        case .delivery(.client)?: return .followUps
        case .delivery(.server)?: return .fallback
        case .none?, nil: return .none
        }
    }

    public static func identifier(stage: String, medicationId: String, slot: Date) -> String {
        "\(prefix)\(stage).\(medicationId).\(Int(slot.timeIntervalSince1970))"
    }

    /// The fallback's id for the reminder the server just delivered.
    public static func fallbackIdentifier(medicationId: String, slot: Date) -> String {
        identifier(stage: "fallback", medicationId: medicationId, slot: slot)
    }

    /// One open dose: the slot and, from the server's today row, the instant
    /// its on-time window closes (`overdueSince`, #190 20:09).
    public struct OpenDose: Sendable, Equatable {
        public let medicationId: String
        public let slot: Date
        public let overdueSince: Date?
        /// **D3 (5).** When the server counts the dose as missed
        /// (`doseState.missedAfter`). No stage fires at or after it.
        public let missedAfter: Date?
        /// **D3 (5).** The medication's next slot today. No stage fires at
        /// or after it, so two doses never come within the hour.
        public let nextSlot: Date?

        public init(medicationId: String, slot: Date, overdueSince: Date? = nil, missedAfter: Date? = nil, nextSlot: Date? = nil) {
            self.medicationId = medicationId
            self.slot = slot
            self.overdueSince = overdueSince
            self.missedAfter = missedAfter
            self.nextSlot = nextSlot
        }

        /// The last instant a stage may fire.
        var deadline: Date? {
            [missedAfter, nextSlot].compactMap(\.self).min()
        }
    }

    public static func plan(open: [(medicationId: String, slot: Date)], mode: Mode, now: Date) -> [Request] {
        plan(open: open.map { OpenDose(medicationId: $0.medicationId, slot: $0.slot) }, mode: mode, now: now)
    }

    /// Requests for today's open slots, those still ahead, earliest first.
    /// The first follow-up fires when the server's window closes
    /// (`overdueSince`); without one, the fixed fallback window.
    ///
    /// **R1 (7).** `delivered` names the fallbacks whose server reminder
    /// already arrived (``RelayDeliveredReminders``): those are not planned
    /// again, however often the intakes change afterwards.
    public static func plan(open: [OpenDose], mode: Mode, now: Date, delivered: Set<String> = []) -> [Request] {
        var requests: [Request] = []
        for dose in open where !(mode == .fallback && delivered.contains(fallbackIdentifier(
            medicationId: dose.medicationId,
            slot: dose.slot
        ))) {
            switch mode {
            case .none:
                break
            case .followUps:
                let first = dose.overdueSince ?? dose.slot.addingTimeInterval(intakeWindow)
                requests.append(Request(
                    identifier: identifier(stage: "window", medicationId: dose.medicationId, slot: dose.slot),
                    medicationId: dose.medicationId,
                    slot: dose.slot,
                    fireAt: first
                ))
                requests.append(Request(
                    identifier: identifier(stage: "late", medicationId: dose.medicationId, slot: dose.slot),
                    medicationId: dose.medicationId,
                    slot: dose.slot,
                    fireAt: first.addingTimeInterval(secondStageDelay)
                ))
            case .fallback:
                requests.append(Request(
                    identifier: fallbackIdentifier(medicationId: dose.medicationId, slot: dose.slot),
                    medicationId: dose.medicationId,
                    slot: dose.slot,
                    fireAt: dose.slot.addingTimeInterval(fallbackDelay)
                ))
            }
        }
        let deadlines = Dictionary(
            open.map { (identifier(stage: "", medicationId: $0.medicationId, slot: $0.slot), $0.deadline) },
            uniquingKeysWith: { first, _ in first }
        )
        return Array(requests
            .filter { $0.fireAt > now }
            .filter { request in
                guard let deadline = deadlines[identifier(stage: "", medicationId: request.medicationId, slot: request.slot)]
                    .flatMap(\.self) else
                {
                    return true
                }
                return request.fireAt < deadline
            }
            .sorted { $0.fireAt < $1.fireAt }
            .prefix(maxRequests))
    }

    /// The slot a delivered dose reminder names (`d.scheduledAt`, §7).
    public static func slot(of plaintext: RelayPlaintext) -> (medicationId: String, slot: Date)? {
        guard RelayTemplate.isDoseReminder(plaintext),
              let medicationId = plaintext.data?["medicationId"]?.stringValue,
              let text = plaintext.data?["scheduledAt"]?.stringValue else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { return nil }
        return (medicationId, Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60))
    }
}

/// **R1 (7) — the server reminders this device received.**
///
/// The extension removes the local fallback of a slot once the server's
/// reminder for it arrives. The app plans the fallbacks anew on every intake
/// change, so without a record the removed fallback came back and fired ten
/// minutes after the reminder that had already been shown. One App Group file
/// of fallback identifiers, written by the extension, read by the app, pruned
/// after two days and wiped on sign-out.
public struct RelayDeliveredReminders: Sendable {
    public static let filename = "push-relay-delivered-reminders.json"
    static let maxEntries = 64
    static let keep: TimeInterval = 48 * 60 * 60

    struct Entry: Codable, Equatable {
        let identifier: String
        let deliveredAt: Date
    }

    private let url: URL?

    public init(url: URL? = RelayAppGroupFile.url(RelayDeliveredReminders.filename)) {
        self.url = url
    }

    /// The server's reminder for this slot arrived.
    public func record(medicationId: String, slot: Date, now: Date = .now) {
        guard let url else { return }
        let identifier = RelayFollowUps.fallbackIdentifier(medicationId: medicationId, slot: slot)
        _ = RelayAppGroupFile.withLock(url) {
            var entries = Self.pruned(RelayAppGroupFile.read([Entry].self, from: url) ?? [], now: now)
            entries.removeAll { $0.identifier == identifier }
            entries.append(Entry(identifier: identifier, deliveredAt: now))
            RelayAppGroupFile.write(Array(entries.suffix(Self.maxEntries)), to: url)
        }
    }

    /// The fallback identifiers whose reminder arrived within two days.
    public func identifiers(now: Date = .now) -> Set<String> {
        guard let url else { return [] }
        let entries = RelayAppGroupFile.withLock(url) { RelayAppGroupFile.read([Entry].self, from: url) ?? [] } ?? []
        return Set(Self.pruned(entries, now: now).map(\.identifier))
    }

    public func wipe() {
        RelayAppGroupFile.remove(url)
    }

    static func pruned(_ entries: [Entry], now: Date) -> [Entry] {
        entries.filter { now.timeIntervalSince($0.deliveredAt) < keep }
    }
}

/// The server's `features` keys the relay reads (#191), recorded from
/// `GET /api/version` like the medication capabilities.
public enum RelayFeatures {
    public static let liveActivityRelay = "push.live-activity-relay"
    public static let dataChanged = "push.data-changed"
    public static let healthKitCatchUp = "push.healthkit-catch-up"
    public static let securityAlertRelay = "push.security-alert-relay"
    public static let liveActivityStarted = "push.live-activity-started"
    static let defaultsKey = "hl.pushRelay.features"

    public static func record(_ features: [String], defaults: UserDefaults = .standard) {
        let known = [liveActivityRelay, dataChanged, healthKitCatchUp, securityAlertRelay, liveActivityStarted]
        defaults.set(features.filter { known.contains($0) }.sorted(), forKey: defaultsKey)
    }

    public static func contains(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: defaultsKey) ?? []).contains(key)
    }
}
