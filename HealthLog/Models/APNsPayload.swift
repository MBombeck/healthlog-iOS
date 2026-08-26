import Foundation

/// Geparste APNs-Payload. `eventType` bleibt absichtlich `String` — Server ist
/// die Quelle der Wahrheit, neue Event-Types sollen **nicht** den iOS-Build
/// brechen. Bekannte Werte (per `06-ios-responsibilities.md` § Domain 3):
/// `MEDICATION_REMINDER`, `MEASUREMENT_ANOMALY`, `COMPLIANCE_LOW`,
/// `WITHINGS_SYNC_FAILED`, `SYSTEM_ALERT`, `PERSONAL_RECORD`.
///
/// v0.5.3 F-4 — Medication-reminder pushes carry three extra top-level keys
/// in `userInfo`, fed from the server's `metadata` map on the dispatcher
/// path (`src/lib/jobs/reminder-worker.ts` → `metadata.medicationId` etc.):
/// - `medicationId` (string, required for actions)
/// - `scheduleId` (string, identifies the recurring schedule row)
/// - `scheduledFor` (ISO-8601 timestamp, when the dose was due)
///
/// These let the action handler call the server's bulk intake endpoint
/// without needing a pre-existing `MedicationIntakeEvent` row in metadata
/// (server pre-creates only on the RED / missed-dose phase).
public struct APNsPayload: Sendable, Equatable {
    public let title: String?
    public let body: String?
    public let eventType: String?
    public let metricType: String?
    public let deepLink: URL?
    public let isContentAvailable: Bool
    public let medicationId: String?
    public let scheduleId: String?
    public let scheduledFor: Date?
    /// v1.18.6 (#32) — the Vorsorge reminder id carried by a
    /// `MEASUREMENT_REMINDER` push, so the foreground "Erledigt" action can POST
    /// `…/{id}/complete` (server-authoritative) instead of only deep-linking.
    /// Server-coord: `reminderId` must be added to the apns `IOS_METADATA_ALLOWLIST`
    /// for it to ride the wire — until then this stays `nil` and the handler
    /// gracefully falls back to the capture deep-link (never dead-ends).
    public let reminderId: String?

    public init(
        title: String?,
        body: String?,
        eventType: String?,
        metricType: String?,
        deepLink: URL?,
        isContentAvailable: Bool = false,
        medicationId: String? = nil,
        scheduleId: String? = nil,
        scheduledFor: Date? = nil,
        reminderId: String? = nil
    ) {
        self.title = title
        self.body = body
        self.eventType = eventType
        self.metricType = metricType
        self.deepLink = deepLink
        self.isContentAvailable = isContentAvailable
        self.medicationId = medicationId
        self.scheduleId = scheduleId
        self.scheduledFor = scheduledFor
        self.reminderId = reminderId
    }

    /// Pure parser. Akzeptiert die rohen `userInfo`-Dictionaries, die UIKit /
    /// `UNUserNotificationCenter` liefert. Liefert `nil` nur wenn `userInfo`
    /// komplett leer ist — sonst best-effort mit allen Felder optional.
    public static func parse(userInfo: [AnyHashable: Any]) -> APNsPayload? {
        guard !userInfo.isEmpty else { return nil }

        let aps = userInfo["aps"] as? [String: Any]
        let alert = aps?["alert"] as? [String: Any]
        // Apple erlaubt auch `alert` als String — dann ist body=string, title=nil.
        let alertString = aps?["alert"] as? String

        let title = alert?["title"] as? String
        let body = (alert?["body"] as? String) ?? alertString

        let eventType = userInfo["eventType"] as? String
        let metricType = userInfo["metricType"] as? String
        let deepLinkString = userInfo["deepLink"] as? String
        let deepLink = deepLinkString.flatMap { URL(string: $0) }

        let contentAvailable: Bool = {
            if let n = aps?["content-available"] as? Int { return n == 1 }
            if let b = aps?["content-available"] as? Bool { return b }
            return false
        }()

        let medicationId = userInfo["medicationId"] as? String
        let scheduleId = userInfo["scheduleId"] as? String
        let scheduledForRaw = userInfo["scheduledFor"] as? String
        let scheduledFor = scheduledForRaw.flatMap(Self.parseISO8601)
        let reminderId = userInfo["reminderId"] as? String

        return APNsPayload(
            title: title,
            body: body,
            eventType: eventType,
            metricType: metricType,
            deepLink: deepLink,
            isContentAvailable: contentAvailable,
            medicationId: medicationId,
            scheduleId: scheduleId,
            scheduledFor: scheduledFor,
            reminderId: reminderId
        )
    }

    /// ISO-8601 parser. Server emits `2026-05-17T12:00:00.000Z`; the
    /// offset-only variant `2026-05-17T12:00:00Z` is also accepted via the
    /// fallback formatter. `ISO8601DateFormatter` rejects strings whose
    /// fractional-seconds presence does not match its options, so two
    /// formatters cover both shapes. Both formatters are created per-call
    /// because `ISO8601DateFormatter` is not `Sendable` under Swift 6
    /// strict-concurrency — sharing them across actors would require
    /// `nonisolated(unsafe)` which we reject as a smell here. Cheap to
    /// allocate (microseconds) and the parse path runs once per push.
    static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
