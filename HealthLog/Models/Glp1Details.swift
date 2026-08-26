import Foundation

/// Wire shape for `GET /api/medications/[id]/glp1`. Server source:
/// `src/app/api/medications/[id]/glp1/route.ts:91-105`.
///
/// Carries per-medication "extras" the PK detail screen needs:
/// chronological dose-change history (`doseChanges`), the last 12 injection
/// events (`recentIntakes`), and running pen-inventory math (`inventory` —
/// may be `null` when the medication has no `dosesPerUnit` configured).
public struct Glp1DetailsDTO: Codable, Sendable, Hashable {
    public let doseChanges: [Glp1DoseChangeDTO]
    public let recentIntakes: [Glp1RecentIntakeDTO]
    public let inventory: Glp1InventoryDTO?

    public init(
        doseChanges: [Glp1DoseChangeDTO],
        recentIntakes: [Glp1RecentIntakeDTO],
        inventory: Glp1InventoryDTO? = nil
    ) {
        self.doseChanges = doseChanges
        self.recentIntakes = recentIntakes
        self.inventory = inventory
    }
}

/// Single dose-change row. `effectiveFrom` parses via `JSONDecoder.hlDefault`
/// (ISO-8601 fractional/plain or `YYYY-MM-DD`). `note` is optional free-text.
public struct Glp1DoseChangeDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let effectiveFrom: Date
    public let doseValue: Double
    public let doseUnit: String
    public let note: String?

    public init(id: String, effectiveFrom: Date, doseValue: Double, doseUnit: String, note: String? = nil) {
        self.id = id
        self.effectiveFrom = effectiveFrom
        self.doseValue = doseValue
        self.doseUnit = doseUnit
        self.note = note
    }
}

/// Single recent-intake row from the `/glp1` endpoint. The server attaches
/// only the timestamp + optional injection-site rotation hint — for full
/// intake history with status flags, use the paginated `/intake` endpoint.
public struct Glp1RecentIntakeDTO: Codable, Sendable, Hashable {
    public let takenAt: Date?
    public let injectionSite: String?

    public init(takenAt: Date?, injectionSite: String? = nil) {
        self.takenAt = takenAt
        self.injectionSite = injectionSite
    }
}

/// Running pen-inventory math. Server populates only when the medication
/// has both `dosesPerUnit` set and at least one inventory event recorded —
/// otherwise the field is `null`.
public struct Glp1InventoryDTO: Codable, Sendable, Hashable {
    public let pensRemaining: Int?
    public let dosesRemaining: Int?
    public let weeksOfSupply: Int?
    public let lowStock: Bool

    public init(pensRemaining: Int?, dosesRemaining: Int?, weeksOfSupply: Int?, lowStock: Bool) {
        self.pensRemaining = pensRemaining
        self.dosesRemaining = dosesRemaining
        self.weeksOfSupply = weeksOfSupply
        self.lowStock = lowStock
    }
}

/// Wire shape for `GET /api/medications/[id]/intake?limit=N&sortBy=takenAt&sortDir=desc`.
/// Server source: `src/app/api/medications/[id]/intake/route.ts:160-195`. The
/// detail screen uses this for the paginated intake-history card.
///
/// `events[].scheduledFor` is the planned timestamp; `takenAt` is the actual
/// administration time (or `nil` when the dose is still pending / skipped).
public struct PaginatedIntakeEnvelope: Codable, Sendable {
    public let events: [PaginatedIntakeEvent]
    public let meta: PaginatedIntakeMeta

    public init(events: [PaginatedIntakeEvent], meta: PaginatedIntakeMeta) {
        self.events = events
        self.meta = meta
    }
}

public struct PaginatedIntakeEvent: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let takenAt: Date?
    public let skipped: Bool
    public let scheduledFor: Date
    public let injectionSite: String?

    public init(
        id: String,
        takenAt: Date?,
        skipped: Bool,
        scheduledFor: Date,
        injectionSite: String? = nil
    ) {
        self.id = id
        self.takenAt = takenAt
        self.skipped = skipped
        self.scheduledFor = scheduledFor
        self.injectionSite = injectionSite
    }
}

public struct PaginatedIntakeMeta: Codable, Sendable, Hashable {
    public let total: Int?
    public let limit: Int?
    public let offset: Int?

    public init(total: Int? = nil, limit: Int? = nil, offset: Int? = nil) {
        self.total = total
        self.limit = limit
        self.offset = offset
    }
}
