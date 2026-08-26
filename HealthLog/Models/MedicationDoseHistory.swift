import Foundation

// v0.14.8 W3-MEDCONTRACT — server dose-history ledger (server v1.15.18+,
// schedule-eras v1.16.3).
//
// `GET /api/medications/{id}/dose-history?from&to` returns the ONE unified
// per-slot ledger the server's compliance % and the web "Verlauf" tab read:
// every expected slot with a status (on-time / late / skipped / missed /
// upcoming) plus every off-schedule intake tagged ad-hoc. Built server-side
// from the same band minter + `reconstructDoseHistory` the write/edit
// attribution consumes, AND era-aware since v1.16.3: a past day is evaluated
// against the schedule that was live THEN (`scheduleRevisions`), which no
// client-side projection from the *current* schedule can reproduce.
//
// Decode doctrine: tolerant-first. Every field beyond the v1.15.18 core is
// optional; `kind`/`status` decode as raw strings with typed accessors so an
// unknown future literal degrades to a renderable-but-inert row instead of a
// decode failure. Against ≤ v1.15.17 servers the route 404s — callers treat
// any fetch failure as "ledger unavailable" and keep the local derivation.

/// Wire envelope of `GET /api/medications/{id}/dose-history`.
/// Server source: `src/app/api/medications/[id]/dose-history/route.ts`.
public struct MedicationDoseHistoryEnvelope: Codable, Sendable, Equatable {
    /// Resolved window start (server clamps to `max(requested, createdAt,
    /// to − 366 d)`).
    public let from: Date
    /// Resolved window end (defaults to server `now`).
    public let to: Date
    /// Band family the slots were minted from: `daily | weekly | one_shot |
    /// none`. Raw string — informational only on iOS.
    public let family: String?
    /// Whether any expected slot was minted in the window. `false` for a
    /// PRN-only / unscheduled medication (rows then carry ad-hoc takes only).
    public let hasExpectedSlots: Bool?
    public let rows: [MedicationDoseHistoryRow]

    public init(
        from: Date,
        to: Date,
        family: String? = nil,
        hasExpectedSlots: Bool? = nil,
        rows: [MedicationDoseHistoryRow]
    ) {
        self.from = from
        self.to = to
        self.family = family
        self.hasExpectedSlots = hasExpectedSlots
        self.rows = rows
    }
}

/// Typed view of the server's `DoseHistoryStatus` union.
public enum MedicationDoseHistoryStatus: String, Sendable, Equatable {
    case takenOnTime = "taken_on_time"
    case takenLate = "taken_late"
    case skipped
    case missed
    case upcoming
    case adHoc = "ad_hoc"
}

/// One ledger row: a scheduled slot or a standalone off-schedule intake.
public struct MedicationDoseHistoryRow: Codable, Sendable, Hashable, Identifiable {
    /// `"slot"` or `"ad_hoc"`. Raw string for forward-compat; use `isAdHoc`.
    public let kind: String
    /// Slot anchor instant, or the ad-hoc take's own time.
    public let at: Date
    /// The slot's `HH:mm` label; `nil` on ad-hoc rows.
    public let timeOfDay: String?
    /// Raw server status literal — use `status` for the typed read.
    public let statusRaw: String
    /// v1.15.20 — row is bound by a deliberate user pin (`USER_PIN`).
    /// On a slot row: "zugeordnet" (offer "Zuordnung lösen"). On an ad-hoc
    /// row: a deliberately released take (no badge, binding is user-fixed).
    public let pinned: Bool?
    /// v1.15.20 — due-context for an ad-hoc take: the nearest slot it could
    /// belong to. Offer the pin only when `filled == false`.
    public let nearestSlot: NearestSlot?
    /// The intake event attributed to this row, if any. `nil` on projected
    /// slots no DB row exists for (pure miss / upcoming).
    public let intake: Intake?

    /// Stable identity for SwiftUI lists: the intake row id when one exists,
    /// else the slot anchor (unique per medication + window).
    public var id: String {
        if let intakeID = intake?.id { return intakeID }
        return "slot-\(at.timeIntervalSince1970)-\(timeOfDay ?? "")"
    }

    public var status: MedicationDoseHistoryStatus? {
        MedicationDoseHistoryStatus(rawValue: statusRaw)
    }

    public var isAdHoc: Bool {
        kind == "ad_hoc"
    }

    public struct NearestSlot: Codable, Sendable, Hashable {
        /// The slot's canonical anchor instant — the exact value
        /// `forceSlotInstant` must echo on a pin.
        public let at: Date
        /// The slot's `HH:mm` label.
        public let timeOfDay: String
        /// `true` when the slot cannot be offered for pinning (already
        /// served, or the take sits outside the suggestion window).
        public let filled: Bool

        public init(at: Date, timeOfDay: String, filled: Bool) {
            self.at = at
            self.timeOfDay = timeOfDay
            self.filled = filled
        }
    }

    public struct Intake: Codable, Sendable, Hashable {
        public let id: String?
        public let scheduledFor: Date
        public let takenAt: Date?
        public let skipped: Bool
        /// Cron-marked forgotten dose (counts as missed, not skipped).
        public let autoMissed: Bool?
        /// **H6 / v1.16.4 — per-intake actual-dose override.** Free text the
        /// user recorded for THIS take when it deviates from (or documents)
        /// the medication's configured dose, e.g. a half tablet or a
        /// titration step (server `doseTaken`, max 50 chars). `nil` = taken
        /// under the configured dose. Optional / nil against servers that
        /// omit the key so the decode stays tolerant.
        public let doseTaken: String?

        /// **Build 6.3 / Issue #64 — intake provenance (server `source`).**
        /// Which surface created THIS intake row: `WEB | API | REMINDER |
        /// IMPORT | APPLE_HEALTH`.
        ///
        /// **CU-18 (v1.32.8) — die Route LIEFERT das Feld.** Der frühere
        /// Docblock ("Route emittiert es noch nicht, #64 server-seitig offen")
        /// ist überholt: seit Server v1.32.8 trägt jede Intake-Zeile der
        /// dose-history ein `source`; nur Zeilen, die vor der Migration
        /// entstanden sind, tragen `null`. Das Feld bleibt trotzdem optional
        /// und ein roher String — `null` (Altbestand), Abwesenheit (≤ v1.32.7)
        /// und ein künftiges sechstes Literal müssen alle decodieren statt zu
        /// werfen. Typisiert über ``MedicationDoseHistoryRow/provenance``.
        public let source: String?

        public init(
            id: String?,
            scheduledFor: Date,
            takenAt: Date?,
            skipped: Bool,
            autoMissed: Bool? = nil,
            doseTaken: String? = nil,
            source: String? = nil
        ) {
            self.id = id
            self.scheduledFor = scheduledFor
            self.takenAt = takenAt
            self.skipped = skipped
            self.autoMissed = autoMissed
            self.doseTaken = doseTaken
            self.source = source
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case at
        case timeOfDay
        case statusRaw = "status"
        case pinned
        case nearestSlot
        case intake
    }

    public init(
        kind: String,
        at: Date,
        timeOfDay: String?,
        statusRaw: String,
        pinned: Bool? = nil,
        nearestSlot: NearestSlot? = nil,
        intake: Intake? = nil
    ) {
        self.kind = kind
        self.at = at
        self.timeOfDay = timeOfDay
        self.statusRaw = statusRaw
        self.pinned = pinned
        self.nearestSlot = nearestSlot
        self.intake = intake
    }

    /// **Build 6.3 / Issue #64 — typed provenance read.** `nil` when the row
    /// carries no `source` (a pre-v1.32.8 intake row, where the server stores
    /// `null`) or an unmodelled future literal. Consumers render the chip ONLY
    /// when this is non-nil, so an unnameable value shows nothing instead of a
    /// guess (`LedgerHistoryRow` gates the chip on exactly this value).
    var provenance: DoseIntakeProvenance? {
        guard let raw = intake?.source else { return nil }
        return DoseIntakeProvenance(wireValue: raw)
    }
}

/// **Build 6.3 / Issue #64 — dose-history intake provenance.** Label-map for
/// the five server `source` literals the dose-history ledger stamps since
/// v1.32.8. Unknown / absent strings resolve to `nil` at the call-site (see
/// ``MedicationDoseHistoryRow/provenance``) rather than to a catch-all case, so
/// a chip is shown ONLY for a value we can name — never a guessed or raw
/// string in the UI.
public enum DoseIntakeProvenance: String, Sendable, Equatable, CaseIterable {
    /// Logged on the web app.
    case web = "WEB"
    /// Logged through the public / integration API.
    case api = "API"
    /// Confirmed from a reminder notification action.
    case reminder = "REMINDER"
    /// Backfilled by an import (CSV / migration).
    case `import` = "IMPORT"
    /// Mirrored from Apple Health's HealthKit Medications.
    case appleHealth = "APPLE_HEALTH"

    /// Tolerant parse — an unknown / absent literal yields `nil` so the caller
    /// suppresses the badge (Issue #64: do not render a source we cannot label).
    public init?(wireValue raw: String) {
        self.init(rawValue: raw)
    }

    /// Localized human label for the provenance chip.
    public var labelResource: LocalizedStringResource {
        switch self {
        case .web: "med.ledger.provenance.web"
        case .api: "med.ledger.provenance.api"
        case .reminder: "med.ledger.provenance.reminder"
        case .import: "med.ledger.provenance.import"
        case .appleHealth: "med.ledger.provenance.apple_health"
        }
    }

    /// SF Symbol paired with the chip.
    public var systemImage: String {
        switch self {
        case .web: "globe"
        case .api: "chevron.left.forwardslash.chevron.right"
        case .reminder: "bell"
        case .import: "square.and.arrow.down"
        case .appleHealth: "heart"
        }
    }
}
