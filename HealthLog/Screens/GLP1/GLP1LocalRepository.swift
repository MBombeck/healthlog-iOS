import Foundation
import SwiftData

/// Public actor wrapping `GLP1LocalStore`. Lives in `AppContainer`, gets
/// injected into the four detail-screen sub-stores. Mirrors the
/// `OutboxQueue` → `OutboxStore` split so the actor surface stays
/// Sendable-clean and the persistence implementation can be swapped in
/// tests (in-memory) without touching call sites.
///
/// **Validation policy:** the repository validates *before* persisting —
/// note length cap (512 chars), severity range (0–3), dose-mg sanity
/// (> 0 and ≤ a generous 100 mg sanity ceiling — Liraglutide max is
/// 3 mg, Tirzepatide max is 15 mg; 100 mg leaves headroom for future
/// catalog additions without rejecting valid input). Invalid input is
/// clamped silently rather than thrown — the UI layer guards against
/// invalid input at the picker / slider boundary so an error here would
/// represent a programmer bug, not a user error.
public actor GLP1LocalRepository {
    /// Deferred-open state for the backing `GLP1LocalStore`. Mirrors
    /// `SWRCoordinator.CacheState`: production defers the SwiftData
    /// `ModelContainer` open onto a detached task (`makeWithRecoveryTask()`)
    /// so `AppContainer.init` (the cold-launch tick) never pays for it; the
    /// store resolves lazily on the first read/write (a GLP-1 detail-screen
    /// sub-store touching it — never on the launch tick). Tests seed
    /// `.resolved` directly via `init(store:)`.
    private enum StoreState {
        case pending(Task<GLP1LocalStore, Never>)
        case resolved(GLP1LocalStore)
    }

    private var storeState: StoreState

    /// Max length for free-text notes across all entities. Enforced at
    /// the repository boundary so the SwiftData schema doesn't need a
    /// validator.
    public static let maxNoteLength: Int = 512

    /// Sanity ceiling for `doseMg` — see comment on
    /// `GLP1LocalRepository`. Mirrors no specific clinical limit; it
    /// only rejects clearly-bogus user input (e.g. "1000 mg") so a typo
    /// doesn't pollute the ladder display.
    public static let maxDoseMg: Double = 100

    public init(store: GLP1LocalStore) {
        storeState = .resolved(store)
    }

    /// Production init — defers `GLP1LocalStore` resolution until the first
    /// read/write. `AppContainer` kicks the `ModelContainer` open onto a
    /// detached task via `makeWithRecoveryTask()`; we await it lazily on first
    /// use so app launch no longer pays for the SwiftData open on the
    /// cold-launch tick (audit P-1).
    public init(storeTask: Task<GLP1LocalStore, Never>) {
        storeState = .pending(storeTask)
    }

    /// Single-flight resolve of the deferred store. First caller awaits the
    /// open; subsequent callers return the memoised actor reference without
    /// re-opening. Mirrors `SWRCoordinator.cache()`.
    private func store() async -> GLP1LocalStore {
        switch storeState {
        case let .resolved(store):
            return store
        case let .pending(task):
            let value = await task.value
            storeState = .resolved(value)
            return value
        }
    }

    /// Synchronous production factory. Mirrors `OutboxQueue.makeWithRecovery`:
    /// tries the persistent SQLite store, wipes the directory + retries
    /// once on failure, falls back to an in-memory store with a logged
    /// warning. Kept for callers that don't pay the cold-launch budget
    /// (tests / macOS); the composition root prefers `makeWithRecoveryTask()`
    /// so the open runs off the launch tick.
    public static func makeWithRecovery() -> GLP1LocalRepository {
        GLP1LocalRepository(store: makeStoreWithRecovery())
    }

    /// Detached-task variant of `makeWithRecovery()`. Schedules the
    /// `ModelContainer` open on a `.userInitiated` detached task so the
    /// SwiftData open (~30-80 ms cold) no longer blocks the launch tick
    /// (audit P-1). Consumed by `init(storeTask:)`, resolved lazily on first
    /// use. Unlike the Outbox (whose `BGTaskScheduler.register` must run in
    /// `applicationDidFinishLaunching`), this store has no launch-tick coupling.
    public static func makeWithRecoveryTask() -> GLP1LocalRepository {
        let task = Task.detached(priority: .userInitiated) {
            makeStoreWithRecovery()
        }
        return GLP1LocalRepository(storeTask: task)
    }

    /// Shared store-open recovery ladder used by both the sync + deferred
    /// factories. `static` (hence nonisolated) so the detached open-task can
    /// call it off the actor.
    private static func makeStoreWithRecovery() -> GLP1LocalStore {
        do {
            let container = try GLP1LocalStore.makePersistent()
            return GLP1LocalStore(modelContainer: container)
        } catch {
            HLLog.outbox.error(
                "GLP1 store unreadable, attempting rebuild: \(LogSanitizer.redact(String(describing: error)))"
            )
            if let storeURL = try? GLP1LocalStore.persistentStoreURL() {
                let dir = storeURL.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: dir)
            }
            do {
                let container = try GLP1LocalStore.makePersistent()
                return GLP1LocalStore(modelContainer: container)
            } catch {
                HLLog.outbox.error(
                    "GLP1 rebuild also failed, falling back to in-memory: \(LogSanitizer.redact(String(describing: error)))"
                )
                // Non-trapping in-memory floor (audit M2): degrade to an inert
                // empty-schema store instead of `try!`-trapping on the path that
                // exists to avoid a hard launch failure.
                let container = ModelContainerRecovery.recoveredInMemoryContainer(
                    log: HLLog.outbox,
                    subsystem: "GLP1",
                    build: GLP1LocalStore.makeInMemory
                )
                return GLP1LocalStore(modelContainer: container)
            }
        }
    }

    // MARK: - Titration

    public func titrationSteps(
        medicationID: String
    ) async throws -> [TitrationStepEntrySnapshot] {
        try await store().snapshotTitrationSteps(medicationID: medicationID)
    }

    public func addTitrationStep(
        medicationID: String,
        effectiveFrom: Date,
        doseMg: Double,
        note: String?
    ) async throws -> TitrationStepEntrySnapshot {
        let id = UUID().uuidString
        let clampedDose = clampDose(doseMg)
        let cleanedNote = sanitizeNote(note)
        try await store().insertTitrationStep(
            id: id,
            medicationID: medicationID,
            effectiveFrom: effectiveFrom,
            doseMg: clampedDose,
            note: cleanedNote
        )
        return TitrationStepEntrySnapshot(
            id: id,
            medicationID: medicationID,
            effectiveFrom: effectiveFrom,
            doseMg: clampedDose,
            note: cleanedNote,
            createdAt: .now
        )
    }

    public func updateTitrationStep(
        id: String,
        effectiveFrom: Date,
        doseMg: Double,
        note: String?
    ) async throws {
        try await store().updateTitrationStep(
            id: id,
            effectiveFrom: effectiveFrom,
            doseMg: clampDose(doseMg),
            note: sanitizeNote(note)
        )
    }

    public func deleteTitrationStep(id: String) async throws {
        try await store().deleteTitrationStep(id: id)
    }

    // MARK: - Side-effects

    public func sideEffects(
        medicationID: String,
        sinceDays: Int = 90
    ) async throws -> [SideEffectEntrySnapshot] {
        try await store().snapshotSideEffects(
            medicationID: medicationID,
            sinceDays: sinceDays
        )
    }

    public func addSideEffect(
        medicationID: String,
        loggedAt: Date,
        kind: SideEffectKind,
        severity: Int,
        note: String?
    ) async throws -> SideEffectEntrySnapshot {
        let id = UUID().uuidString
        let clampedSeverity = max(0, min(3, severity))
        let cleanedNote = sanitizeNote(note)
        try await store().insertSideEffect(
            id: id,
            medicationID: medicationID,
            loggedAt: loggedAt,
            kindRaw: kind.rawValue,
            severity: clampedSeverity,
            note: cleanedNote
        )
        return SideEffectEntrySnapshot(
            id: id,
            medicationID: medicationID,
            loggedAt: loggedAt,
            kindRaw: kind.rawValue,
            severity: clampedSeverity,
            note: cleanedNote,
            createdAt: .now
        )
    }

    public func deleteSideEffect(id: String) async throws {
        try await store().deleteSideEffect(id: id)
    }

    /// v0.12 SP3 — server-id mapping helpers for the side-effect round-trip.
    public func setSideEffectServerID(localID: String, serverID: String) async throws {
        try await store().setSideEffectServerID(localID: localID, serverID: serverID)
    }

    public func sideEffectServerID(localID: String) async throws -> String? {
        try await store().sideEffectServerID(localID: localID)
    }

    // MARK: - Pen inventory

    public func pens(
        medicationID: String
    ) async throws -> [PenInventoryEntrySnapshot] {
        try await store().snapshotPens(medicationID: medicationID)
    }

    public func addPen(
        medicationID: String,
        manufacturer: String,
        doseStrength: String,
        dispensedAt: Date,
        firstUsedAt: Date?,
        notes: String?
    ) async throws -> PenInventoryEntrySnapshot {
        let id = UUID().uuidString
        let cleanedNotes = sanitizeNote(notes)
        try await store().insertPen(
            id: id,
            medicationID: medicationID,
            manufacturer: manufacturer,
            doseStrength: doseStrength,
            dispensedAt: dispensedAt,
            firstUsedAt: firstUsedAt,
            finishedAt: nil,
            notes: cleanedNotes
        )
        return PenInventoryEntrySnapshot(
            id: id,
            medicationID: medicationID,
            manufacturer: manufacturer,
            doseStrength: doseStrength,
            dispensedAt: dispensedAt,
            firstUsedAt: firstUsedAt,
            finishedAt: nil,
            notes: cleanedNotes,
            createdAt: .now
        )
    }

    public func markPenFinished(id: String, finishedAt: Date = .now) async throws {
        try await store().markPenFinished(id: id, finishedAt: finishedAt)
    }

    public func deletePen(id: String) async throws {
        try await store().deletePen(id: id)
    }

    /// v0.12 SP4 — server-id mapping helpers for the inventory round-trip.
    public func setPenServerID(localID: String, serverID: String) async throws {
        try await store().setPenServerID(localID: localID, serverID: serverID)
    }

    public func penServerID(localID: String) async throws -> String? {
        try await store().penServerID(localID: localID)
    }

    /// #52 — replay one server inventory row into the local pen list (insert or
    /// update, keyed on `serverID`). See `GLP1LocalStore.upsertPenFromServer`.
    public func upsertPenFromServer(
        serverID: String,
        medicationID: String,
        manufacturer: String,
        doseStrength: String,
        dispensedAt: Date,
        firstUsedAt: Date?,
        finishedAt: Date?,
        notes: String?
    ) async throws {
        try await store().upsertPenFromServer(
            serverID: serverID,
            medicationID: medicationID,
            manufacturer: manufacturer,
            doseStrength: doseStrength,
            dispensedAt: dispensedAt,
            firstUsedAt: firstUsedAt,
            finishedAt: finishedAt,
            notes: sanitizeNote(notes)
        )
    }

    // MARK: - Injection sites

    public func sites(
        medicationID: String,
        limit: Int = 32
    ) async throws -> [InjectionSiteEntrySnapshot] {
        try await store().snapshotSites(medicationID: medicationID, limit: limit)
    }

    public func addSite(
        medicationID: String,
        injectedAt: Date,
        site: InjectionSite,
        note: String?
    ) async throws -> InjectionSiteEntrySnapshot {
        let id = UUID().uuidString
        let cleanedNote = sanitizeNote(note)
        try await store().insertSite(
            id: id,
            medicationID: medicationID,
            injectedAt: injectedAt,
            siteRaw: site.rawValue,
            note: cleanedNote
        )
        return InjectionSiteEntrySnapshot(
            id: id,
            medicationID: medicationID,
            injectedAt: injectedAt,
            siteRaw: site.rawValue,
            note: cleanedNote,
            createdAt: .now
        )
    }

    public func deleteSite(id: String) async throws {
        try await store().deleteSite(id: id)
    }

    // MARK: - Cascade

    public func deleteAllForMedication(_ medicationID: String) async throws {
        try await store().deleteAllForMedication(medicationID)
    }

    public func deleteAll() async throws {
        try await store().deleteAll()
    }

    // MARK: - Internals

    private func clampDose(_ raw: Double) -> Double {
        max(0, min(Self.maxDoseMg, raw))
    }

    private func sanitizeNote(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(Self.maxNoteLength))
    }
}

// MARK: - Site-rotation suggestion

/// Pure-function helper that picks the next recommended injection site
/// given the user's recent history. Strategy:
///
/// 1. Collect the last N injection sites (default 8 — matches the EMA
///    EPAR §4.2 reference 8-week rotation window).
/// 2. Build a frequency map; the site **least used** in the window wins.
/// 3. Ties broken by going to the site furthest from the most-recent
///    injection (per `InjectionSite.priority(distanceFrom:)`).
///
/// Returns `nil` when the user has no recorded history yet — the UI
/// then renders a neutral "Wähle eine Stelle für die Rotation" prompt
/// without auto-suggesting.
///
/// **MDR boundary:** this is *rotation* guidance (avoid lipohypertrophy
/// from repeated same-site injections), not clinical advice. The picker
/// surfaces it as "Vorschlag laut Rotationsplan", never "you must".
public enum InjectionSiteRotation {
    public static let defaultWindow: Int = 8

    public static func suggestNext(
        recent: [InjectionSite],
        window: Int = defaultWindow
    ) -> InjectionSite? {
        guard !recent.isEmpty else { return nil }
        let bounded = Array(recent.prefix(max(1, window)))
        let mostRecent = bounded[0]
        var counts: [InjectionSite: Int] = [:]
        for site in InjectionSite.allCases {
            counts[site] = 0
        }
        for site in bounded {
            counts[site, default: 0] += 1
        }
        let minCount = counts.values.min() ?? 0
        let candidates = counts.filter { $0.value == minCount }.map(\.key)
        if candidates.count == 1 { return candidates[0] }
        // Tie-break: prefer site on opposite body region from the most
        // recent injection (cross-body avoids same-side over-use).
        return candidates.max { lhs, rhs in
            priority(lhs, distanceFrom: mostRecent) < priority(rhs, distanceFrom: mostRecent)
        }
    }

    /// Coarse distance metric between two sites. Higher = "more
    /// different body region". Sufficient for tie-breaking.
    static func priority(_ site: InjectionSite, distanceFrom other: InjectionSite) -> Int {
        if site == other { return 0 }
        let lhsRegion = region(site)
        let rhsRegion = region(other)
        if lhsRegion != rhsRegion { return 3 }
        let lhsSide = side(site)
        let rhsSide = side(other)
        if lhsSide != rhsSide { return 2 }
        return 1
    }

    enum Region { case abdomen, thigh, arm }
    enum Side { case left, right }

    static func region(_ site: InjectionSite) -> Region {
        switch site {
        case .abdomenLeftUpper, .abdomenRightUpper, .abdomenLeftLower, .abdomenRightLower:
            .abdomen
        case .thighLeft, .thighRight:
            .thigh
        case .armLeft, .armRight:
            .arm
        }
    }

    static func side(_ site: InjectionSite) -> Side {
        switch site {
        case .abdomenLeftUpper, .abdomenLeftLower, .thighLeft, .armLeft:
            .left
        case .abdomenRightUpper, .abdomenRightLower, .thighRight, .armRight:
            .right
        }
    }
}
