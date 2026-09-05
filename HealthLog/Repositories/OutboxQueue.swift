import Foundation
import SwiftData

// The actor intentionally keeps the enqueue chokepoint and its persistent
// operation contract together; kind/payload expansions live in extensions.
// swiftlint:disable file_length type_body_length

/// Persistent Outbox-Faade. Public API hat sich gegenüber Phase 4 (in-memory)
/// nur in zwei Punkten geändert:
///
///   1. Konstruktion ist `async throws` — der `ModelContainer` muss aufgesetzt
///      werden bevor erste Operationen reinkommen.
///   2. `enqueue/remove/incrementAttempts` sind `async throws` — `modelContext.save()`
///      darf werfen.
///
/// Der früher dokumentierte "verliert Operationen beim App-Restart"-Bug ist
/// damit erledigt (siehe ADR-011 + Audit-v021 C-2).
///
/// Intern delegiert die Faade an `OutboxStore` (ein `@ModelActor`). Nur Sendable
/// Value-Types (`Operation` / `OutboxOperationSnapshot`) überqueren die
/// Actor-Grenze — `OutboxOperation` (PersistentModel) bleibt am Store-Context
/// gepinnt.
public actor OutboxQueue {
    public enum OwnerLeaseError: Error, Sendable, Equatable {
        case staleOwner
    }

    /// Ephemeral authenticated-session lease for account-bound writes. The
    /// bearer is deliberately never persisted or logged; equality against the
    /// live Keychain value is the session-generation check. A token rotation,
    /// logout, or A→B switch invalidates the lease before another wire call or
    /// durable enqueue can occur.
    public struct AuthLease: Sendable, Equatable {
        let ownerUserID: String
        let bearerToken: String
        let validatesCredentialGeneration: Bool

        var authorizationHeader: String? {
            validatesCredentialGeneration ? "Bearer \(bearerToken)" : nil
        }
    }

    public struct Operation: Sendable, Identifiable, Codable {
        public let id: UUID
        public let kind: Kind
        public let payload: Data
        public let idempotencyKey: String
        public let createdAt: Date
        public var attempts: Int
        /// Wall-clock of the last replay attempt — drives the audit-v0162 H1
        /// back-off (skip an op re-attempted within `attemptBackoff`). Mirrors
        /// `OutboxOperation.lastAttemptAt`.
        public var lastAttemptAt: Date?
        /// **v0.13 WS — cross-user binding.** The user who owned this write at
        /// enqueue time. Left `nil` by the repository enqueue sites; the
        /// `OutboxQueue.enqueue` chokepoint stamps the current signed-in
        /// `KeychainKey.userID` before persisting (single source of truth, so
        /// every call site is covered without threading the id through each
        /// repo). A non-`nil` value passed in (tests) is respected as-is.
        public var ownerUserID: String?

        /// **audit-v0162 H-4 — optimistic→server id remap key.** The entity id a
        /// PHI records/labs op concerns (a `create` stamps its `optimistic-<uuid>`,
        /// a dependent `update`/`delete` the id it targets). `OutboxReplayService`
        /// remaps siblings to the real server id once the create lands. `nil` for
        /// kinds without an optimistic-id chain. See `OutboxOperation.clientEntityId`.
        public var clientEntityId: String?

        public init(
            id: UUID = UUID(),
            kind: Kind,
            payload: Data,
            idempotencyKey: String = UUID().uuidString.lowercased(),
            createdAt: Date = .now,
            attempts: Int = 0,
            lastAttemptAt: Date? = nil,
            ownerUserID: String? = nil,
            clientEntityId: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.payload = payload
            self.idempotencyKey = idempotencyKey
            self.createdAt = createdAt
            self.attempts = attempts
            self.lastAttemptAt = lastAttemptAt
            self.ownerUserID = ownerUserID
            self.clientEntityId = clientEntityId
        }

        // `Kind` is declared in `OutboxQueue+Kind.swift` (an extension on
        // `Operation`) so the long case list does not count against the actor's
        // `type_body_length` budget (file_length discipline).
    }

    /// Codable payload shapes for the v0.5.x edit/delete kinds. Each shape is
    /// `Sendable` + `Codable` + decoded by `OutboxReplayService.dispatch` via
    /// the persisted `payload: Data`. Kept in one enum-namespace so the
    /// per-kind contract is reviewable in a single place.
    public enum Payloads {
        /// `updateMeasurement` payload: server route `PATCH /api/measurements/[id]`.
        /// The `patch` mirrors `MeasurementPatch` (value/measuredAt/notes).
        ///
        /// **BP-pair semantics (T-1):** `diastolicId` + `diastolicValue` are
        /// populated when the affected measurement is a `bloodPressure` row
        /// with both peers known (Aggregator merged sys + dia). Replay then
        /// re-issues two paired PATCHes against `[id]` (systolic-value) and
        /// `[diastolicId]` (diastolic-value). For non-BP rows both are
        /// `nil` und replay falls back to the historic single-PATCH path.
        public struct UpdateMeasurement: Codable, Sendable {
            public let id: String
            public let patch: MeasurementPatch
            /// Optional — when the affected measurement carries an
            /// `HKMetadataKeyExternalUUID`, callers (T-1/T-2 UIs) propagate
            /// the HK-side mutation themselves *before* enqueuing. T-0
            /// persists `kind` purely so cache-invalidation on replay knows
            /// which `measurementSeries(kind:, days:)` buckets to drop.
            public let kind: MetricKind
            /// Diastolic peer-row id for BP-pair edits (T-1). `nil` for
            /// scalar measurements und für BP-Halbpaare die solo auf dem
            /// Server liegen (Aggregator-Fallback).
            public let diastolicId: String?
            /// Diastolic peer value for BP-pair edits. Used in the second
            /// PATCH leg against `diastolicId`. `nil` for non-BP payloads.
            public let diastolicValue: Double?
            /// Glucose context for glucose-row edits (T-2). Persisted on the
            /// outbox so the replay path can re-hydrate the
            /// `MeasurementPatch.glucoseContext` field (Wire-Codable
            /// suppresses it — the value would otherwise be lost across an
            /// App-restart). `nil` for non-glucose payloads. Server-side
            /// PATCH support tracked as SB-25; until then the context is
            /// applied only to the optimistic Domain row, not the wire.
            public let glucoseContext: GlucoseContext?

            public init(
                id: String,
                patch: MeasurementPatch,
                kind: MetricKind,
                diastolicId: String? = nil,
                diastolicValue: Double? = nil,
                glucoseContext: GlucoseContext? = nil
            ) {
                self.id = id
                self.patch = patch
                self.kind = kind
                self.diastolicId = diastolicId
                self.diastolicValue = diastolicValue
                self.glucoseContext = glucoseContext
            }
        }

        /// `deleteMeasurement` payload: server route `DELETE /api/measurements/[id]`.
        public struct DeleteMeasurement: Codable, Sendable {
            public let id: String
            public init(id: String) {
                self.id = id
            }
        }

        /// `bulkDeleteMeasurements` payload: one ≤200-id chunk for
        /// `POST /api/measurements/bulk-delete` (v1.15.13). The repo chunks a
        /// larger selection BEFORE enqueueing, so a payload always satisfies
        /// the server's `z.array(...).min(1).max(200)` bound.
        public struct BulkDeleteMeasurements: Codable, Sendable {
            public let ids: [String]
            public init(ids: [String]) {
                self.ids = ids
            }
        }

        /// `updateMood` payload: server route `PUT /api/mood-entries/[id]`.
        public struct UpdateMood: Codable, Sendable {
            public let id: String
            public let patch: MoodEntryPatch

            public init(id: String, patch: MoodEntryPatch) {
                self.id = id
                self.patch = patch
            }
        }

        /// `deleteMood` payload: server route `DELETE /api/mood-entries/[id]`.
        public struct DeleteMood: Codable, Sendable {
            public let id: String
            public init(id: String) {
                self.id = id
            }
        }

        /// `createMedication` payload: server route `POST /api/medications`.
        /// Body shape mirrors `MedicationsRepository.MedicationCreate`.
        public struct CreateMedication: Codable, Sendable {
            public let body: MedicationsRepository.MedicationCreate
            public init(body: MedicationsRepository.MedicationCreate) {
                self.body = body
            }
        }

        /// `updateMedication` payload: server route `PUT /api/medications/[id]`.
        public struct UpdateMedication: Codable, Sendable {
            public let id: String
            public let patch: MedicationsRepository.MedicationPatch
            public init(id: String, patch: MedicationsRepository.MedicationPatch) {
                self.id = id
                self.patch = patch
            }
        }

        /// `deleteMedication` payload: server route `DELETE /api/medications/[id]`.
        public struct DeleteMedication: Codable, Sendable {
            public let id: String
            public init(id: String) {
                self.id = id
            }
        }

        /// `updateIntake` payload: server route
        /// `PUT /api/medications/[medicationId]/intake/[eventId]`.
        public struct UpdateIntake: Codable, Sendable {
            public let medicationId: String
            public let eventId: String
            public let patch: MedicationsRepository.IntakePatch
            public init(medicationId: String, eventId: String, patch: MedicationsRepository.IntakePatch) {
                self.medicationId = medicationId
                self.eventId = eventId
                self.patch = patch
            }
        }

        /// `deleteIntake` payload: server route
        /// `DELETE /api/medications/[medicationId]/intake/[eventId]`.
        public struct DeleteIntake: Codable, Sendable {
            public let medicationId: String
            public let eventId: String
            public init(medicationId: String, eventId: String) {
                self.medicationId = medicationId
                self.eventId = eventId
            }
        }

        /// `takeMedication` payload variant — reminder-driven intake from
        /// a notification action (`Genommen` / `Übersprungen` on a
        /// `MEDICATION_REMINDER` push). Server route is the bulk
        /// endpoint `POST /api/medications/intake/bulk`, single entry.
        /// Stored as an isolated struct so the replay path can decode
        /// without colliding with the legacy `IntakeUpdate` shape (which
        /// also routes to `takeMedication` but POSTs the single-row
        /// endpoint). The replay dispatcher tries both decoders and
        /// dispatches based on the one that succeeds.
        public struct ReminderIntake: Codable, Sendable {
            public let entry: MedicationsRepository.BulkIntakeEntry
            public init(entry: MedicationsRepository.BulkIntakeEntry) {
                self.entry = entry
            }
        }

        /// Build 6.1 — `logMedicationIntake` payload: server route
        /// `POST /api/medications/{id}/intake`. Carries the exact
        /// `MedicationIdIntakeBody` (back-dated `takenAt` / `scheduledFor`,
        /// `skipped`, `doseTaken`, optional site + `forceSlotInstant`, and the
        /// body-level `idempotencyKey`). Replay re-POSTs it under the persisted
        /// idempotency key so a dose logged offline lands exactly-once.
        public struct LogMedicationIntake: Codable, Sendable {
            public let medicationId: String
            public let body: MedicationsRepository.MedicationIdIntakeBody
            public init(medicationId: String, body: MedicationsRepository.MedicationIdIntakeBody) {
                self.medicationId = medicationId
                self.body = body
            }
        }

        /// `updateThresholds` payload — server route `PUT /api/user/thresholds`.
        /// `patch` is the partial `{ metric: { min, max } }` map the user
        /// edited; the server merges it onto the existing overrides. Replay
        /// re-issues the identical PUT with the persisted idempotency key so
        /// an offline edit that actually landed before the app was killed is
        /// deduped server-side.
        public struct UpdateThresholds: Codable, Sendable {
            public let patch: ThresholdsUpdatePayload
            public init(patch: ThresholdsUpdatePayload) {
                self.patch = patch
            }
        }

        /// v0.8.0 W10 — server-first Insights layout write. The full
        /// (server-filtered) layout is the idempotent replace body; replay
        /// re-issues the identical PUT under the persisted idempotency key.
        public struct UpdateInsightsLayout: Codable, Sendable {
            public let layout: InsightsLayout
            public init(layout: InsightsLayout) {
                self.layout = layout
            }
        }

        /// v0.12 SP3 — `createMedicationSideEffect` payload. Replay re-issues
        /// `POST /api/medications/[medicationId]/side-effects` with `body`.
        public struct CreateMedicationSideEffect: Codable, Sendable {
            public let medicationId: String
            public let body: MedicationSideEffectCreate
            public init(medicationId: String, body: MedicationSideEffectCreate) {
                self.medicationId = medicationId
                self.body = body
            }
        }

        /// v0.12 SP3 — `deleteMedicationSideEffect` payload. Replay re-issues
        /// `DELETE /api/medications/[medicationId]/side-effects/[logId]`.
        public struct DeleteMedicationSideEffect: Codable, Sendable {
            public let medicationId: String
            public let logId: String
            public init(medicationId: String, logId: String) {
                self.medicationId = medicationId
                self.logId = logId
            }
        }

        /// v0.12 SP4 — `createMedicationInventory` payload. Replay re-issues
        /// `POST /api/medications/[medicationId]/inventory` with `body`.
        public struct CreateMedicationInventory: Codable, Sendable {
            public let medicationId: String
            public let body: MedicationInventoryCreate
            public init(medicationId: String, body: MedicationInventoryCreate) {
                self.medicationId = medicationId
                self.body = body
            }
        }

        /// v0.12 SP4 — `updateMedicationInventory` payload. Replay re-issues
        /// `PATCH /api/medications/[medicationId]/inventory/[itemId]`.
        public struct UpdateMedicationInventory: Codable, Sendable {
            public let medicationId: String
            public let itemId: String
            public let patch: MedicationInventoryPatch
            public init(medicationId: String, itemId: String, patch: MedicationInventoryPatch) {
                self.medicationId = medicationId
                self.itemId = itemId
                self.patch = patch
            }
        }

        /// v0.12 SP4 — `deleteMedicationInventory` payload. Replay re-issues
        /// `DELETE /api/medications/[medicationId]/inventory/[itemId]`.
        public struct DeleteMedicationInventory: Codable, Sendable {
            public let medicationId: String
            public let itemId: String
            public init(medicationId: String, itemId: String) {
                self.medicationId = medicationId
                self.itemId = itemId
            }
        }

        /// v0.14.8 — `logCycleDayLog` payload. Replay POSTs the single entry to
        /// the bulk drain `POST /api/cycle/day-logs/bulk` under the persisted
        /// idempotency key; the entry's `externalId` makes the UPSERT idempotent.
        public struct LogCycleDayLog: Codable, Sendable {
            public let write: CycleDayLogWrite
            public init(write: CycleDayLogWrite) {
                self.write = write
            }
        }

        /// v0.14.8 — `updateCycleDayLog` payload: `PATCH /api/cycle/day-logs/[id]`.
        public struct UpdateCycleDayLog: Codable, Sendable {
            public let id: String
            public let patch: CycleDayLogPatch

            public init(id: String, patch: CycleDayLogPatch) {
                self.id = id
                self.patch = patch
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                if let current = try container.decodeIfPresent(CycleDayLogPatch.self, forKey: .patch) {
                    patch = current
                } else {
                    // Pending pre-Build-5 rows stored the PATCH body under
                    // `write`. CycleDayLogPatch ignores the old immutable keys.
                    patch = try container.decode(CycleDayLogPatch.self, forKey: .legacyWrite)
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(id, forKey: .id)
                try container.encode(patch, forKey: .patch)
            }

            private enum CodingKeys: String, CodingKey {
                case id, patch
                case legacyWrite = "write"
            }
        }

        /// v0.14.8 — `deleteCycleDayLog` payload: `DELETE /api/cycle/day-logs/[id]`.
        public struct DeleteCycleDayLog: Codable, Sendable {
            public let id: String
            public init(id: String) {
                self.id = id
            }
        }

        /// v0.14.8 — `cyclePeriod` payload: `POST /api/cycle/period`.
        public struct CyclePeriod: Codable, Sendable {
            public let request: CyclePeriodRequest
            public init(request: CyclePeriodRequest) {
                self.request = request
            }
        }

        /// v0.14.8 audit Wave A (C4.1) — `uploadWorkoutBatch` payload. Replay
        /// re-issues `POST /api/workouts/batch` (one chunk, ≤ the server's
        /// 100-workout cap — the importer chunks before calling
        /// `uploadBatch`) under the persisted idempotency key. The per-entry
        /// `externalId` UPSERT makes a batch that already landed before
        /// app-kill drain to `duplicate` instead of inserting twins.
        public struct UploadWorkoutBatch: Codable, Sendable {
            public let workouts: [WorkoutIngestDTO]
            public init(workouts: [WorkoutIngestDTO]) {
                self.workouts = workouts
            }
        }

        // W-B187 COACH-3 payloads live in `OutboxQueue+CoachAboutMe.swift`.
    }

    /// **Phase 09 / plan 09-05 — one persistent-store open, deferred and shared.**
    ///
    /// The result of running the G-9 recovery ladder once. It is a value rather
    /// than a `ModelContainer` at the call site so the composition root can wrap
    /// the open in its `outbox.open` signpost without importing SwiftData —
    /// `Repositories/` compiles into the platform-free `HealthLogCore` target,
    /// and `HLPerfSignpost` is deliberately not in it.
    public struct StoreHandle: Sendable {
        let container: ModelContainer

        public init(container: ModelContainer) {
            self.container = container
        }
    }

    /// The deferred open. Runs at most once per queue, on first use.
    private let openStore: @Sendable () -> StoreHandle
    /// The resolved store, once an open has completed.
    private var openedStore: OutboxStore?
    /// The open currently in flight. It is written **before the first
    /// suspension** in ``resolvedStore()``, which is the whole reason a second
    /// arrival coalesces onto it instead of starting a second SQLite open.
    private var openInFlight: Task<OutboxStore, Never>?
    private var continuations: [UUID: AsyncStream<[Operation]>.Continuation] = [:]

    /// **v0.13 WS.** Resolves the currently signed-in `KeychainKey.userID` at
    /// enqueue time so `enqueue(_:)` can stamp every row's owner from a single
    /// chokepoint (no per-repository plumbing). Defaults to a real
    /// `KeychainStore` read; tests inject a deterministic provider. Reads
    /// happen on the actor, off any hot path (enqueue is already a SwiftData
    /// write), so the synchronous Keychain hit is acceptable.
    private let currentOwnerProvider: @Sendable () -> String?

    /// Resolves the live bearer paired with ``currentOwnerProvider``. Kept as a
    /// separate injectable seam so tests can deterministically rotate/remove a
    /// credential between an owner gate and the eventual wire dispatch.
    private let currentAuthTokenProvider: @Sendable () -> String?
    /// Test-only escape hatch selected solely by `inMemory: true` when no token
    /// provider is injected. Persistent and recovery queues never enable it.
    private let allowsUnauthenticatedTestLease: Bool

    /// Build 274 (public #4) — every write to the shared-container store runs
    /// under this lease; see `BackgroundExecutionLeasing`.
    private let backgroundLease: any BackgroundExecutionLeasing

    /// Default initializer — persistent SQLite store under
    /// `Library/Application Support/HealthLog/Outbox/outbox.sqlite`. Throws when
    /// the on-disk container cannot be opened (corruption, permissions). Callers
    /// in production should go through `OutboxQueue.makeWithRecovery()` so a
    /// degraded in-memory fallback kicks in instead of a hard launch failure.
    ///
    /// - Parameters:
    ///   - inMemory: when `true`, uses
    ///     `ModelConfiguration(isStoredInMemoryOnly: true)` — meant for tests.
    ///   - currentOwnerProvider: resolves the signed-in `KeychainKey.userID`
    ///     for the v0.13 WS owner stamp. Defaults to a live Keychain read.
    ///   - backgroundLease: Build 274 (public #4) — the background-execution
    ///     lease every persist runs under. Defaults to the unconditional one.
    public init(
        inMemory: Bool = false,
        currentOwnerProvider: @escaping @Sendable () -> String? = OutboxQueue.defaultOwnerProvider,
        currentAuthTokenProvider: (@Sendable () -> String?)? = nil,
        backgroundLease: any BackgroundExecutionLeasing = UnconditionalBackgroundExecutionLease()
    ) throws {
        let container = try inMemory
            ? OutboxStore.makeInMemory()
            : OutboxStore.makePersistent()
        openStore = { StoreHandle(container: container) }
        openedStore = OutboxStore(modelContainer: container)
        self.currentOwnerProvider = currentOwnerProvider
        self.currentAuthTokenProvider = currentAuthTokenProvider ?? OutboxQueue.defaultAuthTokenProvider
        allowsUnauthenticatedTestLease = inMemory && currentAuthTokenProvider == nil
        self.backgroundLease = backgroundLease
    }

    /// **Phase 09 / plan 09-05 — the deferred production entry point.**
    ///
    /// Constructs a queue that has opened nothing. The first operation (or an
    /// explicit ``prepareStore()``) runs `open` exactly once, and every arrival
    /// while that is in flight awaits the same handle.
    ///
    /// `open` is expected to be the G-9 recovery ladder
    /// (``recoverOrDegradeStore()``), so it does not throw: a corrupted offline
    /// store is bad, and failing every outbox write over it is worse.
    ///
    /// Build 274 (public #4) — `backgroundLease` is the assertion every persist
    /// runs under; the production factory passes the UIKit one.
    public static func deferred(
        _ open: @escaping @Sendable () -> StoreHandle,
        currentOwnerProvider: @escaping @Sendable () -> String? = OutboxQueue.defaultOwnerProvider,
        currentAuthTokenProvider: @escaping @Sendable () -> String? = OutboxQueue.defaultAuthTokenProvider,
        backgroundLease: any BackgroundExecutionLeasing = UnconditionalBackgroundExecutionLease()
    ) -> OutboxQueue {
        OutboxQueue(
            deferredOpen: open,
            currentOwnerProvider: currentOwnerProvider,
            currentAuthTokenProvider: currentAuthTokenProvider,
            backgroundLease: backgroundLease
        )
    }

    /// Build 274 (public #4) — takes the background-execution lease without a
    /// default so the deferred production path always states which one it uses.
    private init(
        deferredOpen: @escaping @Sendable () -> StoreHandle,
        currentOwnerProvider: @escaping @Sendable () -> String?,
        currentAuthTokenProvider: @escaping @Sendable () -> String?,
        backgroundLease: any BackgroundExecutionLeasing
    ) {
        openStore = deferredOpen
        openedStore = nil
        self.currentOwnerProvider = currentOwnerProvider
        self.currentAuthTokenProvider = currentAuthTokenProvider
        // This is the production path; it must never infer a test bypass.
        allowsUnauthenticatedTestLease = false
        self.backgroundLease = backgroundLease
    }

    /// Container-injection entry point. Lets a test bind multiple `OutboxQueue`
    /// faades to the *same* `ModelContainer`, simulating "discard process A,
    /// recreate process B against the same on-disk store" without paying disk
    /// I/O. Also used by `makeWithRecovery()`'s non-trapping in-memory floor
    /// (audit M2) to wrap a recovered container without a throwing init.
    /// Production callers should otherwise use `init(inMemory:)` or
    /// `makeWithRecovery()`.
    ///
    /// Build 274 (public #4) — carries the same defaulted `backgroundLease`
    /// seam as the other initializers, so the stored lease is stated by every
    /// construction path rather than inferred.
    public init(
        testContainer: ModelContainer,
        currentOwnerProvider: @escaping @Sendable () -> String? = OutboxQueue.defaultOwnerProvider,
        currentAuthTokenProvider: @escaping @Sendable () -> String? = OutboxQueue.defaultAuthTokenProvider,
        backgroundLease: any BackgroundExecutionLeasing = UnconditionalBackgroundExecutionLease()
    ) {
        openStore = { StoreHandle(container: testContainer) }
        openedStore = OutboxStore(modelContainer: testContainer)
        self.currentOwnerProvider = currentOwnerProvider
        self.currentAuthTokenProvider = currentAuthTokenProvider
        // This initializer is also a production recovery path, so it must
        // never infer a test bypass merely from an in-memory ModelContainer.
        allowsUnauthenticatedTestLease = false
        self.backgroundLease = backgroundLease
    }

    /// Whether the persistent store has actually been opened yet. The launch
    /// claim this plan makes is a statement about this flag at a moment in time,
    /// not about a duration.
    public var isStoreOpen: Bool {
        openedStore != nil
    }

    /// Run the deferred open now, without performing an operation.
    ///
    /// The ordinary foreground bootstrap calls this **after** the first frame,
    /// which is what turns "the SQLite open is off the launch-critical path"
    /// into something a trace and a counter can both witness. A first real or
    /// background operation does not wait for it — it opens on demand through
    /// the same handle.
    public func prepareStore() async {
        _ = await resolvedStore()
    }

    /// The one shared open.
    ///
    /// Three properties, and each is load-bearing:
    ///
    /// * **Single-flight.** `openInFlight` is assigned before this method ever
    ///   suspends, so a hundred concurrent first operations find the same task
    ///   rather than starting a hundred opens.
    /// * **Off the caller's executor.** The open is a blocking SQLite call; a
    ///   detached task keeps it off whichever actor asked first, including the
    ///   main one.
    /// * **Cancellation-proof.** The task is detached and non-throwing, so a
    ///   cancelled first caller cannot cancel the open every other caller is
    ///   waiting on — the handle survives its first user.
    /// Build 273 (A15) — whether a live (not dead-lettered) row already waits
    /// under `idempotencyKey`. One additive lookup; the HealthKit stats
    /// coordinator asks before it re-enqueues a re-planned chunk.
    public func hasLiveOperation(idempotencyKey: String) async -> Bool {
        do {
            return try await resolvedStore().snapshot()
                .contains { $0.idempotencyKey == idempotencyKey && !$0.deadLettered }
        } catch {
            return false
        }
    }

    private func resolvedStore() async -> OutboxStore {
        if let openedStore { return openedStore }
        if let openInFlight { return await openInFlight.value }
        let open = openStore
        let opening = Task.detached(priority: .userInitiated) {
            OutboxStore(modelContainer: open().container)
        }
        openInFlight = opening
        let resolved = await opening.value
        openedStore = resolved
        openInFlight = nil
        return resolved
    }

    /// Live Keychain read for the signed-in user-id. A `nil` (signed-out at
    /// enqueue time — e.g. a queued write the moment a 401 logout fires) is a
    /// valid stamp: replay treats it as current-user-owned only while still
    /// `nil`, and a real user-id is re-stamped on the next same-user enqueue.
    public static let defaultOwnerProvider: @Sendable () -> String? = ownerProvider(keychain: KeychainStore())

    /// Build 273 (sync audit A2) — the live signed-in user, or, while no user
    /// is signed in, the user the last credential wipe signed out
    /// (`KeychainKey.lastSessionUserID`). The only enqueue that can happen
    /// while signed out is the one whose request *caused* the sign-out (a
    /// terminal 401 wipes the id before the repository's catch enqueues), and
    /// that write belongs to the user who was signed in when it was made.
    public static func ownerProvider(keychain: KeychainStoring) -> @Sendable () -> String? {
        let keychain = keychain
        return {
            keychain.getString(forKey: KeychainKey.userID)
                ?? keychain.getString(forKey: KeychainKey.lastSessionUserID)
        }
    }

    /// Live Keychain read for the access-token generation paired with
    /// ``defaultOwnerProvider``. The token remains memory-only.
    public static let defaultAuthTokenProvider: @Sendable () -> String? = {
        KeychainStore().getString(forKey: KeychainKey.authToken)
    }

    /// Production entry point. **Opens nothing.** The returned queue runs the
    /// G-9 ladder — try the persistent store; on failure classify it and recover
    /// **without destroying un-synced writes on a merely-transient failure** —
    /// exactly once, on first use. The ladder itself lives in
    /// `OutboxQueue+WriteAhead.swift` (file_length discipline).
    ///
    /// Build 274 (public #4) — this factory serves the App-Intent stack in BOTH
    /// processes (`IntentDependencies`), and the widget extension may not touch
    /// `UIApplication`, so it keeps the unconditional lease. The queue that
    /// carries the HealthKit observer wake — the one build 271 died on — is the
    /// app-process queue built in `AppContainer.makeCoreInfra`, and that one is
    /// handed a `UIKitBackgroundExecutionLease`.
    public static func makeWithRecovery() -> OutboxQueue {
        deferred { recoverOrDegradeStore() }
    }

    /// Test-only: thread a deterministic / fault-injection cipher down to the
    /// backing `OutboxStore`. Production callers leave the default cipher in
    /// place. Used by the write-path durability tests to force `enqueue` to fail
    /// (a cipher whose key-fetch throws makes `encrypt` — and therefore the
    /// persisting `save()` — throw) without a real Keychain.
    func useCipher(_ cipher: OutboxPayloadCipher) async {
        await resolvedStore().useCipher(cipher)
    }

    public var snapshot: [Operation] {
        get async {
            do {
                let rows = try await resolvedStore().snapshot()
                return rows.map(Operation.init(from:))
            } catch {
                HLLog.outbox.warning("Outbox snapshot fetch failed: \(LogSanitizer.redact(String(describing: error)))")
                return []
            }
        }
    }

    /// b177 W-SYNCPROGRESS — read-only backlog count for sync-progress
    /// surfaces. One snapshot fetch; callers needing LIVE counts subscribe to
    /// `changes` and read `ops.count` instead.
    public var pendingCount: Int {
        get async { await snapshot.count }
    }

    public var changes: AsyncStream<[Operation]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Operation].self)
        let id = UUID()
        // Task inherits the actor's isolation, so `register` runs on this actor —
        // no extra await hop needed.
        Task { await register(id: id, continuation: continuation) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func register(id: UUID, continuation: AsyncStream<[Operation]>.Continuation) async {
        continuations[id] = continuation
        let snap = await snapshot
        continuation.yield(snap)
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    public func enqueue(_ op: Operation) async throws {
        // v0.13 WS — stamp the owning user-id from the single chokepoint so
        // every repository enqueue site is covered without per-call plumbing.
        // A caller that already set `ownerUserID` (tests) wins; otherwise we
        // resolve the live signed-in user.
        let owner = op.ownerUserID ?? currentOwnerProvider()
        try await persist(op, ownerUserID: owner)
    }

    /// Persists a write only while the explicitly captured owner still owns
    /// the authenticated session. Long-running account-bound work uses this
    /// path so a failure that resumes after A→B cannot be stamped as B.
    public func enqueue(
        _ op: Operation,
        requiringCurrentOwner ownerUserID: String
    ) async throws {
        let lease = try captureAuthLease(requiringOwner: ownerUserID)
        try await enqueue(op, requiring: lease)
    }

    /// Persists under an already-captured authenticated session generation.
    /// Long-running work must carry this lease across suspension rather than
    /// re-resolving a same-looking userID against a replacement bearer.
    public func enqueue(_ op: Operation, requiring lease: AuthLease) async throws {
        try validateAuthLease(lease)
        guard Self.canonicalOwner(op.ownerUserID) == lease.ownerUserID else {
            throw OwnerLeaseError.staleOwner
        }
        try await persist(op, ownerUserID: lease.ownerUserID)
    }

    /// Captures the current authenticated owner + access-token generation.
    /// Fails closed if logout has removed the bearer but the userID write has
    /// not yet completed.
    public func captureAuthLease(requiringOwner ownerUserID: String) throws -> AuthLease {
        let owner = Self.canonicalOwner(ownerUserID)
        let liveOwner = Self.canonicalOwner(currentOwnerProvider())
        let bearer = Self.canonicalToken(currentAuthTokenProvider())
        if allowsUnauthenticatedTestLease {
            // An in-memory fixture must not inherit whichever real app user is
            // still present in the simulator Keychain. The explicit owner
            // argument is the fixture's isolated account boundary.
            guard !owner.isEmpty else {
                throw OwnerLeaseError.staleOwner
            }
            return AuthLease(
                ownerUserID: owner,
                bearerToken: "",
                validatesCredentialGeneration: false
            )
        }
        guard !owner.isEmpty, owner == liveOwner, !bearer.isEmpty else {
            throw OwnerLeaseError.staleOwner
        }
        return AuthLease(
            ownerUserID: owner,
            bearerToken: bearer,
            validatesCredentialGeneration: true
        )
    }

    /// Revalidates owner and credential generation after every suspension
    /// boundary that precedes a wire call, cache mutation, or row removal.
    public func validateAuthLease(_ lease: AuthLease) throws {
        if !lease.validatesCredentialGeneration {
            guard allowsUnauthenticatedTestLease else {
                throw OwnerLeaseError.staleOwner
            }
            return
        }
        guard Self.canonicalOwner(currentOwnerProvider()) == lease.ownerUserID,
              Self.canonicalToken(currentAuthTokenProvider()) == lease.bearerToken else
        {
            throw OwnerLeaseError.staleOwner
        }
    }

    /// Build 274 (public #4) — the single write chokepoint into the app-group
    /// store. The save runs inside a background-execution lease; when the system
    /// grants no time the row is NOT written and the call throws, which every
    /// caller already treats as "not persisted" (the health-sync path holds its
    /// page and re-collects on the next wake).
    private func persist(_ op: Operation, ownerUserID: String?) async throws {
        // Phase 07 — the forward-compatibility sentinel is a *read* shape. It
        // must never reach disk, or a later build would replay a row whose real
        // contract this build had already overwritten.
        guard op.kind != .unrecognized else {
            throw HLError.unknown("refusing to persist the unrecognized-kind sentinel")
        }
        let store = await resolvedStore()
        let id = op.id, kindRaw = op.kind.rawValue, payload = op.payload
        let idempotencyKey = op.idempotencyKey, createdAt = op.createdAt, attempts = op.attempts
        let clientEntityId = op.clientEntityId
        // Build 274 (public #4) — the store lives in the app-group container;
        // a SQLite lock held across a suspension is a RunningBoard kill.
        let persisted: Void? = try await backgroundLease.withLease(named: "outbox.persist") {
            try await store.enqueue(
                id: id,
                kindRaw: kindRaw,
                payload: payload,
                idempotencyKey: idempotencyKey,
                createdAt: createdAt,
                attempts: attempts,
                ownerUserID: ownerUserID,
                clientEntityId: clientEntityId
            )
        }
        guard persisted != nil else {
            throw HLError.unknown("outbox write held: no background execution time granted")
        }
        await broadcast()
    }

    private nonisolated static func canonicalOwner(_ ownerUserID: String?) -> String {
        ownerUserID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private nonisolated static func canonicalToken(_ token: String?) -> String {
        token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func remove(id: UUID) async throws {
        try await resolvedStore().delete(id: id)
        await broadcast()
    }

    public func incrementAttempts(id: UUID, lastError: String? = nil) async throws {
        try await resolvedStore().incrementAttempts(id: id, lastError: lastError)
        await broadcast()
    }

    /// audit-v0162 H1 (Opt 3) — stamp a replay attempt WITHOUT burning the
    /// attempt counter (degraded-server 5xx/429). See `OutboxStore.touchAttempt`.
    public func touchAttempt(id: UUID, lastError: String? = nil) async throws {
        try await resolvedStore().touchAttempt(id: id, lastError: lastError)
        await broadcast()
    }

    /// audit-v0162 H-4 — remap an optimistic entity id to the server id on every
    /// sibling row once the create lands. Returns the number of rows rewritten.
    @discardableResult
    public func applyEntityRemap(from optimisticId: String, to serverId: String) async throws -> Int {
        let n = try await resolvedStore().applyEntityRemap(from: optimisticId, to: serverId)
        if n > 0 { await broadcast() }
        return n
    }

    /// Drops every row in the outbox. Account-deletion cascade calls this so
    /// pending POSTs from the deleted account never replay into the next
    /// login. Errors are logged + swallowed — failure to clear the outbox
    /// must not block the deletion-completion path (the Keychain wipe matters
    /// more for the security-critical wipe contract).
    public func clearAll() async {
        do {
            try await resolvedStore().deleteAll()
            await broadcast()
        } catch {
            HLLog.outbox.error("Outbox clearAll failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }

    /// **audit-v0162 H1 (Opt 3 + Opt 1) — gated dead-lettering.** Flags (never
    /// deletes) rows that have BOTH exhausted their retry budget
    /// (`attempts >= maxAttempts`) AND aged past `minAge` wall-clock seconds.
    /// Flagged rows stay on disk (recoverable via ``resubmitDeadLetter(id:)``)
    /// but drop out of the replay snapshot. Returns the rows NEWLY dead-lettered
    /// by this call so `OutboxReplayService` can log + surface an honest failure.
    public func markDeadLetters(maxAttempts: Int, minAge: TimeInterval, now: Date = .now) async throws -> [Operation] {
        let dropped = try await resolvedStore()
            .markDeadLetters(maxAttempts: maxAttempts, minAge: minAge, now: now)
        if !dropped.isEmpty { await broadcast() }
        return dropped.map(Operation.init(from:))
    }

    /// audit-v0162 H1 (Opt 1) — count of recoverable dead-lettered rows.
    public var deadLetterCount: Int {
        get async { await (try? resolvedStore().deadLetterCount()) ?? 0 }
    }

    /// audit-v0162 H1 (Opt 1) — every dead-lettered row (for a re-submit surface).
    public var deadLetteredOperations: [Operation] {
        get async { await ((try? resolvedStore().deadLetteredSnapshots()) ?? []).map(Operation.init(from:)) }
    }

    /// audit-v0162 H1 (Opt 1) — manual re-submit: clears the dead-letter flag +
    /// resets the retry budget so the next replay pass re-attempts the row.
    /// Returns `true` when a matching dead-lettered row was re-armed.
    @discardableResult
    public func resubmitDeadLetter(id: UUID) async throws -> Bool {
        let ok = try await resolvedStore().resubmit(id: id)
        if ok { await broadcast() }
        return ok
    }

    private func broadcast() async {
        let snap = await snapshot
        for c in continuations.values {
            c.yield(snap)
        }
    }
}

private extension OutboxQueue.Operation {
    init(from snap: OutboxOperationSnapshot) {
        // `kindRaw` came from `Kind.rawValue` at enqueue time. Forward-compat:
        // a Kind we don't recognize means a future build wrote it. Phase 07
        // routes it to the dedicated `.unrecognized` sentinel — the row is
        // quarantined (retained, never transmitted, never deleted) and its real
        // `kindRaw` stays on disk for the build that can name it.
        let kind = OutboxQueue.Operation.Kind(rawValue: snap.kindRaw) ?? .unrecognized
        self.init(
            id: snap.id,
            kind: kind,
            payload: snap.payload,
            idempotencyKey: snap.idempotencyKey,
            createdAt: snap.createdAt,
            attempts: snap.attempts,
            lastAttemptAt: snap.lastAttemptAt,
            ownerUserID: snap.ownerUserID,
            clientEntityId: snap.clientEntityId
        )
    }
}
