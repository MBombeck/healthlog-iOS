import Foundation
import Observation

/// The quick log's timer: when the seizure began, the type picked for it,
/// the rescue doses stamped while it ran and, once stop was pressed, when it
/// ended. Kept on disk by ``SeizureTimerStore`` with every change, so it
/// survives leaving the page, an app switch and the app being ended. The
/// idempotency key stays with it until the server has the seizure, and from
/// the first stop on the body is frozen: every retry sends the same duration
/// under the same key, so the seizure lands exactly once and as timed.
public struct SeizureTimerState: Sendable, Equatable, Codable {
    public let startedAt: Date
    public var typeProfileId: String?
    public var rescue: [SeizureRescueDoseCreate]
    public let idempotencyKey: IdempotencyKey
    /// Set by the first stop and never moved again.
    public var stoppedAt: Date?

    public init(
        startedAt: Date,
        typeProfileId: String?,
        rescue: [SeizureRescueDoseCreate] = [],
        idempotencyKey: IdempotencyKey = IdempotencyKey(),
        stoppedAt: Date? = nil
    ) {
        self.startedAt = startedAt
        self.typeProfileId = typeProfileId
        self.rescue = rescue
        self.idempotencyKey = idempotencyKey
        self.stoppedAt = stoppedAt
    }

    /// `false` once stop was pressed, also while the save still waits.
    public var isRunning: Bool {
        stoppedAt == nil
    }

    /// Whole seconds from the start to `now`, or to the stop once there was
    /// one; never below zero.
    public func elapsed(at now: Date) -> Int {
        let end = stoppedAt.map { min($0, now) } ?? now
        return max(0, Int(end.timeIntervalSince(startedAt).rounded(.down)))
    }

    /// The seizure the stop sends: the exact start, the timed duration (at
    /// least one second), witnessed because somebody ran the timer, and the
    /// doses given while it ran. A stopped timer ignores `now` and sends its
    /// own end.
    public func write(stoppedAt now: Date) -> SeizureEventWrite {
        let end = stoppedAt ?? now
        return SeizureEventWrite(
            mode: .create,
            typeProfileId: typeProfileId,
            onsetAt: SeizureDateFormat.wire(startedAt),
            onsetPrecision: .exact,
            durationSec: max(1, Int(end.timeIntervalSince(startedAt).rounded())),
            durationSource: .timed,
            witnessed: true,
            rescueDoses: rescue
        )
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt, typeProfileId, rescue, idempotencyKey, stoppedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        typeProfileId = try c.decodeIfPresent(String.self, forKey: .typeProfileId)
        rescue = try c.decodeIfPresent([SeizureRescueDoseCreate].self, forKey: .rescue) ?? []
        idempotencyKey = try IdempotencyKey(raw: c.decode(String.self, forKey: .idempotencyKey))
        stoppedAt = try c.decodeIfPresent(Date.self, forKey: .stoppedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(typeProfileId, forKey: .typeProfileId)
        try c.encode(rescue, forKey: .rescue)
        try c.encode(idempotencyKey.raw, forKey: .idempotencyKey)
        try c.encodeIfPresent(stoppedAt, forKey: .stoppedAt)
    }
}

/// Where the running timer lives between launches: one small file in
/// Application Support, written with every change under the protection the
/// app's other local health records use
/// (`completeUntilFirstUserAuthentication`), kept out of the backup and
/// removed when the timer ends, is discarded or the account signs out.
struct SeizureTimerStore: Sendable {
    let url: URL?

    static var standard: SeizureTimerStore {
        SeizureTimerStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HealthLog", isDirectory: true)
            .appendingPathComponent("seizure-timer.json", isDirectory: false))
    }

    /// The stored timer; a missing or unreadable file reads as none.
    func load() -> SeizureTimerState? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SeizureTimerState.self, from: data)
    }

    func save(_ state: SeizureTimerState?) {
        guard let url else { return }
        guard let state else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url
            try? target.setResourceValues(values)
        } catch {
            HLLog.ui.error("Seizure timer could not be kept on disk")
        }
    }
}

/// `@MainActor @Observable` store of the seizure diary (server v1.48.0,
/// #182 A4). Loads the whole diary in one read, runs the quick-log timer
/// and sends every write through ``SeizuresRepository``. The counts, the
/// cluster episodes and the thresholds are the server's; nothing here
/// recounts them.
@MainActor
@Observable
public final class SeizuresStore {
    public private(set) var diary: SeizureDiaryDTO?
    public private(set) var isLoading = false
    /// A `403 seizures.disabled`: the module is off for this record.
    public private(set) var isDisabled = false
    public private(set) var lastError: String?
    /// The quick-log timer, `nil` while none runs. A stopped timer whose
    /// save still waits stays here, frozen at its stop.
    public private(set) var timer: SeizureTimerState?
    /// The seizure the last stop recorded, for "Add details".
    public private(set) var lastRecorded: SeizureEventDTO?
    /// The type the quick log offers next: the one of the newest seizure.
    public private(set) var pickedTypeId: String?

    private let repository: SeizuresRepository
    private let timerStore: SeizureTimerStore
    private var generation = 0

    /// Picks up a timer the app was ended with.
    init(repository: SeizuresRepository, timerStore: SeizureTimerStore) {
        self.repository = repository
        self.timerStore = timerStore
        timer = timerStore.load()
    }

    public convenience init(repository: SeizuresRepository) {
        self.init(repository: repository, timerStore: .standard)
    }

    // MARK: - Read

    public func load() async {
        let started = generation
        isLoading = true
        defer { if started == generation { isLoading = false } }
        do {
            let fresh = try await repository.diary()
            guard started == generation else { return }
            apply(fresh)
            isDisabled = false
            lastError = nil
        } catch {
            guard started == generation else { return }
            applyError(error)
        }
    }

    public var types: [SeizureTypeDTO] {
        diary?.activeTypes ?? []
    }

    // MARK: - Quick log

    public func startTimer(at now: Date = .now) {
        guard timer == nil else { return }
        lastRecorded = nil
        keep(SeizureTimerState(startedAt: now, typeProfileId: pickedTypeId))
    }

    /// Picks the type; a running timer takes it over, a stopped one keeps
    /// the body its stop froze.
    public func pick(typeId: String?) {
        pickedTypeId = typeId
        guard var running = timer, running.isRunning else { return }
        running.typeProfileId = typeId
        keep(running)
    }

    /// Stamps a dose of the type's rescue drug at `now`, as the plan names it.
    public func stampRescue(at now: Date = .now) {
        guard var running = timer, running.isRunning, running.rescue.count < SeizureEventWrite.maxRescueDoses,
              let type = diary?.type(id: running.typeProfileId), type.hasRescueMedication else { return }
        running.rescue.append(.fromPlan(type, givenAt: now))
        keep(running)
    }

    /// Nothing is recorded and the start time is lost.
    public func discardTimer() {
        keep(nil)
    }

    /// Sends the timed seizure. The first stop freezes the end; on a failure
    /// the timer stays, stopped, with its start, its end and its key, so a
    /// retry sends the very same seizure and it lands once.
    @discardableResult
    public func stopTimer(at now: Date = .now) async -> SeizureEventDTO? {
        guard var running = timer else { return nil }
        if running.isRunning {
            running.stoppedAt = now
            keep(running)
        }
        let started = generation
        do {
            let event = try await repository.createEvent(running.write(stoppedAt: now), idempotencyKey: running.idempotencyKey)
            guard started == generation else { return nil }
            keep(nil)
            lastRecorded = event
            lastError = nil
            await load()
            return event
        } catch {
            guard started == generation else { return nil }
            applyError(error)
            return nil
        }
    }

    public func dismissRecorded() {
        lastRecorded = nil
    }

    // MARK: - Events

    @discardableResult
    public func create(_ write: SeizureEventWrite, idempotencyKey: IdempotencyKey) async -> SeizureEventDTO? {
        await mutate { try await self.repository.createEvent(write, idempotencyKey: idempotencyKey) }
    }

    @discardableResult
    public func update(id: String, _ write: SeizureEventWrite) async -> SeizureEventDTO? {
        await mutate { try await self.repository.updateEvent(id: id, write) }
    }

    @discardableResult
    public func delete(_ event: SeizureEventDTO) async -> Bool {
        await mutate { try await self.repository.deleteEvent(id: event.id) } != nil
    }

    public func event(id: String) -> SeizureEventDTO? {
        diary?.events.first { $0.id == id }
    }

    // MARK: - Rescue doses

    @discardableResult
    public func addRescueDose(
        eventId: String,
        _ body: SeizureRescueDoseCreate,
        idempotencyKey: IdempotencyKey
    ) async -> SeizureRescueDoseDTO? {
        await mutate { try await self.repository.addRescueDose(eventId: eventId, body, idempotencyKey: idempotencyKey) }
    }

    @discardableResult
    public func setRescueEffect(_ effect: SeizureRescueEffect, dose: SeizureRescueDoseDTO) async -> Bool {
        await mutate {
            try await self.repository.updateRescueDose(
                eventId: dose.eventId, doseId: dose.id, SeizureRescueDosePatch(effect: effect)
            )
        } != nil
    }

    @discardableResult
    public func deleteRescueDose(_ dose: SeizureRescueDoseDTO) async -> Bool {
        await mutate { try await self.repository.deleteRescueDose(eventId: dose.eventId, doseId: dose.id) } != nil
    }

    // MARK: - Types and rule

    @discardableResult
    public func createType(_ write: SeizureTypeWrite) async -> SeizureTypeDTO? {
        await mutate { try await self.repository.createType(write) }
    }

    @discardableResult
    public func updateType(id: String, _ write: SeizureTypeWrite) async -> SeizureTypeDTO? {
        await mutate { try await self.repository.updateType(id: id, write) }
    }

    /// `false` with ``lastError`` set when the type still names seizures.
    @discardableResult
    public func deleteType(_ type: SeizureTypeDTO) async -> Bool {
        await mutate { try await self.repository.deleteType(id: type.id) } != nil
    }

    @discardableResult
    public func updateRule(_ rule: SeizureClusterRule) async -> Bool {
        await mutate { try await self.repository.updateSettings(rule) } != nil
    }

    // MARK: - Logout

    public func clearOnLogout() {
        generation += 1
        diary = nil
        isLoading = false
        isDisabled = false
        lastError = nil
        keep(nil)
        lastRecorded = nil
        pickedTypeId = nil
    }

    /// Test seam: a diary without a request.
    func seedForTesting(_ diary: SeizureDiaryDTO) {
        apply(diary)
    }

    // MARK: - Private

    /// Every change of the timer goes to disk with it.
    private func keep(_ state: SeizureTimerState?) {
        timer = state
        timerStore.save(state)
    }

    /// One write, then the whole diary again (the summary and the clusters
    /// are the server's and change with every write). `nil` on a failure,
    /// with the sentence in ``lastError``.
    private func mutate<Value: Sendable>(_ write: @escaping @Sendable () async throws -> Value) async -> Value? {
        let started = generation
        do {
            let value = try await write()
            guard started == generation else { return nil }
            lastError = nil
            await load()
            return value
        } catch {
            guard started == generation else { return nil }
            applyError(error)
            return nil
        }
    }

    private func apply(_ fresh: SeizureDiaryDTO) {
        diary = fresh
        let active = fresh.activeTypes
        if let picked = pickedTypeId, active.contains(where: { $0.id == picked }) { return }
        let newest = fresh.events.first { event in active.contains { $0.id == event.typeProfileId } }?.typeProfileId
        pickedTypeId = newest ?? active.first?.id
    }

    private func applyError(_ error: Error) {
        if SeizuresRepository.isSeizuresDisabled(error) {
            isDisabled = true
            diary = nil
            lastError = nil
            return
        }
        HLLog.ui.error("Seizure diary request failed: \(LogSanitizer.redact(String(describing: error)))")
        lastError = SeizureErrorWording.sentence(for: error)
    }
}

extension SeizuresStore: LogoutClearable {}

/// The sentence a failed diary request shows.
enum SeizureErrorWording {
    static func sentence(for error: Error) -> String {
        if SeizuresRepository.isTypeInUse(error) { return String(localized: "seizures.types.inUse") }
        if SeizuresRepository.isTypeLimit(error) { return String(localized: "seizures.types.limit") }
        return HLError.userFacingText(for: error)
    }
}
