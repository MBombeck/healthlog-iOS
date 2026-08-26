import Foundation

// Result envelopes for the data-import routes (server v1.17.1 —
// `src/app/api/import/csv/route.ts` + `src/app/api/import/route.ts`). Both are
// tolerant `Decodable`s so an added server field never breaks the decode.

// MARK: - CSV import (dry-run capable)

/// One row's projected / actual outcome in a CSV import.
/// (`{ line, status, reason? }`). `status` is left as the raw server string so
/// an added status variant never drops the row from the summary.
public struct CSVImportRow: Decodable, Sendable, Identifiable, Equatable {
    public let line: Int
    /// `inserted` / `updated` / `skipped` / `duplicate` (server-defined). Raw
    /// string — an unknown future variant still decodes + renders.
    public let status: String
    /// Human-readable skip/duplicate reason when the server supplies one.
    public let reason: String?

    public var id: Int {
        line
    }

    public init(line: Int, status: String, reason: String? = nil) {
        self.line = line
        self.status = status
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case line, status, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        line = try c.decodeIfPresent(Int.self, forKey: .line) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "skipped"
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// `POST /api/import/csv[?dryRun=1]` → `{ inserted, updated, skipped, total,
/// dryRun, rows[] }`. In dry-run mode nothing is written and the counts are the
/// *projected* outcome — the trust-win preview before a bulk cold-start import.
public struct CSVImportResult: Decodable, Sendable, Equatable {
    public let inserted: Int
    public let updated: Int
    public let skipped: Int
    public let total: Int
    public let dryRun: Bool
    public let rows: [CSVImportRow]

    public init(inserted: Int, updated: Int, skipped: Int, total: Int, dryRun: Bool, rows: [CSVImportRow]) {
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.total = total
        self.dryRun = dryRun
        self.rows = rows
    }

    private enum CodingKeys: String, CodingKey {
        case inserted, updated, skipped, total, dryRun, rows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inserted = try c.decodeIfPresent(Int.self, forKey: .inserted) ?? 0
        updated = try c.decodeIfPresent(Int.self, forKey: .updated) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        rows = try c.decodeIfPresent([CSVImportRow].self, forKey: .rows) ?? []
    }

    /// The count of rows that would actually land (insert + update) — the
    /// headline the preview shows before the user commits.
    public var writeCount: Int {
        inserted + updated
    }
}

// MARK: - JSON import (export round-trip)

/// `POST /api/import` → `{ measurements, moodEntries, skipped }` — the row
/// counts written when restoring a JSON export back into the account. There is
/// no dry-run on the JSON route (the CSV route is the preview surface).
public struct JSONImportResult: Decodable, Sendable, Equatable {
    public let measurements: Int
    public let moodEntries: Int
    public let skipped: Int

    public init(measurements: Int, moodEntries: Int, skipped: Int) {
        self.measurements = measurements
        self.moodEntries = moodEntries
        self.skipped = skipped
    }

    private enum CodingKeys: String, CodingKey {
        case measurements, moodEntries, skipped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        measurements = try c.decodeIfPresent(Int.self, forKey: .measurements) ?? 0
        moodEntries = try c.decodeIfPresent(Int.self, forKey: .moodEntries) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
    }
}
