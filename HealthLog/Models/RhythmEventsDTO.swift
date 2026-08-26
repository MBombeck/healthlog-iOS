import Foundation

/// Wire-form mirror of `GET /api/insights/rhythm-events` (server v1.10.0,
/// route at `src/app/api/insights/rhythm-events/route.ts`).
///
/// **What it is.** A timeline of the on-device notifications the user's
/// wearable (Apple Watch / Withings ScanWatch) already produced + synced —
/// irregular-rhythm / high-HR / low-HR / walking-steadiness /
/// breathing-disturbance. Each row is a discrete EVENT (server
/// `EVENT_MEASUREMENT_TYPES`), carrying the DEVICE's own verdict in
/// `classification`.
///
/// **Regulatory framing (load-bearing — do NOT soften).** This is AWARENESS /
/// SCREENING of the DEVICE's own certified decision, never a HealthLog
/// diagnosis. iOS renders ONLY the classification RESULT the device's
/// FDA-cleared / CE-marked on-device algorithm produced; it never
/// re-classifies, never shows a waveform, and pairs the timeline with a
/// permanent, non-dismissible disclaimer (server/web copy contract,
/// `ios-coord/v1.10.0-server-to-ios-ingestion.md §2`).
///
/// **Data-availability gate.** An account with no events returns
/// `{ events: [], hasEvents: false }`; the card self-suppresses (`EmptyView`)
/// rather than painting an empty / alarming surface.
///
/// **Server-derived (paired only).** This is a pure server read — no
/// on-device fallback — so the card hides in standalone / no-server.
public struct RhythmEventsDTO: Codable, Sendable, Equatable {
    public let events: [Event]
    public let hasEvents: Bool

    public init(events: [Event], hasEvents: Bool) {
        self.events = events
        self.hasEvents = hasEvents
    }

    /// One device-flagged categorical event row.
    public struct Event: Codable, Sendable, Equatable, Identifiable {
        /// Server measurement-row id (stable, used as the SwiftUI list id).
        public let id: String
        /// The EVENT MeasurementType (`IRREGULAR_RHYTHM_NOTIFICATION`,
        /// `HIGH_HEART_RATE_EVENT`, `LOW_HEART_RATE_EVENT`,
        /// `WALKING_STEADINESS_EVENT`, `BREATHING_DISTURBANCE_EVENT`).
        public let type: String
        /// The device's verdict (`IRREGULAR | NOT_DETECTED | INCONCLUSIVE |
        /// LOW | VERY_LOW | FIRED`), or `nil` when the device emitted no
        /// classification. Surfaced VERBATIM as the device's decision.
        public let classification: String?
        /// When the device produced the notification (ISO 8601).
        public let occurredAt: Date
        /// Ingest source (`APPLE_HEALTH`, `WITHINGS`, …).
        public let source: String?
        /// Device model string, when the wearable reported one.
        public let deviceType: String?

        public init(
            id: String,
            type: String,
            classification: String?,
            occurredAt: Date,
            source: String?,
            deviceType: String?
        ) {
            self.id = id
            self.type = type
            self.classification = classification
            self.occurredAt = occurredAt
            self.source = source
            self.deviceType = deviceType
        }
    }
}
