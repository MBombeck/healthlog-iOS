import Foundation

// SP3 (v0.12) — wire DTOs for the server-backed GLP-1 side-effect logbook.
//
// Server contract (READ verbatim):
//   - `src/app/api/medications/[id]/side-effects/route.ts`
//       GET  → apiSuccess({ items: MedicationSideEffect[], meta: { total } })
//       POST → apiSuccess(MedicationSideEffect, 201)   body: { entry, severity, occurredAt?, notes? }
//   - `src/app/api/medications/[id]/side-effects/[logId]/route.ts`
//       DELETE → apiSuccess({ id, deleted: true })
//   - `src/lib/medications/side-effects/validators.ts` (createSideEffectSchema)
//   - `src/lib/medications/side-effects/taxonomy.ts` (entry → category, 21 entries)
//
// The server derives `category` from `entry` server-side and the wire schema no
// longer accepts a client `category` (validators.ts code-M6). The POST body
// therefore carries only `entry`/`severity`/`occurredAt?`/`notes?`. The stored
// row that comes back DOES carry `category` (denormalised) so we decode it.

// MARK: - Read row (server-authoritative)

/// One side-effect log row as the server stores + returns it (POST 201 body and
/// each element of the GET `items[]`). Field names mirror the Prisma
/// `medicationSideEffect` model verbatim.
public struct MedicationSideEffectDTO: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let userId: String
    public let medicationId: String
    /// Denormalised category, derived server-side from `entry` (taxonomy.ts).
    public let category: String
    /// Canonical entry key (e.g. `"NAUSEA"`). One of the 21 taxonomy entries.
    public let entry: String
    /// 1–5 Likert severity.
    public let severity: Int
    public let occurredAt: Date
    public let notes: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: String,
        userId: String,
        medicationId: String,
        category: String,
        entry: String,
        severity: Int,
        occurredAt: Date,
        notes: String?,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.medicationId = medicationId
        self.category = category
        self.entry = entry
        self.severity = severity
        self.occurredAt = occurredAt
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// GET list envelope: server returns `{ items, meta: { total } }` inside the
/// `data` field of the standard API envelope.
public struct MedicationSideEffectListDTO: Codable, Sendable, Hashable {
    public let items: [MedicationSideEffectDTO]
    public let meta: Meta

    public struct Meta: Codable, Sendable, Hashable {
        public let total: Int
        public init(total: Int) {
            self.total = total
        }
    }

    public init(items: [MedicationSideEffectDTO], meta: Meta) {
        self.items = items
        self.meta = meta
    }
}

// MARK: - Write body

/// POST body. Mirrors `createSideEffectSchema` exactly: `entry`, `severity`,
/// optional `occurredAt`, optional `notes`. `category` is intentionally NOT
/// sent — the server derives it (older clients that send it are ignored).
public struct MedicationSideEffectCreate: Codable, Sendable, Hashable {
    public let entry: String
    public let severity: Int
    public let occurredAt: Date?
    public let notes: String?

    public init(entry: String, severity: Int, occurredAt: Date?, notes: String?) {
        self.entry = entry
        self.severity = severity
        self.occurredAt = occurredAt
        self.notes = notes
    }
}

/// DELETE response: `{ id, deleted: true }`.
public struct MedicationMutationAck: Codable, Sendable, Hashable {
    public let id: String
    public let deleted: Bool

    public init(id: String, deleted: Bool) {
        self.id = id
        self.deleted = deleted
    }
}
