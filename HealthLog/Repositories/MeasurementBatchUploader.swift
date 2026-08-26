import Foundation

/// Current account credentials used to create an ephemeral measurement-upload
/// lease. Values are read from Keychain at the composition boundary and are
/// never persisted or logged by the uploader.
public struct MeasurementUploadAuthenticationSnapshot: Sendable, Equatable {
    public let ownerUserID: String?
    public let bearerToken: String?

    public init(ownerUserID: String?, bearerToken: String?) {
        self.ownerUserID = ownerUserID
        self.bearerToken = bearerToken
    }
}

/// Owner + bearer generation captured for one HealthKit measurement delivery.
/// The explicit bearer prevents account-A HealthKit rows from inheriting
/// account B's ambient APIClient credential after an async boundary.
struct MeasurementUploadAuthenticationLease: Sendable {
    enum ValidationError: Error, Sendable {
        case unavailableAuthentication
        case staleAuthentication
    }

    let ownerUserID: String
    private let bearerToken: String
    private let isCurrentProvider: @Sendable () -> Bool

    init(
        ownerUserID: String,
        bearerToken: String,
        isCurrent: @escaping @Sendable () -> Bool
    ) {
        self.ownerUserID = ownerUserID
        self.bearerToken = bearerToken
        isCurrentProvider = isCurrent
    }

    var authorizationHeader: String {
        "Bearer \(bearerToken)"
    }

    func validate() throws {
        guard !Task.isCancelled, isCurrentProvider() else {
            throw ValidationError.staleAuthentication
        }
    }
}

/// Actor, der HK-Samples über `POST /api/measurements/batch` an den Server pumpt.
///
/// **Contract** (siehe `08-locked-contracts.md §2.1` + `03-api-contracts.md`):
/// - Body: `{ entries: [HealthKitBatchEntryDTO] }`, max 500 Entries.
/// - Header: `Idempotency-Key: <UUIDv4>` pro Batch (24h replay-window).
/// - Antwort: `{ processed, inserted, duplicates, skipped[], entries[] }`.
/// - Cursor-Advance: entscheidet ausschliesslich ``MeasurementBatchAcceptance``
///   gegen ``MeasurementBatchAcceptance/Policy/deployedMeasurementRoute`` — exakt
///   pro Index und reason-aware. HTTP 200 allein bewegt keinen Cursor.
/// - Server-Limit: 60 Batches/min/User → wir pacen via `BatchSyncThrottle`.
///
/// `upload(_:)` chunked große Einträge automatisch in 500er-Batches. Returns
/// die Liste der `BatchUploadOutcome` pro chunk — der Caller kann daraus die
/// "successfully consumed external IDs" zusammensetzen (z. B. `outcome.successfulExternalIds`),
/// um seinen lokalen HK-Anchor entsprechend voranzuschieben.
public actor MeasurementBatchUploader {
    public static let maxEntriesPerBatch = 500

    private let api: APIClientProtocol
    private let throttle: BatchSyncThrottle
    private let encoder: JSONEncoder
    private let clock: @Sendable () -> Date
    private let authenticationSnapshot: (@Sendable () -> MeasurementUploadAuthenticationSnapshot)?
    /// CU-21 (1) — Quelle des `syncTrigger`-Feldes. Injizierbar, damit Tests
    /// einen isolierten Kontext fahren können statt den prozessweiten zu
    /// verbiegen.
    private let syncTrigger: SyncTriggerContext

    /// Optional Hook der nach jedem erfolgreichen Batch-POST aufgerufen wird —
    /// vom Composition-Root gesetzt damit `HKReadinessStore.noteSuccessfulSync`
    /// die "Zuletzt synchronisiert"-Zeit in Settings → Health aktualisieren
    /// kann (F7-Plan §5). Closure ist `@Sendable` damit sie via Actor zu
    /// `@MainActor` springen kann.
    private var successNotifier: (@Sendable (Date) async -> Void)?

    // MARK: - F8 hotfix Backoff-State (v0.4.1.1)

    /// Sliding-Window-Failure-Counter: Timestamps der letzten Failures.
    /// Wird beim ersten Success komplett geleert.
    private var recentFailures: [Date] = []
    /// Aktueller Backoff-Block bis zu diesem Zeitpunkt — alle `upload`-Calls
    /// werfen `BatchBackoffError.throttled` solange `now < blockedUntil`.
    private var blockedUntil: Date?
    /// Aktuelles Backoff-Level (Index in `Self.backoffSteps`).
    private var backoffStep: Int = 0

    /// Failure-Threshold: ab >5 Fehlern in 60 Sekunden kicked die Backoff ein.
    public static let failureWindow: TimeInterval = 60
    public static let failureThreshold: Int = 5
    /// Exponentielle Backoff-Stufen — 15s, 60s, 5min, 30min.
    public static let backoffSteps: [TimeInterval] = [15, 60, 5 * 60, 30 * 60]

    public init(
        api: APIClientProtocol,
        throttle: BatchSyncThrottle,
        encoder: JSONEncoder = .hlBatch,
        clock: @escaping @Sendable () -> Date = { Date() },
        syncTrigger: SyncTriggerContext = .shared,
        authenticationSnapshot: (@Sendable () -> MeasurementUploadAuthenticationSnapshot)? = nil
    ) {
        self.api = api
        self.throttle = throttle
        self.encoder = encoder
        self.clock = clock
        self.syncTrigger = syncTrigger
        self.authenticationSnapshot = authenticationSnapshot
    }

    /// Setter-Injection (statt Constructor-Inject), weil der Composition-Root
    /// den Uploader baut BEVOR der HKReadinessStore existiert (gleiche Reihen-
    /// folge wie `HealthKitService.setUploader`).
    public func setSuccessNotifier(_ notifier: (@Sendable (Date) async -> Void)?) {
        successNotifier = notifier
    }

    /// Sendet alle `entries` als ein oder mehrere Batches. Liefert einen Outcome
    /// pro tatsächlich abgesetztem Batch. Wirf nur wenn der Server-Call **für den
    /// aktuellen Batch** unwiederbringlich fehlschlägt — vorherige Batches in
    /// derselben `upload`-Session sind bereits durchgegangen und werden über den
    /// returned Array sichtbar.
    @discardableResult
    public func upload(_ entries: [HealthKitBatchEntryDTO]) async throws -> [BatchUploadOutcome] {
        let lease = try captureAuthenticationLeaseIfConfigured()
        return try await upload(entries, requiring: lease)
    }

    /// Captures the currently authenticated owner and exact bearer generation.
    /// Production composition always configures the snapshot provider; direct
    /// unit-test uploaders may omit it and continue using APIClient's fixture
    /// authentication path.
    func captureAuthenticationLease() throws -> MeasurementUploadAuthenticationLease {
        guard let lease = try captureAuthenticationLeaseIfConfigured() else {
            throw MeasurementUploadAuthenticationLease.ValidationError.unavailableAuthentication
        }
        return lease
    }

    func captureAuthenticationLeaseIfConfigured() throws -> MeasurementUploadAuthenticationLease? {
        guard let authenticationSnapshot else { return nil }
        let captured = authenticationSnapshot()
        let owner = Self.canonical(captured.ownerUserID)
        let bearer = Self.canonical(captured.bearerToken)
        guard !owner.isEmpty, !bearer.isEmpty else {
            throw MeasurementUploadAuthenticationLease.ValidationError.unavailableAuthentication
        }
        return MeasurementUploadAuthenticationLease(
            ownerUserID: owner,
            bearerToken: bearer,
            isCurrent: {
                let current = authenticationSnapshot()
                return Self.canonical(current.ownerUserID) == owner
                    && Self.canonical(current.bearerToken) == bearer
            }
        )
    }

    @discardableResult
    func upload(
        _ entries: [HealthKitBatchEntryDTO],
        requiring authLease: MeasurementUploadAuthenticationLease?
    ) async throws -> [BatchUploadOutcome] {
        guard !entries.isEmpty else { return [] }
        try authLease?.validate()
        // F8 hotfix: kurzer Pre-Flight-Check — wenn wir gerade in einem
        // Backoff-Block stehen, gar nicht erst die Server-Call ausloesen.
        try checkBackoff()

        var outcomes: [BatchUploadOutcome] = []

        for chunk in entries.chunks(of: Self.maxEntriesPerBatch) {
            try await throttle.acquire()
            try authLease?.validate()

            // CU-21 (1): der tatsächliche Auslöser DIESES Sweeps. Nicht geraten —
            // `SyncTriggerContext` trägt das Fenster, das der auslösende Pfad
            // (BGProcessing / BGAppRefresh / Silent-Push / HK-Background-
            // Delivery) um seine Arbeit gelegt hat; ohne offenes Fenster ist der
            // Sweep per Restmenge ein Vordergrund-Pull.
            let payload = HealthKitBatchPayload(entries: chunk, syncTrigger: syncTrigger.current)
            let base: APIRequest<HealthKitBatchResponseDTO> = try .post(
                "/api/measurements/batch",
                body: payload,
                encoder: encoder,
                idempotencyKey: IdempotencyKey()
            )
            let req = APIRequest<HealthKitBatchResponseDTO>(
                method: base.method,
                path: base.path,
                query: base.query,
                body: base.body,
                extraHeaders: authLease.map { ["Authorization": $0.authorizationHeader] } ?? base.extraHeaders,
                idempotencyKey: base.idempotencyKey,
                maxRetries: authLease == nil ? base.maxRetries : 0,
                failFast: base.failFast,
                streaming: base.streaming,
                allowsAuthenticationRecovery: authLease == nil
            )
            do {
                let response = try await api.send(req)
                try authLease?.validate()
                // The submitted external ids travel with the count: they are what
                // makes `superseded_in_batch` verifiable rather than assumed.
                try MeasurementBatchAcceptance.validate(
                    postedCount: chunk.count,
                    postedExternalIds: chunk.map(\.externalId),
                    response: response,
                    policy: .deployedMeasurementRoute
                )
                outcomes.append(BatchUploadOutcome(chunk: chunk, response: response))
                // First success → Backoff komplett resetten.
                resetBackoffOnSuccess()
                // 2xx ist hier garantiert — `api.send` würde sonst geworfen haben.
                // Notifier feuert pro erfolgreichem Chunk: der "Zuletzt synchroni-
                // siert"-Surface soll Live-Updates während eines grossen Backfills
                // zeigen, nicht erst nach 1200 Samples.
                if let notifier = successNotifier {
                    await notifier(Date())
                }
            } catch {
                try authLease?.validate()
                noteFailure()
                throw error
            }
        }
        try authLease?.validate()
        return outcomes
    }

    private nonisolated static func canonical(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - F8 hotfix Backoff (v0.4.1.1)

    /// Pre-Flight-Check — wirft `BatchBackoffError.throttled` wenn die Uploader
    /// noch in einem Backoff-Block steht.
    private func checkBackoff() throws {
        if let until = blockedUntil, clock() < until {
            throw BatchBackoffError.throttled(retryAfter: until)
        }
        // Block ist abgelaufen → freischalten, naechster Aufruf darf wieder
        // versuchen.
        blockedUntil = nil
    }

    /// Wird nach jedem ersten Success aufgerufen — leert das Sliding-Window
    /// und setzt das Backoff-Level zurueck.
    private func resetBackoffOnSuccess() {
        if !recentFailures.isEmpty || backoffStep > 0 || blockedUntil != nil {
            recentFailures.removeAll()
            backoffStep = 0
            blockedUntil = nil
        }
    }

    /// Wird nach jedem geworfenen API-Call aufgerufen. Wenn die Failure-Rate
    /// im Sliding-Window die `failureThreshold` ueberschreitet, kicked die
    /// Backoff ein.
    private func noteFailure() {
        let now = clock()
        recentFailures.append(now)
        let cutoff = now.addingTimeInterval(-Self.failureWindow)
        recentFailures.removeAll(where: { $0 < cutoff })

        guard recentFailures.count > Self.failureThreshold else { return }
        let stepIndex = min(backoffStep, Self.backoffSteps.count - 1)
        let delay = Self.backoffSteps[stepIndex]
        blockedUntil = now.addingTimeInterval(delay)
        backoffStep = min(backoffStep + 1, Self.backoffSteps.count - 1)
        HLLog.api
            .warning(
                "MeasurementBatchUploader Backoff aktiv: \(recentFailures.count, privacy: .public) Fehler/\(Int(Self.failureWindow), privacy: .public)s — block \(Int(delay), privacy: .public)s"
            )
    }

    // MARK: - Test-introspection

    /// Snapshot der aktuellen Backoff-State. Nur fuer Tests, keine UI nutzt das.
    public func backoffSnapshot() -> BackoffSnapshot {
        BackoffSnapshot(
            failuresInWindow: recentFailures.count,
            blockedUntil: blockedUntil,
            step: backoffStep
        )
    }

    public struct BackoffSnapshot: Sendable, Equatable {
        public let failuresInWindow: Int
        public let blockedUntil: Date?
        public let step: Int
    }
}

/// Fehler den `MeasurementBatchUploader.upload` wirft, wenn der Backoff
/// einen Call blockt. Caller (Outbox + HK-Sweep) sollen daraus `keepAnchor`
/// machen — die Samples kommen beim naechsten Wakeup wieder.
public enum BatchBackoffError: Error, Sendable, Equatable {
    case throttled(retryAfter: Date)
}

/// Aggregiertes Ergebnis EINES POST. `chunk` ist 1:1 das Array das der Caller
/// abgeschickt hat — `response.entries` indexieren dort hinein.
public struct BatchUploadOutcome: Sendable, Equatable {
    public let chunk: [HealthKitBatchEntryDTO]
    public let response: HealthKitBatchResponseDTO

    public init(chunk: [HealthKitBatchEntryDTO], response: HealthKitBatchResponseDTO) {
        self.chunk = chunk
        self.response = response
    }

    /// Indizes (in `chunk`) deren Server-Status `inserted | duplicate | skipped`
    /// ist — alle drei Cursor-Advance-fähig (Server hat den Eintrag gesehen,
    /// retry würde am Status nichts ändern).
    ///
    /// **CU-21 (4):** die Menge ist die **Vereinigung** aus `entries[]` und
    /// `skipped[]`. Auf den Batch-Routen kommt eine per-Entry-Ablehnung (seit
    /// v1.32.37 `unstable_external_id`) als `skipped`-Eintrag zurück; führte der
    /// Server ihn nicht *zusätzlich* in `entries[]`, bliebe sein Index ohne die
    /// Vereinigung ewig unverbraucht — und der Grund ist deterministisch, ein
    /// Retry könnte ihn nie auflösen. Reihenfolge bleibt die des Servers,
    /// Duplikate werden entfernt.
    public var consumedIndexes: [Int] {
        var seen = Set<Int>()
        return (response.entries.map(\.index) + response.skipped.map(\.index))
            .filter { seen.insert($0).inserted }
    }

    /// Externe IDs die der Caller in seinem HK-Anchor / Outbox-Cursor advance'n
    /// kann. Convenience oben drauf, weil iOS' Anchor letztlich auf den HK-Sample-
    /// `uuid.uuidString` zeigt — siehe `HealthKitWireConverter.entries(from:)`.
    public var successfulExternalIds: [String] {
        consumedIndexes.compactMap { idx in
            chunk.indices.contains(idx) ? chunk[idx].externalId : nil
        }
    }

    /// `skipped`-Einträge mit Reason — für Telemetrie/Triage, nicht für Cursor-
    /// Logik (die behandelt skipped wie inserted/duplicate). `unmappable_identifier`
    /// signalisiert z. B. dass Apple einen neuen Identifier eingeführt hat den
    /// der Server-Mapper noch nicht kennt.
    public var skipped: [HealthKitBatchResponseDTO.SkippedEntry] {
        response.skipped
    }
}

// MARK: - Helpers

extension Array {
    /// Chunked-Iterator. `chunks(of: 500)` liefert nicht-leere Sub-Arrays bis zur Größe 500.
    /// Internal damit der Uploader und seine Tests es nutzen können.
    func chunks(of size: Int) -> [[Element]] {
        precondition(size > 0, "chunk size must be positive")
        guard !isEmpty else { return [] }
        var result: [[Element]] = []
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            result.append(Array(self[index ..< end]))
            index = end
        }
        return result
    }
}

public extension JSONEncoder {
    /// Encoder für `POST /api/measurements/batch`. Server erwartet ISO-8601 Timestamps
    /// **mit Offset** (`z.iso.datetime({ offset: true })`) — `.iso8601`-Strategy + die
    /// SDK-Default-FormatOptions decken das ab.
    static let hlBatch: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
