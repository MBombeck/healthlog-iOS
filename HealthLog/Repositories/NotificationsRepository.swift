import Foundation

/// Wrappt \`/api/notifications/preferences\` GET + PUT. Actor-isoliert um
/// inflight-Requests zu serialisieren — der Store optimistisch toggled,
/// Repo POSTs der Reihe nach + revertet on error.
public actor NotificationsRepository {
    private let api: APIClientProtocol

    /// **CU-20 (#69)** — the last `updatedAt` seen from
    /// `/api/auth/me/notification-prefs` (GET or PATCH echo). Sent as
    /// `baseUpdatedAt` on the next PATCH so a write built on a stale read is
    /// refused with `409 notification_prefs_conflict` instead of deep-merging
    /// over whatever another session stored. `nil` = no token yet → the next
    /// write is unconditional (the permanently supported arm).
    private var baseUpdatedAt: String?

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Test/diagnostic accessor for the currently held concurrency token.
    public func currentPrefsToken() -> String? {
        baseUpdatedAt
    }

    public func preferences() async throws -> NotificationPreferencesPayload {
        try await api.send(.get("/api/notifications/preferences"))
    }

    /// **AUDIT-G A1-B1 (v0.11)** — cold-read of the evening mood-reminder hour.
    /// The hour's source of truth is `GET /api/auth/me/notification-prefs`
    /// (`{ medication, mood: { reminderHour } }`), NOT
    /// `/api/notifications/preferences` (which carries no `mood` block). Reading
    /// it here means a fresh launch sees the server-canonical hour instead of
    /// silently falling to the local default 22. The matching WRITE stays
    /// ``setMoodReminderHour(_:)`` (PATCH on the same path) — unchanged.
    public func authNotificationPrefs() async throws -> AuthNotificationPrefsPayload {
        let payload: AuthNotificationPrefsPayload = try await api.send(
            .get("/api/auth/me/notification-prefs")
        )
        // CU-20 — every GET refreshes the token the next PATCH will echo.
        baseUpdatedAt = payload.updatedAt
        return payload
    }

    /// **CU-20 (#69)** — the single guarded PATCH used by all three
    /// notification-prefs writers below.
    ///
    /// Sends `body` plus the held `baseUpdatedAt` (omitted when absent — a
    /// `null` would be a hard `422 invalid_base_updated_at`), stores the token
    /// the server echoes back, and on a `409` re-reads once and retries. The
    /// retry is bounded: this route shares `User.updatedAt` with six others, so
    /// an unrelated account write can keep rotating the token, and an unbounded
    /// conflict→re-read→retry loop would never terminate. Giving up throws
    /// ``HLError/writeConflictUnresolved(_:)`` and the surface tells the user.
    private func patchAuthNotificationPrefs(_ body: some Encodable & Sendable) async throws {
        try await withOptimisticConflictRetry(
            conflictCode: OptimisticConflictCode.notificationPrefs,
            token: baseUpdatedAt
        ) { token in
            let req: APIRequest<AuthNotificationPrefsPayload> = try .patch(
                "/api/auth/me/notification-prefs",
                body: OptimisticWriteBody(payload: body, baseUpdatedAt: token)
            )
            let echoed = try await api.send(req)
            // Advance the token off the write echo so a follow-up write in the
            // same session is guarded rather than falling back to unconditional.
            baseUpdatedAt = echoed.updatedAt
        } reread: {
            // Nothing to re-apply: each writer owns one leaf of the blob and
            // the server deep-merges, so the pending change is still correct
            // against the refreshed state. We only need the fresh token.
            try await authNotificationPrefs().updatedAt
        }
    }

    public func setPreference(channelId: String, eventType: String, enabled: Bool) async throws {
        struct Body: Encodable, Sendable {
            let channelId: String
            let eventType: String
            let enabled: Bool
        }
        let req: APIRequest<EmptyPayload> = try .put(
            "/api/notifications/preferences",
            body: Body(channelId: channelId, eventType: eventType, enabled: enabled)
        )
        try await api.sendVoid(req)
    }

    /// **v0.10.0 W-Mood-B** — set the per-user evening mood-reminder hour
    /// (0–23). Server v1.7.0 exposes it at `notificationPrefs.mood.reminderHour`
    /// (read via ``preferences()``); the write rides the existing
    /// `PATCH /api/auth/me/notification-prefs` surface with the same nested
    /// `mood` shape the GET returns. Forward-compatible: an older server
    /// rejects the unknown key, the iOS-local reminder still works off the
    /// UserDefaults mirror + the local default.
    public func setMoodReminderHour(_ hour: Int) async throws {
        struct MoodPrefs: Encodable, Sendable {
            let reminderHour: Int
        }
        struct Body: Encodable, Sendable {
            let mood: MoodPrefs
        }
        let clamped = max(0, min(23, hour))
        try await patchAuthNotificationPrefs(Body(mood: MoodPrefs(reminderHour: clamped)))
    }

    /// **MED-4 / AUDIT-PARITY C3** — set the low-supply runway threshold
    /// (`notificationPrefs.medication.lowStockRunwayDays`, 1–60 days, or `null`
    /// to turn the alert off). Rides the same `PATCH /api/auth/me/notification-prefs`
    /// surface as the mood hour, nesting under `medication` exactly as the GET
    /// returns it. The PATCH carries an idempotency key (auto) + outbox replay
    /// like every other write — a transient failure re-sends on reachability.
    /// Forward-compatible: a pre-v1.16.11 server rejects the unknown key, the
    /// client keeps the value off.
    public func setLowStockRunwayDays(_ days: Int?) async throws {
        struct MedicationPrefs: Encodable, Sendable {
            let lowStockRunwayDays: Int?
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                // Explicit JSON `null` turns the alert off (server distinguishes
                // `undefined` = unchanged from `null` = clear).
                if let lowStockRunwayDays {
                    try c.encode(lowStockRunwayDays, forKey: .lowStockRunwayDays)
                } else {
                    try c.encodeNil(forKey: .lowStockRunwayDays)
                }
            }

            enum CodingKeys: String, CodingKey {
                case lowStockRunwayDays
            }
        }
        struct Body: Encodable, Sendable {
            let medication: MedicationPrefs
        }
        let clamped = days.map { max(medicationLowStockRunwayMin, min(medicationLowStockRunwayMax, $0)) }
        try await patchAuthNotificationPrefs(Body(medication: MedicationPrefs(lowStockRunwayDays: clamped)))
    }

    /// **W-B189 / #23** — set the preventive-care (Vorsorge) reminder opt-in
    /// (`notificationPrefs.measurementReminder.clientManaged`). Rides the same
    /// `PATCH /api/auth/me/notification-prefs` surface as the mood hour + the
    /// low-stock threshold, nesting under `measurementReminder` exactly as the
    /// GET returns it, and inherits the auto idempotency key + outbox replay.
    /// Forward-compatible: a pre-v1.17.1 server rejects the unknown key, the
    /// client keeps the local mirror as the load-bearing value.
    public func setMeasurementReminderClientManaged(_ enabled: Bool) async throws {
        struct MeasurementReminderPrefs: Encodable, Sendable {
            let clientManaged: Bool
        }
        struct Body: Encodable, Sendable {
            let measurementReminder: MeasurementReminderPrefs
        }
        try await patchAuthNotificationPrefs(
            Body(measurementReminder: MeasurementReminderPrefs(clientManaged: enabled))
        )
    }

    /// **CU-20 (#69) — the write the token was introduced for.** Sets
    /// `notificationPrefs.medication.clientManaged`: `true` means iOS owns
    /// medication reminder delivery and the server must not also push.
    ///
    /// Guarded like its siblings, and that guard is the point: the server
    /// deep-merges the whole prefs blob, so before CU-20 a web session writing
    /// from a read taken before this flag was set silently reset it and the
    /// user got both a server push and a local notification for the same dose.
    /// With `baseUpdatedAt` the write either lands or returns 409 having
    /// written nothing.
    public func setMedicationClientManaged(_ enabled: Bool) async throws {
        struct MedicationPrefs: Encodable, Sendable {
            let clientManaged: Bool
        }
        struct Body: Encodable, Sendable {
            let medication: MedicationPrefs
        }
        try await patchAuthNotificationPrefs(Body(medication: MedicationPrefs(clientManaged: enabled)))
    }

    /// Per-channel reliability state (last-success, last-failure, retry-state).
    /// Drives the "Letzte Zustellung: heute, 09:00" line per channel in the UI
    /// (A7 §3.3 issue #2). Cheap GET; safe to call on `.task` + `.refreshable`.
    public func status() async throws -> NotificationStatusPayload {
        try await api.send(.get("/api/notifications/status"))
    }

    /// Re-enable a previously auto-disabled / paused channel. Wraps
    /// `POST /api/notifications/status` (server-side
    /// `reEnableChannel`): clears `disabled_reason`, resets the
    /// consecutive-failure counter + the `next_retry_at` cooldown
    /// window, flips `enabled = true`, and writes an audit-log row.
    /// Returns without value — the caller reloads `status` to refresh
    /// the badge.
    ///
    /// Used by REG-12 (v0.5.6) fix: when the operator sees "Apple Push
    /// (APNs) — pausiert" in Settings, the row exposes an "Erneut
    /// versuchen" button that calls this method so the next reminder
    /// dispatch tries the upstream again instead of skipping the
    /// channel during the cooldown window.
    public func reEnableChannel(channelId: String) async throws {
        struct Body: Encodable, Sendable {
            let channelId: String
        }
        let req: APIRequest<EmptyPayload> = try .post(
            "/api/notifications/status",
            body: Body(channelId: channelId)
        )
        try await api.sendVoid(req)
    }
}
