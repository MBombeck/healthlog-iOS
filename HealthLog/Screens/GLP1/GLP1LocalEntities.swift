import Foundation
import SwiftData

// Local-only SwiftData entities for the GLP-1 detail stack.
//
// **Scope (v0.5.x):** these entries live **on-device only**. The server
// already authoritatively serves the *aggregate* views that overlap (dose
// changes via `Glp1DetailsDTO.doseChanges`, pen-inventory totals via
// `Glp1InventoryDTO`, and the per-intake injection-site via
// `PaginatedIntakeEvent.injectionSite`); the local entries augment those
// with user-editable journal-style state the server does not yet store.
//
// **Future server-sync (post-v0.5.x):** when SB-T5-side-effects /
// SB-T5-inventory / SB-T5-titration-edit / SB-T5-site-rotation land
// server-side, these entities become the iOS cache layer in front of the
// new endpoints (`POST /api/medications/[id]/side-effect`, etc.) with the
// same optimistic-write + outbox-fallback pattern the T-0 foundation
// established for medications proper. The local rows then carry a
// nullable `serverID: String?` and a `syncedAt: Date?` to track which
// rows have been mirrored. We keep the schema "ready" for that:
// `serverID` + `syncedAt` are already on each entity, both currently
// always `nil`.
//
// **MDR boundary reminder:** every copy that surfaces these entries must
// be journal/informational only. No "if X then do Y" prescriptive
// language, no autonomous titration recommendation. The titration ladder
// surfaces *historical* dose changes + the catalog's *standard* next-step
// label ("Übliche Folge-Stufe gemäß Hersteller-Leitfaden — bespreche mit
// Arzt vor Wechsel."), never a personal recommendation.

// MARK: - Titration ladder

/// Per-medication titration step entry. Used by the titration ladder view
/// for *local* dose-change journaling. Server-authoritative dose history
/// (`Glp1DetailsDTO.doseChanges`) is rendered alongside these — local
/// entries take precedence when timestamps overlap (user just edited).
@Model
public final class TitrationStepEntry {
    /// Stable identifier; UUID.uuidString so we can mirror into wire-shape
    /// once an upload path exists.
    @Attribute(.unique) public var id: String
    /// Foreign key to `Medication.id` (server-issued string). Indexed for
    /// the by-medication query path.
    public var medicationID: String
    /// When the user moved to this dose. Indexed for chronological queries.
    public var effectiveFrom: Date
    /// Recorded dose in milligrams. Matches the catalog's
    /// `titrationStepsMg` unit so a UI step "1.0 mg" reads cleanly.
    public var doseMg: Double
    /// Free-text journal note. Optional; capped at 512 chars at the
    /// service-layer boundary (validation happens before insertion).
    public var note: String?
    /// Wall-clock creation timestamp.
    public var createdAt: Date
    /// Future server-sync marker. Always `nil` in v0.5.x.
    public var serverID: String?
    /// Future server-sync marker. Always `nil` in v0.5.x.
    public var syncedAt: Date?

    public init(
        id: String = UUID().uuidString,
        medicationID: String,
        effectiveFrom: Date,
        doseMg: Double,
        note: String? = nil,
        createdAt: Date = .now,
        serverID: String? = nil,
        syncedAt: Date? = nil
    ) {
        self.id = id
        self.medicationID = medicationID
        self.effectiveFrom = effectiveFrom
        self.doseMg = doseMg
        self.note = note
        self.createdAt = createdAt
        self.serverID = serverID
        self.syncedAt = syncedAt
    }
}

// MARK: - Side-effects logbook

/// GI / systemic side-effects journal entry. One row per logging event
/// (the UI logs per-day, not per-intake — the per-intake granularity
/// surfaces later only if the operator asks). `kind` is server-stable
/// canonical raw; `severity` is 0–3 (none / mild / moderate / severe).
@Model
public final class SideEffectEntry {
    @Attribute(.unique) public var id: String
    public var medicationID: String
    /// When the side-effect was experienced (user-supplied). May be
    /// "today" or backdated.
    public var loggedAt: Date
    /// Canonical raw string of `SideEffectKind`. Storing the raw keeps
    /// the schema forward-compatible with future kinds without a
    /// migration (mirrors `OutboxOperation.kindRaw` pattern).
    public var kindRaw: String
    /// 0–3 severity slider. 0 = none, 1 = mild, 2 = moderate,
    /// 3 = severe. Validated at the service boundary.
    public var severity: Int
    /// Optional free-text journal note. Capped at 512 chars at insert.
    public var note: String?
    public var createdAt: Date
    public var serverID: String?
    public var syncedAt: Date?

    public init(
        id: String = UUID().uuidString,
        medicationID: String,
        loggedAt: Date,
        kindRaw: String,
        severity: Int,
        note: String? = nil,
        createdAt: Date = .now,
        serverID: String? = nil,
        syncedAt: Date? = nil
    ) {
        self.id = id
        self.medicationID = medicationID
        self.loggedAt = loggedAt
        self.kindRaw = kindRaw
        self.severity = max(0, min(3, severity))
        self.note = note
        self.createdAt = createdAt
        self.serverID = serverID
        self.syncedAt = syncedAt
    }
}

/// Canonical side-effect kinds for the GLP-1 logbook. Closed enum keeps
/// the picker UX bounded; user-defined / "other" lives in `note`. Raw
/// strings are stable and server-bound when the future side-effect
/// endpoint lands.
public enum SideEffectKind: String, CaseIterable, Sendable, Hashable {
    case nausea
    case vomiting
    case constipation
    case diarrhea
    case fatigue
    case appetiteLoss = "appetite_loss"
    case injectionSiteReaction = "injection_site_reaction"
    case headache

    /// v0.12 SP3 — maps the closed iOS picker kind onto the server's
    /// authoritative side-effect `entry` taxonomy
    /// (`src/lib/medications/side-effects/taxonomy.ts`, 21 entries). The
    /// server derives `category` from this entry, so iOS sends only the entry.
    /// `headache` has no exact server entry — it rides under the nearest
    /// cognitive signal (`DIZZINESS`) so it still round-trips rather than
    /// being silently dropped; the free-text note preserves the literal label.
    public var serverEntry: String {
        switch self {
        case .nausea: "NAUSEA"
        case .vomiting: "VOMITING"
        case .constipation: "CONSTIPATION"
        case .diarrhea: "DIARRHEA"
        case .fatigue: "LOW_ENERGY"
        case .appetiteLoss: "ANOREXIA"
        case .injectionSiteReaction: "INJECTION_REDNESS"
        case .headache: "DIZZINESS"
        }
    }

    /// Inverse of `serverEntry` for hydrating server rows back into the iOS
    /// picker model. Unknown / unmapped entries return `nil` so the row still
    /// renders (the store keeps the raw + note) without crashing.
    public static func from(serverEntry: String) -> SideEffectKind? {
        switch serverEntry {
        case "NAUSEA": .nausea
        case "VOMITING": .vomiting
        case "CONSTIPATION": .constipation
        case "DIARRHEA": .diarrhea
        case "LOW_ENERGY", "ELECTROLYTE_FATIGUE": .fatigue
        case "ANOREXIA": .appetiteLoss
        case "INJECTION_REDNESS", "INJECTION_SWELLING", "INJECTION_BRUISING", "INJECTION_INDURATION":
            .injectionSiteReaction
        case "DIZZINESS": .headache
        default: nil
        }
    }
}

/// v0.12 SP3 — severity mapping between the iOS 0–3 logbook slider and the
/// server's 1–5 Likert scale (`createSideEffectSchema`, min 1 max 5).
public enum SideEffectSeverityBridge {
    /// 0–3 (iOS) → 1–5 (server). 0/1→1 (mild), 2→3 (moderate), 3→5 (severe).
    public static func toServer(_ local: Int) -> Int {
        switch max(0, min(3, local)) {
        case 0, 1: 1
        case 2: 3
        default: 5
        }
    }

    /// 1–5 (server) → 0–3 (iOS) for hydration.
    public static func toLocal(_ server: Int) -> Int {
        switch max(1, min(5, server)) {
        case 1: 1
        case 2, 3: 2
        default: 3
        }
    }
}

// MARK: - Pen inventory

/// User-recorded pen inventory entry — "I just opened a new pen on
/// 2026-05-12, dispense date 2026-05-10, X mg per dose, 4 doses". The
/// server already publishes the *aggregate* via `Glp1InventoryDTO`;
/// these local entries let the user log pens explicitly without round-
/// tripping the server (which currently has no write endpoint for this).
@Model
public final class PenInventoryEntry {
    @Attribute(.unique) public var id: String
    public var medicationID: String
    /// Manufacturer / brand label. Free-text so the user can record
    /// generic names; UI prefills from the resolved catalog brand when
    /// available.
    public var manufacturer: String
    /// Strength as a free-text label ("1.0 mg / dose", "0.25 mg"). Free-
    /// text lets us mirror the pre-existing `medication.dose` shape.
    public var doseStrength: String
    /// When the user obtained the pen.
    public var dispensedAt: Date
    /// When the user first used the pen — optional, populated when the
    /// user marks the pen as "started".
    public var firstUsedAt: Date?
    /// When the user marked the pen as "finished" / empty.
    public var finishedAt: Date?
    public var notes: String?
    public var createdAt: Date
    public var serverID: String?
    public var syncedAt: Date?

    public init(
        id: String = UUID().uuidString,
        medicationID: String,
        manufacturer: String,
        doseStrength: String,
        dispensedAt: Date,
        firstUsedAt: Date? = nil,
        finishedAt: Date? = nil,
        notes: String? = nil,
        createdAt: Date = .now,
        serverID: String? = nil,
        syncedAt: Date? = nil
    ) {
        self.id = id
        self.medicationID = medicationID
        self.manufacturer = manufacturer
        self.doseStrength = doseStrength
        self.dispensedAt = dispensedAt
        self.firstUsedAt = firstUsedAt
        self.finishedAt = finishedAt
        self.notes = notes
        self.createdAt = createdAt
        self.serverID = serverID
        self.syncedAt = syncedAt
    }
}

// MARK: - Injection-site picker

/// One row per injection event the user records via the iOS site-picker.
/// The server-side aggregate (`PaginatedIntakeEvent.injectionSite` on the
/// intake history) covers what *was* logged at intake time; this local
/// table covers the "I just injected at site X" UX action that does not
/// yet round-trip a server intake row (server intake rows are created on
/// the `record(intake:)` flow which is separate from "let me pick a site
/// for next time"). The site-rotation suggestion algorithm reads the
/// union of local + server rows.
@Model
public final class InjectionSiteEntry {
    @Attribute(.unique) public var id: String
    public var medicationID: String
    /// When the injection was administered (user-supplied; may be
    /// backdated).
    public var injectedAt: Date
    /// Canonical raw of `InjectionSite`. Storing raw keeps the schema
    /// forward-compatible.
    public var siteRaw: String
    public var note: String?
    public var createdAt: Date
    public var serverID: String?
    public var syncedAt: Date?

    public init(
        id: String = UUID().uuidString,
        medicationID: String,
        injectedAt: Date,
        siteRaw: String,
        note: String? = nil,
        createdAt: Date = .now,
        serverID: String? = nil,
        syncedAt: Date? = nil
    ) {
        self.id = id
        self.medicationID = medicationID
        self.injectedAt = injectedAt
        self.siteRaw = siteRaw
        self.note = note
        self.createdAt = createdAt
        self.serverID = serverID
        self.syncedAt = syncedAt
    }
}

// `InjectionSite` (+ `InjectionSiteEffectiveSet`) moved to
// `Models/InjectionSite.swift` (v0.11) so the plattform-free Core /
// widget-extension targets can reference it from the medications repo +
// wire bodies. The SwiftData entities here keep using it unchanged.

// MARK: - Schema v1

/// Schema versioning seed for the GLP-1 local store. Mirrors the
/// `OutboxSchemaV1` pattern — start from a named version rather than
/// "anonymous v0" so the first migration is explicit. When the server-
/// sync work lands, a v2 schema will add `serverID` indexing + a
/// `dirtyFlag` row for replay-on-reachability.
public enum GLP1SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [
            TitrationStepEntry.self,
            SideEffectEntry.self,
            PenInventoryEntry.self,
            InjectionSiteEntry.self
        ]
    }
}
