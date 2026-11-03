import Foundation

/// The Insights **Recovery** family as the page reads it, built by
/// `RecoveryInsightsRepository` from `GET /api/analytics?slice=summaries` and
/// cached as built (SWR, `.insightsRecovery`).
///
/// **Server-authoritative, never recomputed.** Every number here is a field of
/// the server's per-type summary, passed through unchanged: `latest` is the
/// newest canonical reading, `average30` the server's `avg30`. The app derives
/// nothing from them except which ones to show.
///
/// **1.4 B3 — only what is current.** An item exists only when its type has a
/// reading in the last 30 days (`avg30 != nil`), so a value from 2024 never
/// stands on the page as if it were today's. An empty family is still a value:
/// it carries the server's reason the page is empty (`recoveryEmpty`) and the
/// HRV measure decision, both of which matter without any recovery item.
public struct RecoveryInsightsDTO: Codable, Sendable, Equatable {
    /// The family types with a reading in the last 30 days, in page order.
    public let items: [Item]
    /// Server `recoveryEmpty` (v1.43.7): `general`, `oura_permission`,
    /// `oura_no_resilience`, or `nil` when the server has something to chart.
    /// Rendered as sent; the app never works the reason out itself.
    public let emptyReason: String?
    /// `true` when SDNN (`HEART_RATE_VARIABILITY`) has no reading in the last
    /// 30 days while RMSSD (`HRV_RMSSD`) has: the HRV page then shows RMSSD
    /// instead of standing on an SDNN series that stopped.
    public let hrvShowsRMSSD: Bool

    public init(items: [Item] = [], emptyReason: String? = nil, hrvShowsRMSSD: Bool = false) {
        self.items = items
        self.emptyReason = emptyReason
        self.hrvShowsRMSSD = hrvShowsRMSSD
    }

    /// `true` when at least one family type has a current reading.
    public var hasContent: Bool {
        !items.isEmpty
    }

    /// The item for a server `MeasurementType`, if it is current.
    public func item(for type: String) -> Item? {
        items.first { $0.id == type }
    }

    /// One current family type: its newest reading and its 30-day average,
    /// both exactly as the server summarised them.
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        /// Server `MeasurementType` (e.g. `DAY_STRAIN`).
        public let id: String
        /// Server `latest`, in the type's wire unit.
        public let latest: Double
        /// Server `avg30`, in the type's wire unit.
        public let average30: Double

        public init(id: String, latest: Double, average30: Double) {
            self.id = id
            self.latest = latest
            self.average30 = average30
        }
    }
}
