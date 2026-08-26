import Foundation

/// Server-Channel (typischerweise nur \`APNS\` auf iOS, aber Server kann
/// auch \`WEB_PUSH\` / \`TELEGRAM\` / \`NTFY\` zurückgeben — die UI rendert
/// nur die für iOS relevanten Channels in v0.3.x).
public struct NotificationChannel: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let type: String
    public let label: String
    public let enabled: Bool
    public let globallyEnabled: Bool

    public init(id: String, type: String, label: String, enabled: Bool, globallyEnabled: Bool) {
        self.id = id
        self.type = type
        self.label = label
        self.enabled = enabled
        self.globallyEnabled = globallyEnabled
    }
}

/// Per-(channel × event) Toggle-Status. \`enabled = false\` heißt: Server
/// schickt diesen Channel keine Pushes für diesen eventType.
public struct NotificationPreference: Codable, Sendable, Equatable {
    public let channelId: String
    public let eventType: String
    public let enabled: Bool

    public init(channelId: String, eventType: String, enabled: Bool) {
        self.channelId = channelId
        self.eventType = eventType
        self.enabled = enabled
    }
}

/// Per-user mood-reminder settings (server v1.7.0). Nested under
/// `notificationPrefs.mood`. `reminderHour` is the local-clock hour (0–23)
/// the evening mood nudge should fire at — the **source of truth** for the
/// iOS-local `UNCalendarNotificationTrigger`. Optional on the wire because
/// older servers (pre-v1.7.0) omit it; the client falls back to a local
/// default (22) then.
public struct MoodNotificationPrefs: Codable, Sendable, Equatable {
    public let reminderHour: Int?

    public init(reminderHour: Int?) {
        self.reminderHour = reminderHour
    }
}

/// Wire shape of `GET /api/auth/me/notification-prefs` (server v1.7.0).
///
/// **Why a separate type from ``NotificationPreferencesPayload``.** The
/// `mood.reminderHour` source-of-truth lives here, NOT on
/// `GET /api/notifications/preferences` (which returns only
/// `{ channels, preferences, eventTypes }` — no `mood` block). The earlier
/// cold-read of the hour off `/api/notifications/preferences` therefore always
/// missed the server value and silently fell to the local default 22 (AUDIT-G
/// A1-B1). This endpoint carries the fully-resolved
/// `{ medication: { clientManaged, deliveryDefault }, mood: { reminderHour } }`
/// so the cold read sees the server-canonical hour. The matching WRITE is the
/// existing `PATCH /api/auth/me/notification-prefs` (unchanged).
///
/// The server always returns the fully-resolved shape (missing keys filled
/// from defaults), so `mood.reminderHour` is non-optional here — but the nested
/// objects stay optional for forward-compat with a drifted/older server.
public struct AuthNotificationPrefsPayload: Codable, Sendable, Equatable {
    public struct Mood: Codable, Sendable, Equatable {
        public let reminderHour: Int?

        public init(reminderHour: Int?) {
            self.reminderHour = reminderHour
        }
    }

    /// **MED-4 / AUDIT-PARITY C3 — low-supply runway threshold.** Nested under
    /// `notificationPrefs.medication`. `lowStockRunwayDays` is the projected
    /// days-of-supply at or below which the low-supply alert fires (server cron
    /// pushes once per crossing; iOS renders the runway on the card/detail and
    /// surfaces the local low-supply notification). Range 1–60, server default
    /// 7, `null` = the alert is off. Optional on the wire because pre-v1.16.11
    /// servers omit the field — the client then keeps the alert off.
    public struct Medication: Codable, Sendable, Equatable {
        public let lowStockRunwayDays: Int?
        /// **CU-20 (#69) — the field the concurrency token exists to protect.**
        /// When `true` the *client* owns medication reminder delivery (iOS
        /// schedules them locally) and the server must not also push them.
        ///
        /// The server deep-merges the whole `notificationPrefs` blob, so a web
        /// session PATCHing from a read taken before this flag was set silently
        /// resets it — and the user gets a server push *and* a local
        /// notification for the same dose. That is the double-reminder bug.
        /// With `baseUpdatedAt` on the PATCH the write either lands or comes
        /// back as `409 notification_prefs_conflict`; it can no longer be
        /// clobbered from a stale read. Decoded so the client can see (and a
        /// test can pin) the value that survives a conflict.
        public let clientManaged: Bool?

        public init(lowStockRunwayDays: Int?, clientManaged: Bool? = nil) {
            self.lowStockRunwayDays = lowStockRunwayDays
            self.clientManaged = clientManaged
        }
    }

    /// **W-B189 / #23 — preventive-care (Vorsorge) reminder suppression.**
    ///
    /// **CU-26: `clientManaged == true` SUPPRESSES delivery** (server
    /// `client-managed-apns.ts`; APNs-only since v1.33.1, every channel before).
    /// It is not an opt-in to receive. Nested
    /// under `notificationPrefs.measurementReminder` (server v1.17.1). The
    /// `MEASUREMENT_REMINDER` event fires when a preventive-care measurement is
    /// due; `clientManaged` mirrors the medication opt-in precedent — when the
    /// server surfaces it, the Settings toggle reflects the persisted state and
    /// the user opts in/out. Optional on the wire because pre-v1.17.1 servers
    /// omit the block — the client then keeps the opt-in off.
    public struct MeasurementReminder: Codable, Sendable, Equatable {
        public let clientManaged: Bool?

        public init(clientManaged: Bool?) {
            self.clientManaged = clientManaged
        }
    }

    public let mood: Mood?
    public let medication: Medication?
    public let measurementReminder: MeasurementReminder?
    /// **CU-20 (#69) — optimistic-concurrency token.** Echoed as
    /// `baseUpdatedAt` on the next PATCH; a stale one yields
    /// `409 notification_prefs_conflict` and nothing is written. Guards the
    /// shared `User.updatedAt`
    /// (`api/auth/me/notification-prefs/route.ts:130`). `nil` on an older
    /// server — the next write is then unconditional.
    public let updatedAt: String?

    public init(
        mood: Mood?,
        medication: Medication? = nil,
        measurementReminder: MeasurementReminder? = nil,
        updatedAt: String? = nil
    ) {
        self.mood = mood
        self.medication = medication
        self.measurementReminder = measurementReminder
        self.updatedAt = updatedAt
    }

    /// The local-clock hour (0–23) for the evening mood reminder, clamped, or
    /// `nil` when the server omitted it (a drifted/older server) so the caller
    /// keeps its local mirror / default rather than overwriting it with a guess.
    public var moodReminderHour: Int? {
        mood?.reminderHour.map { max(0, min(23, $0)) }
    }

    /// **MED-4 / C3** — the configured low-supply runway threshold (1–60 days),
    /// clamped, or `nil` when the alert is off / the server omitted the field.
    public var lowStockRunwayDays: Int? {
        medication?.lowStockRunwayDays.map { max(1, min(60, $0)) }
    }

    /// **W-B189 / #23** — whether the preventive-care (Vorsorge) reminder is
    /// opted in (`measurementReminder.clientManaged`), or `nil` when the server
    /// omitted the block (a pre-v1.17.1 / drifted server) so the caller keeps
    /// its local mirror rather than overwriting it with a guess.
    public var measurementReminderClientManaged: Bool? {
        measurementReminder?.clientManaged
    }

    /// **CU-20 / #69** — whether medication reminder delivery is client-managed
    /// (`medication.clientManaged`). `nil` when the server omitted the field so
    /// the caller keeps its local mirror rather than guessing.
    public var medicationClientManaged: Bool? {
        medication?.clientManaged
    }
}

/// **MED-4 / C3** — server bounds on the low-supply runway threshold.
public let medicationLowStockRunwayMin = 1
public let medicationLowStockRunwayMax = 60
/// Server default when the user has never set a threshold (v1.16.11).
public let medicationLowStockRunwayDefault = 7

/// Aggregat-Payload aus \`GET /api/notifications/preferences\`. \`eventTypes\`
/// liefert die Server-known Event-Catalogue — iOS rendert sie in dieser
/// Reihenfolge.
public struct NotificationPreferencesPayload: Codable, Sendable, Equatable {
    public let channels: [NotificationChannel]
    public let preferences: [NotificationPreference]
    public let eventTypes: [String]
    /// v1.7.0 — per-user mood-reminder settings (`notificationPrefs.mood`).
    /// `nil` on a legacy server; the iOS-local reminder defaults its hour to
    /// 22 in that case.
    public let mood: MoodNotificationPrefs?

    public init(
        channels: [NotificationChannel],
        preferences: [NotificationPreference],
        eventTypes: [String],
        mood: MoodNotificationPrefs? = nil
    ) {
        self.channels = channels
        self.preferences = preferences
        self.eventTypes = eventTypes
        self.mood = mood
    }

    /// The local-clock hour (0–23) for the evening mood reminder, clamped to a
    /// valid range, defaulting to ``defaultMoodReminderHour`` (22) when the
    /// server doesn't surface one.
    public var moodReminderHour: Int {
        guard let raw = mood?.reminderHour else { return Self.defaultMoodReminderHour }
        return max(0, min(23, raw))
    }

    /// Local fallback when the server omits `notificationPrefs.mood.reminderHour`.
    public static let defaultMoodReminderHour = 22

    /// Lookup-Helper: ist (channel × event) **explizit** enabled?
    /// Liefert nur `true`, wenn eine echte Preference-Row mit `enabled = true`
    /// existiert — eine fehlende Row ist hier NICHT „default-on". Für die
    /// effektive (server-parity) Toggle-Stellung siehe ``effectiveEnabled``.
    public func isEnabled(channelId: String, eventType: String) -> Bool {
        preferences.first(where: { $0.channelId == channelId && $0.eventType == eventType })?.enabled ?? false
    }

    /// **Build 6.5 — server-parity Toggle-Stellung.** Der Dispatcher entscheidet
    /// bei fehlender Preference-Row anhand von `EVENT_DEFAULT_ENABLED[eventType]
    /// ?? true` (`lib/notifications/dispatcher.ts`), NICHT „aus". Eine reine
    /// `isEnabled`-Anzeige zeigte darum default-on-Events (Medikamente, System,
    /// Vorsorge …) fälschlich als aus. `effectiveEnabled` spiegelt die
    /// Server-Default-Policy: existiert eine explizite Row, gewinnt sie; sonst
    /// gilt der gespiegelte Default (``NotificationEventDefaults``).
    public func effectiveEnabled(channelId: String, eventType: String) -> Bool {
        if let pref = preferences.first(where: { $0.channelId == channelId && $0.eventType == eventType }) {
            return pref.enabled
        }
        return NotificationEventDefaults.isOn(eventType)
    }
}

/// **Build 6.5 — mirror of the server's `EVENT_DEFAULT_ENABLED`**
/// (`lib/notifications/types.ts`). The per-event default the dispatcher applies
/// when a channel has no explicit `NotificationPreference` row. Every event is
/// opt-out (default ON) EXCEPT the privacy-/noise-sensitive ones the server
/// keeps silent until an explicit opt-in. An UNKNOWN (future) event defaults ON,
/// matching the server's `?? true` — a new default-on event a client doesn't yet
/// know still reads as on rather than silently off.
public enum NotificationEventDefaults {
    /// Events the server keeps OFF by default (must be explicitly enabled).
    private static let offByDefault: Set<String> = [
        "PERSONAL_RECORD",
        "MOOD_REMINDER",
        "CYCLE_PERIOD_SOON",
        "CYCLE_PERIOD_CONFIRM",
        "CYCLE_FERTILE_SOON",
        "DAILY_BRIEFING"
    ]

    /// The default-enabled state for `eventType` when no explicit preference
    /// exists — `false` for the opt-in set above, `true` otherwise (incl. unknown
    /// future events, mirroring the server's `?? true`).
    public static func isOn(_ eventType: String) -> Bool {
        !offByDefault.contains(eventType)
    }
}
