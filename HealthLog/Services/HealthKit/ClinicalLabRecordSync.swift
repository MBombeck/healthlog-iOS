import CryptoKit
import Foundation

// Lab results from Apple Health Records into Labs (#180, contract #182
// part A §3: `POST /api/labs/fhir-batch`, server 1.48.0).
//
// Everything here is plain values over `UserDefaults` and `Data`, so the gate,
// the batching, the wire body and the handling of each answer are testable
// without HealthKit. The HealthKit half is `ClinicalLabRecordReader`.

/// One lab result as Health Records hands it over: the FHIR resource bytes
/// (`HKFHIRResource.data`, DSTU2 or R4) and where it came from.
struct ClinicalLabRecord: Sendable, Equatable {
    /// The `HKClinicalRecord` UUID; only used to find a record again for a
    /// resend, never sent.
    let sampleID: UUID
    let resource: Data
    let fhirVersion: String?
    let identifier: String?
    let sourceURL: String?
    let sourceName: String?
}

/// Whether the Labs screen offers Health Records and whether the sync reads
/// them.
enum ClinicalLabRecordsGate {
    /// The release that shipped `POST /api/labs/fhir-batch`.
    static let minimumServerVersion = "1.48.0"

    /// Offered on a device that reads Apple Health, whose HealthKit has Health
    /// Records (in most countries it has not), against a server known to take
    /// them. An unknown server version counts as older.
    static func isAvailable(
        readsHealthKit: Bool,
        supportsHealthRecords: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        readsHealthKit && supportsHealthRecords
            && KnownServerVersion.isAtLeast(minimumServerVersion, defaults: defaults)
    }
}

/// The person's one answer to the Health Records offer. Kept on the device,
/// like the HealthKit permission it leads to, but it belongs to the account
/// that gave it: sign-out removes it, so the next account on this device is
/// asked again before anything of the device's Health Records is sent.
enum ClinicalLabRecordsConsent: String, Sendable, Equatable {
    /// Never asked. The Labs screen shows the offer; nothing is read.
    case notAsked
    /// The HealthKit sheet was shown. What the person chose there HealthKit
    /// does not tell; a refused read simply returns nothing.
    case requested
    /// Declined in the app. Never offered again, nothing is read.
    case declined

    static let defaultsKey = "hl.labs.healthRecords.consent.v1"

    static func current(defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .notAsked
    }

    static func record(_ consent: Self, defaults: UserDefaults = .standard) {
        defaults.set(consent.rawValue, forKey: defaultsKey)
    }

    /// Sign-out: the answer goes with the account that gave it. A device
    /// updated from 1.6 keeps the answer of whoever is signed in until that
    /// account signs out.
    static func clearOnLogout(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Whether the offer stands in Labs: available and never answered.
    static func offersCard(isAvailable: Bool, defaults: UserDefaults = .standard) -> Bool {
        isAvailable && current(defaults: defaults) == .notAsked
    }

    /// Whether a sync pass reads Health Records.
    static func syncs(isAvailable: Bool, defaults: UserDefaults = .standard) -> Bool {
        isAvailable && current(defaults: defaults) == .requested
    }
}

// MARK: - Batching and the wire body

enum ClinicalLabRecordBatching {
    /// The route's limit per call.
    static let maxRecordsPerCall = 200
    /// The server skips a larger resource as `too_large`; the app does not
    /// send it at all.
    static let maxResourceBytes = 256 * 1024
    /// The server reads at most 1 MiB per call (the proxy's ceiling,
    /// `labs/fhir-batch/route.ts` `MAX_BODY_BYTES`, release/v1.49.0). The
    /// budget is the whole encoded body, envelope and source fields
    /// included, with room to spare.
    static let maxBodyBytes = 1024 * 1024 - 64 * 1024

    /// `{"records":[]}` around the entries, and the comma between two.
    private static let envelopeBytes = 14

    /// The records in calls of 1 to 200, each encoded body within
    /// ``maxBodyBytes``. Oversized and unreadable resources are left out and
    /// returned apart.
    static func batches(_ records: [ClinicalLabRecord]) -> (batches: [[ClinicalLabRecord]], leftOut: [ClinicalLabRecord]) {
        var batches: [[ClinicalLabRecord]] = []
        var current: [ClinicalLabRecord] = []
        var currentBytes = envelopeBytes
        var leftOut: [ClinicalLabRecord] = []
        for record in records {
            guard record.resource.count <= maxResourceBytes, resourceObject(record.resource) != nil,
                  let entry = entryBytes(record), envelopeBytes + entry <= maxBodyBytes else
            {
                leftOut.append(record)
                continue
            }
            let separator = current.isEmpty ? 0 : 1
            if !current.isEmpty, current.count == maxRecordsPerCall || currentBytes + separator + entry > maxBodyBytes {
                batches.append(current)
                current = []
                currentBytes = envelopeBytes
            }
            currentBytes += (current.isEmpty ? 0 : 1) + entry
            current.append(record)
        }
        if !current.isEmpty { batches.append(current) }
        return (batches, leftOut)
    }

    /// The bytes one record adds to the body, as it is encoded (escaping
    /// makes that more than the resource's own size).
    private static func entryBytes(_ record: ClinicalLabRecord) -> Int? {
        (try? body(for: [record])).map { $0.count - envelopeBytes }
    }

    /// `{ records: [{ resource, fhirVersion?, identifier?, sourceURL?, sourceName? }] }`.
    /// The request is strict, so an optional field over its limit is left
    /// out rather than sent (the identity then falls back to the resource id
    /// or the content key); the source name is cut to its limit.
    static func body(for batch: [ClinicalLabRecord]) throws -> Data {
        let records: [[String: Any]] = batch.compactMap { record in
            guard let resource = resourceObject(record.resource) else { return nil }
            var entry: [String: Any] = ["resource": resource]
            if let value = bounded(record.fhirVersion, 16) { entry["fhirVersion"] = value }
            if let value = bounded(record.identifier, 256) { entry["identifier"] = value }
            if let value = bounded(record.sourceURL, 2048) { entry["sourceURL"] = value }
            if let name = record.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                entry["sourceName"] = String(name.prefix(200))
            }
            return entry
        }
        return try JSONSerialization.data(withJSONObject: ["records": records])
    }

    static func resourceObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func bounded(_ value: String?, _ limit: Int) -> String? {
        guard let value, !value.isEmpty, value.count <= limit else { return nil }
        return value
    }
}

// MARK: - The answer

/// `POST /api/labs/fhir-batch` response.
struct ClinicalLabBatchResponse: Decodable, Sendable, Equatable {
    struct Result: Decodable, Sendable, Equatable {
        let index: Int
        let status: String
        let reason: String?
    }

    let results: [Result]
    let inserted: Int?
    let duplicate: Int?
    let skipped: Int?
    let failed: Int?
}

/// What one call settled and what goes out again.
struct ClinicalLabBatchOutcome: Sendable, Equatable {
    var inserted = 0
    var duplicate = 0
    var skipped = 0
    /// Failed for good (`missing_unit`, `unit_mismatch`, `text_too_long`, or
    /// a reason this build does not know): the same record would fail again.
    var failed = 0
    /// `write_failed`, or no answer for the record at all: sent again.
    var resend: [UUID] = []

    /// Reads one response against the batch it answers. Only `write_failed`
    /// is transient (contract §3); `duplicate` is done, like `inserted`.
    static func classify(_ response: ClinicalLabBatchResponse, batch: [ClinicalLabRecord]) -> Self {
        var outcome = Self()
        var answered = Set<Int>()
        for result in response.results where batch.indices.contains(result.index) {
            answered.insert(result.index)
            switch result.status {
            case "inserted": outcome.inserted += 1
            case "duplicate": outcome.duplicate += 1
            case "skipped": outcome.skipped += 1
            case "failed" where result.reason == "write_failed": outcome.resend.append(batch[result.index].sampleID)
            default: outcome.failed += 1
            }
        }
        for index in batch.indices where !answered.contains(index) {
            outcome.resend.append(batch[index].sampleID)
        }
        return outcome
    }

    mutating func add(_ other: Self) {
        inserted += other.inserted
        duplicate += other.duplicate
        skipped += other.skipped
        failed += other.failed
        resend += other.resend
    }
}

/// How a failed call is handled.
enum ClinicalLabCallFailure: Equatable {
    /// The server read the body and refused it (400, 413, 422
    /// `labs.fhir_batch.invalid`). One bad record or a body over the limit
    /// refuses the whole call, so a call of several records is halved and
    /// each half sent on its own; only a single record refused this way
    /// counts as failed for good.
    case refused
    /// No server answer, a rate limit, a server error, a missing route or an
    /// account problem: nothing moves, the next pass tries again.
    case hold

    static func of(_ error: Error) -> Self {
        guard let error = error as? HLError, case let .server(status, _, _) = error else { return .hold }
        return [400, 413, 422].contains(status) ? .refused : .hold
    }
}

// MARK: - Cursor

/// Where the sync stands for one account: the HealthKit anchor (archived
/// `HKQueryAnchor`), the records owed a resend, and the last pass in numbers
/// for the sync diagnostics.
struct ClinicalLabRecordCursor: Codable, Sendable, Equatable {
    var anchor: Data?
    var resend: [UUID] = []
    var lastPass: Date?
    var lastSent = 0
    var lastInserted = 0
    var lastDuplicate = 0
    var totalInserted = 0

    /// A resend list that only grows would be read on every pass forever.
    /// A page that would push it past this bound is not taken: the anchor
    /// holds and the page is read again, so nothing is cut off.
    static let maxResend = 1000
}

/// Keeps one cursor per account in `UserDefaults` (anchors live there, see
/// PROJECT_GUIDE.md). The account id is hashed into the key.
struct ClinicalLabRecordCursorStore: Sendable {
    static let keyPrefix = "hl.labs.healthRecords.cursor.v1."

    /// `UserDefaults` is documented thread-safe; this type only reads and
    /// writes whole values (the `HealthSyncCursorStorage` precedent).
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(owner: String) -> String {
        let digest = SHA256.hash(data: Data(owner.utf8))
        return keyPrefix + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func load(owner: String) -> ClinicalLabRecordCursor {
        guard let data = defaults.data(forKey: Self.key(owner: owner)),
              let cursor = try? JSONDecoder().decode(ClinicalLabRecordCursor.self, from: data) else { return ClinicalLabRecordCursor() }
        return cursor
    }

    /// Sign-out: the leaving account's position in the device's records.
    func clear(owner: String) {
        defaults.removeObject(forKey: Self.key(owner: owner))
    }

    func save(_ cursor: ClinicalLabRecordCursor, owner: String) {
        var bounded = cursor
        bounded.resend = Array(cursor.resend.suffix(ClinicalLabRecordCursor.maxResend))
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        defaults.set(data, forKey: Self.key(owner: owner))
    }
}

// MARK: - Sync diagnostics

/// The Health Records lab row of the sync diagnostics.
enum ClinicalLabRecordsStatus: Equatable, Sendable {
    /// Read and sent.
    case active
    /// Possible here, not chosen (or declined).
    case notConnected
    /// The server does not take them yet.
    case waitingForServer
    /// This device or its HealthKit has no Health Records.
    case notOnThisSystem

    static func current(
        readsHealthKit: Bool,
        supportsHealthRecords: Bool,
        defaults: UserDefaults = .standard
    ) -> Self {
        guard readsHealthKit, supportsHealthRecords else { return .notOnThisSystem }
        guard KnownServerVersion.isAtLeast(ClinicalLabRecordsGate.minimumServerVersion, defaults: defaults) else {
            return .waitingForServer
        }
        return ClinicalLabRecordsConsent.current(defaults: defaults) == .requested ? .active : .notConnected
    }
}
