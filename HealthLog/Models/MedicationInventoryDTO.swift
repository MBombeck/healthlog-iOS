import Foundation

// SP4 (v0.12) — wire DTOs for the server-backed medication supply CRUD.
//
// Server contract (READ verbatim, v1.16.12):
//   - `src/app/api/medications/[id]/inventory/route.ts`
//       GET  → apiSuccess({ items: MedicationInventoryItem[], meta: { total } })
//       POST → apiSuccess(MedicationInventoryItem, 201)
//              body: { unitsTotal, containerType?, manufacturer?, doseStrength?,
//                      printedExpiry?, purchasedAt?, notes? }
//   - `src/app/api/medications/[id]/inventory/[itemId]/route.ts`
//       PATCH  → apiSuccess(MedicationInventoryItem)
//               body: { markAsFirstUseAt? (nullable — `null` DELETES the
//                       first-use date), markAsUsedUp?, printedExpiry?
//                       (nullable), unitsRemaining?, notes? }
//       DELETE → apiSuccess({ id, deleted: true })
//   - `src/lib/validations/medication.ts`
//       (createInventoryItemSchema / updateInventoryItemSchema)
//   - `src/lib/medications/inventory/service.ts` (serializeInventoryItem)
//   - `src/lib/medications/inventory/state-machine.ts` (state enum)
//
// **v1.16.10 wire rename (C1):** the inventory endpoints "speak one wire
// dialect" — the request + response fields are `unitsTotal` / `unitsRemaining`
// (they always counted UNITS, mapped to doses via `Medication.unitsPerDose`).
// The pre-v1.16.10 names were `dosesTotal` / `dosesRemaining`; the server no
// longer emits or accepts them, so iOS MUST send + decode the new names. The
// decoder keeps a tolerant fallback to the old keys purely for any stale local
// cache decoded against ≤v1.16.9. The cap rose 100 → 1000 (large tablet packs,
// 200-puff inhalers). `containerType` (PEN / AMPOULE / BLISTER / INHALER /
// BOTTLE / OTHER) is display-only metadata, default OTHER. `unitsRemaining`
// joined the PATCH body for an absolute remaining-unit correction.
//
// **v1.31.0 (#52, migration 0256):** `manufacturer` + `doseStrength` joined
// `MedicationInventoryItem` and are passed through by the create + update
// routes. iOS previously kept that detail level in local SwiftData only, which
// made a pen registered on the web render without any detail on device.
//
// **v1.33.0 (B2) — the expiry clock is no longer blanket.** "30 days after
// first use" now applies to `PEN` and `AMPOULE` only; `BLISTER` / `INHALER` /
// `BOTTLE` / `OTHER` expire on the printed date alone, and the server
// recomputes `expiresAt` from the container type. iOS holds NO expiry maths —
// see `MedicationContainerType.usesFirstUseExpiryClock`, which only selects the
// copy that states the rule.
//
// The running-low math + state transitions are authoritative server-side. iOS
// posts the user intent (register / correct / mark first-use / mark used-up)
// and re-reads the computed row. State ∈ ACTIVE | IN_USE | EXPIRED | USED_UP.

// MARK: - Container type

/// Display-level container classification, mirrored from the server
/// `MEDICATION_CONTAINER_TYPE_VALUES` enum (v1.16.10).
public enum MedicationContainerType: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case pen = "PEN"
    case ampoule = "AMPOULE"
    case blister = "BLISTER"
    case inhaler = "INHALER"
    case bottle = "BOTTLE"
    case other = "OTHER"

    public var id: String {
        rawValue
    }

    /// SF Symbol glyph for the supply list. Calm monochrome — no signal colour.
    public var glyph: String {
        switch self {
        case .pen: "pencil.tip"
        case .ampoule: "syringe"
        case .blister: "pills"
        case .inhaler: "lungs"
        case .bottle: "waterbottle"
        case .other: "shippingbox"
        }
    }

    /// Localized label for the register-container picker + supply list.
    public var localizedLabel: String {
        switch self {
        case .pen: String(localized: "med.inventory.container.pen")
        case .ampoule: String(localized: "med.inventory.container.ampoule")
        case .blister: String(localized: "med.inventory.container.blister")
        case .inhaler: String(localized: "med.inventory.container.inhaler")
        case .bottle: String(localized: "med.inventory.container.bottle")
        case .other: String(localized: "med.inventory.container.other")
        }
    }

    /// **B2 (server v1.33.0) — which expiry clock the server applies.**
    ///
    /// The "30 days after first use" clock is no longer blanket: since v1.33.0 it
    /// runs for `PEN` and `AMPOULE` **only**. Every other container form expires
    /// purely on its printed date, and the server recomputes `expiresAt` with the
    /// container type. This flag exists so the client can say the TRUE thing per
    /// form — it is a copy selector, never a client-side expiry calculation
    /// (doctrine: the server computes, the client displays).
    public var usesFirstUseExpiryClock: Bool {
        switch self {
        case .pen, .ampoule: true
        case .blister, .inhaler, .bottle, .other: false
        }
    }

    /// Localized one-liner stating which expiry rule this container form obeys.
    /// Pen / ampoule: printed date **or** 30 days after opening, whichever comes
    /// first. All other forms: the printed date alone.
    public var localizedExpiryRule: String {
        usesFirstUseExpiryClock
            ? String(localized: "med.inventory.expiry.rule.firstUseClock")
            : String(localized: "med.inventory.expiry.rule.printedOnly")
    }

    /// Rule copy for a possibly-absent container type. A row without a
    /// `containerType` (≤v1.16.9 payload) is `OTHER` server-side, i.e. the
    /// printed-date-only rule.
    public static func expiryRule(for type: MedicationContainerType?) -> String {
        (type ?? .other).localizedExpiryRule
    }
}

/// Server cap on `unitsTotal` / `unitsRemaining` (v1.16.10 raised 100 → 1000).
public let medicationInventoryUnitsCap = 1000

/// **W-INVENTORY — ONE central sanity gate for every supply readout.**
///
/// The b187 guard clamped a corrupt unit count to `[0, cap]` at decode, but
/// that silently turned garbage into a confident-looking **`0`** ("0 doses") —
/// which the operator brief explicitly forbids ("nicht still auf 0 raten").
/// Worse, a parallel readout (`Glp1InventoryDTO.pensRemaining` /
/// `dosesRemaining` / `weeksOfSupply`, all raw `Int`) had **no** guard at all,
/// so a negative / absurd server value rendered verbatim as "minus X Pens".
///
/// This enum is the single place that decides whether a raw supply quantity is
/// *trustworthy enough to show as a number*. Anything non-finite, negative, or
/// absurdly large is **not** rendered as a number — the caller shows the
/// `placeholder` ("—") instead, so the user sees an honest "unknown" rather
/// than a fabricated 0 or wild garbage. Every supply surface (list summary,
/// per-item row, runway, supply editor pre-fill, GLP-1 pen card, low-supply
/// notification) routes through here.
public enum InventorySanity {
    /// The honest "we don't have a trustworthy number" glyph. Locale-neutral
    /// em-dash — the same token the rest of the app uses for absent metrics.
    public static let placeholder = "—"

    /// Upper bound a *unit* count may plausibly reach before we treat it as
    /// corrupt. The server caps a single container at `medicationInventoryUnitsCap`
    /// (1000); a pooled multi-container sum can legitimately exceed one cap, so
    /// the display ceiling is generous (100× the per-container cap) — high
    /// enough that no real supply trips it, low enough that a sentinel /
    /// overflow value (1e12, 8e21, …) always does.
    public static let unitDisplayCeiling = Double(medicationInventoryUnitsCap) * 100

    /// Validate a raw inventory **unit** count for display.
    ///
    /// - Returns: the value when it is finite, `>= 0`, and `<= unitDisplayCeiling`;
    ///   otherwise `nil` (→ caller renders `placeholder`). A valid value is
    ///   returned unchanged — no silent clamp-to-0, no silent clamp-to-cap that
    ///   could mask a real (large but plausible) restock.
    public static func validUnits(_ raw: Double) -> Double? {
        guard raw.isFinite, raw >= 0, raw <= unitDisplayCeiling else { return nil }
        return raw
    }

    /// Validate a raw inventory **count** (`Int` — pens, doses, weeks) for
    /// display. Negative is corrupt (supply is never below empty); an absurd
    /// magnitude is corrupt. `nil` → caller renders `placeholder`.
    public static func validCount(_ raw: Int) -> Int? {
        guard raw >= 0, raw <= Int(unitDisplayCeiling) else { return nil }
        return raw
    }

    /// Validate a stored supply **date** for display. A date is only shown when
    /// it is inside a plausible window (`2000-01-01 … now + 50 years`) — a
    /// sentinel / epoch / overflow timestamp renders as `placeholder` instead of
    /// a fabricated "Januar 1970" / far-future date. `nil` input stays `nil`
    /// (genuinely absent → caller already hides the field).
    public static func validDate(_ raw: Date?, now: Date = .now) -> Date? {
        guard let raw else { return nil }
        let lower = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01Z
        let upper = now.addingTimeInterval(50 * 365.25 * 24 * 60 * 60)
        guard raw >= lower, raw <= upper else { return nil }
        return raw
    }
}

/// A finite stand-in for a non-finite (`NaN` / `±infinity`) decoded unit count.
/// Deliberately one step above `InventorySanity.unitDisplayCeiling`, so the
/// central display gate rejects it (→ "—") exactly like the corrupt value it
/// replaces, while keeping the stored Double finite so later sums / `Int()`
/// conversions cannot trap.
let inventoryNonFiniteSentinel = InventorySanity.unitDisplayCeiling + 1

/// **W-INVENTORY — boundary normaliser for a decoded inventory unit count.**
///
/// The server is authoritative for supply counts. This does the MINIMUM needed
/// to keep the in-memory model safe to compute on, and deliberately does **not**
/// mask a corrupt-but-finite value:
///   - `NaN` / `±infinity` → `inventoryNonFiniteSentinel` (a finite value the
///     display gate rejects → "—"), because a non-finite Double poisons every
///     sum / comparison and traps `Int()`.
///   - a finite value (incl. negative or absurd magnitude) → returned VERBATIM,
///     so the ONE central gate (`InventorySanity`) sees the real value and
///     renders "—" instead of b187's confident, wrong "0".
///
/// A normalisation is logged once as a `.warning` (no PII — field name `.public`,
/// magnitude `.private`) so a bad server/cache value stays observable.
func sanitizeInventoryUnits(_ raw: Double, field: StaticString) -> Double {
    guard raw.isFinite else {
        // `field` is an operator-grade compile-time field name (no PII).
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.storage.warning(
            "Inventory unit count non-finite, replacing with reject-sentinel (field=\(field, privacy: .public))"
        )
        return inventoryNonFiniteSentinel
    }
    if raw < 0 || raw > InventorySanity.unitDisplayCeiling {
        // `field` is an operator-grade field name; the magnitude is `.private`.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.storage.warning(
            "Inventory unit count out of plausible range (field=\(field, privacy: .public), value=\(raw, privacy: .private))"
        )
    }
    return raw
}

// MARK: - Read row (server-authoritative)

/// One inventory item as the server stores + returns it. Field names mirror the
/// serialized `medicationInventoryItem` model verbatim (`unitsTotal` /
/// `unitsRemaining` as of v1.16.10).
public struct MedicationInventoryItemDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let userId: String
    public let medicationId: String
    /// ACTIVE | IN_USE | EXPIRED | USED_UP (state-machine.ts).
    public let state: String
    /// Units the container shipped with (1–1000, fractional allowed for
    /// split-pill packs since v1.16.12).
    ///
    /// **#31 (v1.18.3) — nullable on the wire.** The server now serialises an
    /// UNKNOWN supply count as an explicit JSON `null` (not `0`): `null` = "we
    /// don't know how many units this container holds" → render "—", never
    /// decrement, never synthesise `0`. A genuine `0` (an empty tracked
    /// container) is still `0`. So this is `Double?`: `nil` flows straight to
    /// the `InventorySanity` placeholder path that already renders "—" for
    /// corrupt counts — the ONE honest-unknown surface.
    public let unitsTotal: Double?
    /// Units still remaining (server-decremented per taken dose). Nullable for
    /// the same UNKNOWN reason as ``unitsTotal`` (#31, v1.18.3).
    public let unitsRemaining: Double?
    /// Container kind (v1.16.10). `nil` against ≤v1.16.9 payloads.
    public let containerType: MedicationContainerType?
    /// **#52 (v1.31.0, migration 0256)** — manufacturer / brand of this
    /// container, server-stored since v1.31.0 and echoed by the create + update
    /// routes. `nil` against older payloads and for any row the user registered
    /// without pen detail; iOS used to hold this level of detail purely in local
    /// SwiftData, which is exactly what made web-entered pens invisible on device.
    public let manufacturer: String?
    /// **#52 (v1.31.0)** — free-text strength label ("1,0 mg / Dosis"), same
    /// provenance + nullability as ``manufacturer``.
    public let doseStrength: String?
    public let firstUseAt: Date?
    public let printedExpiry: Date?
    public let expiresAt: Date?
    public let purchasedAt: Date?
    public let notes: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: String,
        userId: String,
        medicationId: String,
        state: String,
        unitsTotal: Double?,
        unitsRemaining: Double?,
        containerType: MedicationContainerType? = nil,
        manufacturer: String? = nil,
        doseStrength: String? = nil,
        firstUseAt: Date? = nil,
        printedExpiry: Date? = nil,
        expiresAt: Date? = nil,
        purchasedAt: Date? = nil,
        notes: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.medicationId = medicationId
        self.state = state
        self.unitsTotal = unitsTotal
        self.unitsRemaining = unitsRemaining
        self.containerType = containerType
        self.manufacturer = manufacturer
        self.doseStrength = doseStrength
        self.firstUseAt = firstUseAt
        self.printedExpiry = printedExpiry
        self.expiresAt = expiresAt
        self.purchasedAt = purchasedAt
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// **Tolerant decode (C1).** The generic supply section renders for every
    /// medication type, so a field drop/rename must degrade gracefully instead
    /// of failing the whole list decode. Only `id` + a unit count are hard
    /// requirements: `unitsTotal` reads the v1.16.10 key first, then falls back
    /// to the legacy `dosesTotal` (stale local cache). `state` defaults to
    /// `ACTIVE`, `unitsRemaining` to `unitsTotal`, identity strings to empty,
    /// `containerType` to nil (an unknown future literal also decodes to nil).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decodeIfPresent(String.self, forKey: .userId) ?? ""
        medicationId = try c.decodeIfPresent(String.self, forKey: .medicationId) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "ACTIVE"

        // **#31 (v1.18.3) — explicit `null` = UNKNOWN, never a thrown decode.**
        // The server now emits `unitsTotal` / `unitsRemaining` as `number | null`;
        // `null` means the supply count is genuinely unknown. An explicit `null`
        // must decode to `nil` (→ "—"), NOT throw and NOT fall through to a
        // legacy key or synthesise `0`. The decode therefore distinguishes three
        // cases per field:
        //   - key present + JSON `null`  → nil   (UNKNOWN, render "—")
        //   - key present + a number     → sanitised value
        //   - key absent (stale ≤v1.16.9 cache) → legacy `dosesTotal/Remaining`
        //     fallback, else (remaining only) mirror `unitsTotal`.
        //
        // **W-INVENTORY.** A decoded NUMBER still routes through
        // `sanitizeInventoryUnits`: a NaN/±infinity is normalised to a finite
        // reject-sentinel (a non-finite Double poisons every later sum / `Int()`
        // conversion), while a finite-but-corrupt value is preserved verbatim so
        // the ONE central display gate (`InventorySanity`) renders "—" instead of
        // b187's confident, wrong "0".
        unitsTotal = try Self.decodeNullableUnits(
            from: c, primary: .unitsTotal, legacy: .dosesTotal, field: "unitsTotal"
        )

        if c.contains(.unitsRemaining) {
            unitsRemaining = try c.decodeNil(forKey: .unitsRemaining)
                ? nil
                : sanitizeInventoryUnits(c.decode(Double.self, forKey: .unitsRemaining), field: "unitsRemaining")
        } else if let legacy = try c.decodeIfPresent(Double.self, forKey: .dosesRemaining) {
            unitsRemaining = sanitizeInventoryUnits(legacy, field: "unitsRemaining")
        } else {
            // No remaining key at all (stale cache): mirror total, preserving its
            // unknown-ness (a `nil` total → `nil` remaining, not a fake number).
            unitsRemaining = unitsTotal
        }

        containerType = try c.decodeIfPresent(MedicationContainerType.self, forKey: .containerType)
        // #52 — nullable on the wire; an absent key (pre-v1.31.0 server / stale
        // cache) and an explicit `null` both mean "no pen detail on this row".
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        doseStrength = try c.decodeIfPresent(String.self, forKey: .doseStrength)
        firstUseAt = try c.decodeIfPresent(Date.self, forKey: .firstUseAt)
        printedExpiry = try c.decodeIfPresent(Date.self, forKey: .printedExpiry)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        purchasedAt = try c.decodeIfPresent(Date.self, forKey: .purchasedAt)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// Decode one nullable-units field (#31): JSON `null` → `nil` (UNKNOWN),
    /// a number → sanitised value, an absent key → legacy fallback (else `nil`).
    private static func decodeNullableUnits(
        from c: KeyedDecodingContainer<CodingKeys>,
        primary: CodingKeys,
        legacy: CodingKeys,
        field: StaticString
    ) throws -> Double? {
        if c.contains(primary) {
            if try c.decodeNil(forKey: primary) { return nil }
            return try sanitizeInventoryUnits(c.decode(Double.self, forKey: primary), field: field)
        }
        if let value = try c.decodeIfPresent(Double.self, forKey: legacy) {
            return sanitizeInventoryUnits(value, field: field)
        }
        return nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(medicationId, forKey: .medicationId)
        try c.encode(state, forKey: .state)
        // #31 — an UNKNOWN count round-trips as an explicit JSON `null` (the
        // server's own sentinel), never as a fabricated `0`.
        try c.encode(unitsTotal, forKey: .unitsTotal)
        try c.encode(unitsRemaining, forKey: .unitsRemaining)
        try c.encodeIfPresent(containerType, forKey: .containerType)
        try c.encodeIfPresent(manufacturer, forKey: .manufacturer)
        try c.encodeIfPresent(doseStrength, forKey: .doseStrength)
        try c.encodeIfPresent(firstUseAt, forKey: .firstUseAt)
        try c.encodeIfPresent(printedExpiry, forKey: .printedExpiry)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(purchasedAt, forKey: .purchasedAt)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, userId, medicationId, state
        case unitsTotal, unitsRemaining, containerType
        /// #52 (v1.31.0) — pen detail, server-stored since migration 0256.
        case manufacturer, doseStrength
        // Legacy ≤v1.16.9 fallbacks (decode-only).
        case dosesTotal, dosesRemaining
        case firstUseAt, printedExpiry, expiresAt, purchasedAt, notes
        case createdAt, updatedAt
    }
}

/// GET list envelope: `{ items, meta: { total } }` inside `data`.
public struct MedicationInventoryListDTO: Codable, Sendable, Hashable {
    public let items: [MedicationInventoryItemDTO]
    public let meta: Meta

    public struct Meta: Codable, Sendable, Hashable {
        public let total: Int
        public init(total: Int) {
            self.total = total
        }
    }

    public init(items: [MedicationInventoryItemDTO], meta: Meta) {
        self.items = items
        self.meta = meta
    }
}

// MARK: - Write bodies

/// POST body. Mirrors `createInventoryItemSchema`: `unitsTotal` (1–1000),
/// optional `containerType`, `manufacturer` / `doseStrength` (#52, v1.31.0),
/// `printedExpiry`, `purchasedAt`, `notes` (≤200).
public struct MedicationInventoryCreate: Codable, Sendable, Hashable {
    public let unitsTotal: Double
    public let containerType: MedicationContainerType?
    /// #52 — pen detail the create route persists since v1.31.0. Sending it is
    /// what makes a pen registered on iOS visible on the web (and vice versa);
    /// before that the detail lived only in on-device SwiftData.
    public let manufacturer: String?
    /// #52 — see ``manufacturer``.
    public let doseStrength: String?
    public let printedExpiry: Date?
    public let purchasedAt: Date?
    public let notes: String?

    public init(
        unitsTotal: Double,
        containerType: MedicationContainerType? = nil,
        manufacturer: String? = nil,
        doseStrength: String? = nil,
        printedExpiry: Date? = nil,
        purchasedAt: Date? = nil,
        notes: String? = nil
    ) {
        self.unitsTotal = unitsTotal
        self.containerType = containerType
        self.manufacturer = manufacturer
        self.doseStrength = doseStrength
        self.printedExpiry = printedExpiry
        self.purchasedAt = purchasedAt
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case unitsTotal, containerType, manufacturer, doseStrength
        case printedExpiry, purchasedAt, notes
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(unitsTotal, forKey: .unitsTotal)
        try c.encodeIfPresent(containerType, forKey: .containerType)
        try c.encodeIfPresent(manufacturer, forKey: .manufacturer)
        try c.encodeIfPresent(doseStrength, forKey: .doseStrength)
        try c.encodeIfPresent(printedExpiry, forKey: .printedExpiry)
        try c.encodeIfPresent(purchasedAt, forKey: .purchasedAt)
        try c.encodeIfPresent(notes, forKey: .notes)
    }
}

/// PATCH body. Mirrors `updateInventoryItemSchema`. All fields optional + the
/// server applies them commutatively. Encodes only the populated keys so an
/// omitted field is never sent as `null` (which `notes` would treat as "clear").
/// `unitsRemaining` (v1.16.10) is the absolute remaining-unit correction —
/// server-clamped to the item's `unitsTotal`, re-runs the state machine.
///
/// **Two columns are clearable, and for those an omitted key and an explicit
/// `null` mean DIFFERENT things** — the same trap as the concurrency token:
///   - `printedExpiry` (M-1): `.nullable().optional()` since v1.16.12.
///   - `markAsFirstUseAt`: accepts `null` to DELETE the first-use date since the
///     A7 shape change. Before that only a date was allowed, so iOS had no way
///     to undo a mis-tapped "als geöffnet markieren".
/// Both therefore use the project's existing tri-state primitive
/// ``RecordPatchField`` (`unchanged` = omit the key / `clear` = explicit JSON
/// `null` / `set` = the value) instead of an ad-hoc clear-flag. The hand-rolled
/// `Codable` round-trips all three states so an outbox replay re-issues the
/// intent verbatim.
public struct MedicationInventoryPatch: Codable, Sendable, Hashable {
    /// Tri-state: leave the first-use date alone, clear it (JSON `null`), or set it.
    public let markAsFirstUseAt: RecordPatchField<Date>
    public let markAsUsedUp: Bool?
    /// Tri-state: leave the printed expiry alone, clear it (JSON `null`), or set it.
    public let printedExpiry: RecordPatchField<Date>
    public let unitsRemaining: Double?
    public let notes: String?

    public init(
        markAsFirstUseAt: RecordPatchField<Date> = .unchanged,
        markAsUsedUp: Bool? = nil,
        printedExpiry: RecordPatchField<Date> = .unchanged,
        unitsRemaining: Double? = nil,
        notes: String? = nil
    ) {
        self.markAsFirstUseAt = markAsFirstUseAt
        self.markAsUsedUp = markAsUsedUp
        self.printedExpiry = printedExpiry
        self.unitsRemaining = unitsRemaining
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case markAsFirstUseAt, markAsUsedUp, printedExpiry, unitsRemaining, notes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markAsFirstUseAt = try RecordPatchField.decode(from: c, forKey: .markAsFirstUseAt)
        markAsUsedUp = try c.decodeIfPresent(Bool.self, forKey: .markAsUsedUp)
        printedExpiry = try RecordPatchField.decode(from: c, forKey: .printedExpiry)
        unitsRemaining = try c.decodeIfPresent(Double.self, forKey: .unitsRemaining)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try markAsFirstUseAt.encode(into: &c, forKey: .markAsFirstUseAt)
        try c.encodeIfPresent(markAsUsedUp, forKey: .markAsUsedUp)
        try printedExpiry.encode(into: &c, forKey: .printedExpiry)
        try c.encodeIfPresent(unitsRemaining, forKey: .unitsRemaining)
        try c.encodeIfPresent(notes, forKey: .notes)
    }
}
