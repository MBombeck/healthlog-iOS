import Foundation

// #113 / 0.3 — a refusal the person cannot see is data loss.
//
// `POST /api/measurements/batch` answers a row it will not store with
// `status: "skipped"` inside an HTTP 200. For `value_out_of_range` (and the other
// deterministic reasons on the acceptance allowlist) the page is complete and the
// HealthKit cursor may move — retrying the same bytes against the same server
// cannot change the verdict. Up to 1.0.3 that was the end of the reading: the
// anchor walked past it, the diagnostics counted it as uploaded, and nothing on
// the phone remembered it. That is how every SpO2 and body-fat reading was lost
// for a month without a single visible symptom.
//
// This register is where such a row goes instead. The cursor still moves — an
// unchanged row posted again is refused again — but the row is kept, owner-bound,
// with its reason, until either the server stores it or the person has seen it:
//
//   * it is offered again once per app build (a new build can carry a mapping
//     fix, and a server update usually arrives in the meantime), and on demand
//     from Sync Diagnostics;
//   * `inserted`, `updated` or `duplicate` on a later offer removes it;
//   * a sign-out or account deletion removes every row, like every other
//     account-bound local store.
//
// INT-A (1.0.4) — this is the ONE register for every refusal a HealthKit sync
// path would otherwise lose: `value_out_of_range` rows (A2), named whole-batch
// refusals and unexplained 4xx runs of the heart-event importer, refused or
// never-confirmed pages of the outbox replay, and nutrient day-totals. It
// lives in the platform-free core so the replay can write to it; every path
// resolves it through `HealthKitSkippedRowRegister.current`.
//
// API surface for other importers (kept deliberately small):
//
//   record(_:ownerID:build:at:)       — durable, read-back verified; throws
//   rows(ownerID:)                    — newest first, for the list screen
//   countsByIdentifier(ownerID:)      — for the per-type warning
//   rowsDue(ownerID:build:)           — not yet offered by this build
//   applyReoffer(_:ownerID:build:at:) — fold one re-offer's verdicts back in
//   clearAll()                        — logout / account deletion
//
// Storage is one JSON file under Application Support, excluded from backup and
// protected until first unlock — the same tier as the outbox (ADR-011/012). It
// holds health values, so it never goes to `UserDefaults`.

/// One refused row as it came back from the server: the exact row that was
/// posted and the reason the server gave.
///
/// #115 / 0.3 (INT-A) — ONE register for every reading a HealthKit sync moved
/// past without the server storing it. A row is either a measurement-batch
/// entry (`/api/measurements/batch`: out-of-range values, named whole-batch
/// refusals, replayed pages the server never confirmed, a heart-event page
/// held too long), a nutrient day-total (`/api/nutrients/batch`) or (E1) an
/// Apple Health State of Mind sample the mood route never confirmed. Exactly
/// one of ``entry``, ``nutrient`` and ``mood`` is set.
struct HealthKitSkippedEntry: Sendable, Equatable {
    let entry: HealthKitBatchEntryDTO?
    let nutrient: NutrientIntakeEntryDTO?
    let mood: StateOfMindSkippedSample?
    let reason: String

    init(entry: HealthKitBatchEntryDTO, reason: String) {
        self.entry = entry
        nutrient = nil
        mood = nil
        self.reason = reason
    }

    init(nutrient: NutrientIntakeEntryDTO, reason: String) {
        entry = nil
        self.nutrient = nutrient
        mood = nil
        self.reason = reason
    }

    init(mood: StateOfMindSkippedSample, reason: String) {
        entry = nil
        nutrient = nil
        self.mood = mood
        self.reason = reason
    }

    var id: String {
        HealthKitSkippedRow.identity(entry: entry, nutrient: nutrient, mood: mood)
    }
}

/// E1 — a State of Mind sample as the register keeps it: its HealthKit UUID,
/// when it was felt, and the 1–5 score the importer posts. Never re-offered
/// (it belongs to `POST /api/mood-entries`, not the measurement batch); shown so
/// the person knows which mood the server never confirmed.
struct StateOfMindSkippedSample: Codable, Sendable, Equatable {
    let externalId: String
    let recordedAt: Date
    let score: Int
}

/// One remembered refusal.
struct HealthKitSkippedRow: Codable, Sendable, Equatable, Identifiable {
    let ownerID: String
    /// A measurement row: the posted entry, byte-for-byte what a re-offer sends
    /// again. `nil` for a nutrient row.
    let entry: HealthKitBatchEntryDTO?
    /// A nutrient day-total as posted to `/api/nutrients/batch`. `nil` for a
    /// measurement row. (Absent from files written before INT-A, which then
    /// decode as measurement rows, exactly what they were.)
    var nutrient: NutrientIntakeEntryDTO?
    /// E1 — a State of Mind sample; absent from every earlier file.
    var mood: StateOfMindSkippedSample?
    /// The server's latest reason for refusing it.
    var reason: String
    let firstSkippedAt: Date
    var lastAttemptAt: Date
    var attempts: Int
    /// `CFBundleVersion` of the build that last offered the row.
    var lastOfferedBuild: String

    var id: String {
        Self.identity(entry: entry, nutrient: nutrient, mood: mood)
    }

    /// The HealthKit identifier of a measurement row; `nutrient:<code>` for a
    /// nutrient row (no diagnostics kind maps to it, so it never lights a
    /// per-type warning it does not belong to).
    var hkIdentifier: String {
        if let entry { return entry.hkIdentifier }
        if mood != nil { return Self.stateOfMindIdentifier }
        return "nutrient:" + (nutrient?.nutrient.rawValue ?? "unknown")
    }

    /// When the reading was taken. A nutrient row is a day total: its server
    /// day key at noon UTC, which names the same calendar day everywhere the
    /// list is read.
    var measuredAt: Date {
        if let entry { return entry.startDate }
        if let mood { return mood.recordedAt }
        return nutrient.flatMap { Self.dayNoonUTC($0.day) } ?? firstSkippedAt
    }

    /// The `hkIdentifier` of a State of Mind row (no diagnostics kind maps to it).
    static let stateOfMindIdentifier = "HKStateOfMindType"

    static func identity(
        entry: HealthKitBatchEntryDTO?,
        nutrient: NutrientIntakeEntryDTO?,
        mood: StateOfMindSkippedSample? = nil
    ) -> String {
        if let entry { return entry.externalId }
        if let mood { return "mood|" + mood.externalId }
        guard let nutrient else { return "" }
        return "nutrient|" + nutrient.day + "|" + nutrient.nutrient.rawValue
    }

    static func dayNoonUTC(_ day: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

/// Why a register write did not become durable. Carries no value and no owner.
enum HealthKitSkippedRowRegisterError: Error, Sendable, Equatable {
    case unownedWriteRefused
    case writeNotVerified
}

/// The two operations the register needs from disk. Injected so a test runs
/// against memory and a lossy backing can be simulated.
struct HealthKitSkippedRowStorage: Sendable {
    let load: @Sendable () throws -> Data?
    let save: @Sendable (Data) throws -> Void

    /// `Application Support/HealthLog/HKSkipped/skipped-rows.json`.
    static let applicationSupport = HealthKitSkippedRowStorage(
        load: {
            let url = try fileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        },
        save: { data in
            let url = try fileURL()
            try SensitiveDataBackupExclusion.prepareDirectory(at: url.deletingLastPathComponent())
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    )

    private static func fileURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HealthLog", isDirectory: true)
            .appendingPathComponent("HKSkipped", isDirectory: true)
            .appendingPathComponent("skipped-rows.json", isDirectory: false)
    }
}

/// Owner-partitioned, bounded register of rows the server refused.
actor HealthKitSkippedRowRegister {
    static let shared = HealthKitSkippedRowRegister(storage: .applicationSupport)

    /// The register every sync path writes to: ``shared`` in the app. A test
    /// binds its own (in-memory) register for the scope of one call with
    /// `HealthKitSkippedRowRegister.$bound.withValue(…)`, which reaches the
    /// importers, the nutrient sweep and the outbox replay alike without a
    /// new parameter on each.
    @TaskLocal static var bound: HealthKitSkippedRowRegister?

    static var current: HealthKitSkippedRowRegister {
        bound ?? shared
    }

    /// Rows kept per account. A person does not produce this many refusals in
    /// normal use; a systematic one (a whole type mis-mapped) reaches it fast,
    /// and then the newest readings are the ones worth keeping. What falls off
    /// is counted, never silently forgotten.
    static let maxRowsPerOwner = 500

    static let formatVersion = 1

    private struct File: Codable, Equatable {
        var version: Int
        var rows: [HealthKitSkippedRow]
        /// Rows dropped at the bound, per owner.
        var overflow: [String: Int]
    }

    private let storage: HealthKitSkippedRowStorage
    private var cache: File?

    init(storage: HealthKitSkippedRowStorage) {
        self.storage = storage
    }

    // MARK: - Reads

    /// The account's rows, newest reading first.
    func rows(ownerID: String) -> [HealthKitSkippedRow] {
        guard let owner = Self.canonical(ownerID) else { return [] }
        return loaded().rows
            .filter { $0.ownerID == owner }
            .sorted { $0.measuredAt > $1.measuredAt }
    }

    func count(ownerID: String) -> Int {
        rows(ownerID: ownerID).count
    }

    /// Row count per HealthKit identifier, for the per-type warning.
    func countsByIdentifier(ownerID: String) -> [String: Int] {
        rows(ownerID: ownerID).reduce(into: [:]) { $0[$1.hkIdentifier, default: 0] += 1 }
    }

    /// Rows dropped at ``maxRowsPerOwner`` for this account.
    func overflowCount(ownerID: String) -> Int {
        guard let owner = Self.canonical(ownerID) else { return 0 }
        return loaded().overflow[owner] ?? 0
    }

    /// Measurement rows this build has not offered yet. Nutrient rows are shown
    /// and kept, but the measurement re-offer cannot send them (another route).
    func rowsDue(ownerID: String, build: String) -> [HealthKitSkippedRow] {
        rows(ownerID: ownerID).filter { $0.entry != nil && $0.lastOfferedBuild != build }
    }

    /// Every measurement row, for the manual re-offer.
    func measurementRows(ownerID: String) -> [HealthKitSkippedRow] {
        rows(ownerID: ownerID).filter { $0.entry != nil }
    }

    // MARK: - Writes

    /// Remembers freshly refused rows. A row already present is updated in place
    /// (latest reason, one more attempt), never duplicated.
    ///
    /// Durable only after a read-back returns every recorded id: the caller lets
    /// the HealthKit cursor move past these rows on the strength of this call.
    func record(
        _ skipped: [HealthKitSkippedEntry],
        ownerID: String,
        build: String,
        at now: Date = Date()
    ) throws {
        guard !skipped.isEmpty else { return }
        guard let owner = Self.canonical(ownerID) else {
            throw HealthKitSkippedRowRegisterError.unownedWriteRefused
        }
        var file = loaded()
        for item in skipped {
            if let index = file.rows.firstIndex(where: { $0.ownerID == owner && $0.id == item.id }) {
                file.rows[index].reason = item.reason
                // A nutrient day-total is re-read before every post: keep the
                // latest amount (the identity is the day and the nutrient).
                if let nutrient = item.nutrient { file.rows[index].nutrient = nutrient }
                file.rows[index].lastAttemptAt = now
                file.rows[index].attempts += 1
                file.rows[index].lastOfferedBuild = build
            } else {
                file.rows.append(
                    HealthKitSkippedRow(
                        ownerID: owner,
                        entry: item.entry,
                        nutrient: item.nutrient,
                        mood: item.mood,
                        reason: item.reason,
                        firstSkippedAt: now,
                        lastAttemptAt: now,
                        attempts: 1,
                        lastOfferedBuild: build
                    )
                )
            }
        }
        Self.enforceBound(&file, owner: owner)
        try persist(file)

        let kept = Set(loaded().rows.filter { $0.ownerID == owner }.map(\.id))
        let expected = Set(file.rows.filter { $0.ownerID == owner }.map(\.id))
        guard kept == expected else { throw HealthKitSkippedRowRegisterError.writeNotVerified }
    }

    /// Folds one re-offer back in: stored rows leave, still-refused rows carry
    /// the new reason and this build's stamp.
    func applyReoffer(
        stored storedIDs: Set<String>,
        refused: [HealthKitSkippedEntry],
        ownerID: String,
        build: String,
        at now: Date = Date()
    ) throws {
        guard let owner = Self.canonical(ownerID) else {
            throw HealthKitSkippedRowRegisterError.unownedWriteRefused
        }
        var file = loaded()
        file.rows.removeAll { $0.ownerID == owner && storedIDs.contains($0.id) }
        try persist(file)
        try record(refused, ownerID: owner, build: build, at: now)
    }

    /// Sign-out and account deletion. Every account's rows go: a signed-out
    /// device has no account entitled to see any of them.
    func clearAll() throws {
        try persist(File(version: Self.formatVersion, rows: [], overflow: [:]))
    }

    /// The logout cascade's entry point (every reason). A failure is surfaced,
    /// never swallowed: the file holds health values of the signed-out account.
    func clearOnLogout() {
        do {
            try clearAll()
        } catch {
            HLLog.storage.error("logout skip-register wipe failed — previous-user rows may linger")
        }
    }

    // MARK: - Private

    private func loaded() -> File {
        if let cache { return cache }
        let decoded = (try? storage.load())
            .flatMap { $0 }
            .flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        let file = decoded?.version == Self.formatVersion
            ? decoded ?? Self.empty
            : Self.empty
        cache = file
        return file
    }

    private func persist(_ file: File) throws {
        let data = try JSONEncoder().encode(file)
        try storage.save(data)
        // Re-read from the backing store rather than trusting the write: a lost
        // write must not look like a kept row.
        cache = nil
        guard loaded() == file else { throw HealthKitSkippedRowRegisterError.writeNotVerified }
    }

    private static var empty: File {
        File(version: formatVersion, rows: [], overflow: [:])
    }

    private static func enforceBound(_ file: inout File, owner: String) {
        let owned = file.rows.filter { $0.ownerID == owner }
        let excess = owned.count - maxRowsPerOwner
        guard excess > 0 else { return }
        let dropped = Set(owned.sorted { $0.measuredAt < $1.measuredAt }.prefix(excess).map(\.id))
        file.rows.removeAll { $0.ownerID == owner && dropped.contains($0.id) }
        file.overflow[owner, default: 0] += excess
    }

    private static func canonical(_ owner: String) -> String? {
        let trimmed = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Per-row verdicts of one batch

/// What the server said about one posted index.
struct HealthKitBatchRowVerdict: Sendable, Equatable {
    let index: Int
    let status: HealthKitEntryStatus
    let reason: String?

    /// The only three words that mean the row is in the server's state.
    var isStored: Bool {
        status == .inserted || status == .updated || status == .duplicate
    }
}

extension BatchUploadOutcome {
    /// One verdict per answered index, `entries[]` and `skipped[]` merged the
    /// way ``MeasurementBatchAcceptance`` merges them (a reason carried in only
    /// one of the two arrays still counts).
    var rowVerdicts: [HealthKitBatchRowVerdict] {
        var byIndex: [Int: HealthKitBatchRowVerdict] = [:]
        for entry in response.entries where chunk.indices.contains(entry.index) && byIndex[entry.index] == nil {
            byIndex[entry.index] = HealthKitBatchRowVerdict(index: entry.index, status: entry.status, reason: entry.reason)
        }
        for skipped in response.skipped where chunk.indices.contains(skipped.index) {
            if let existing = byIndex[skipped.index] {
                if existing.status == .skipped, existing.reason == nil {
                    byIndex[skipped.index] = HealthKitBatchRowVerdict(
                        index: skipped.index,
                        status: .skipped,
                        reason: skipped.reason
                    )
                }
            } else {
                byIndex[skipped.index] = HealthKitBatchRowVerdict(index: skipped.index, status: .skipped, reason: skipped.reason)
            }
        }
        return byIndex.values.sorted { $0.index < $1.index }
    }
}

/// The running binary's build, as the re-offer rule compares it.
enum HealthKitSkipRegisterBuild {
    static var current: String {
        AppBuildMetadata(
            marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString"),
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
        ).build ?? "unknown"
    }
}
