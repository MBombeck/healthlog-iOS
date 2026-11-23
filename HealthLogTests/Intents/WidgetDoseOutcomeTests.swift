import AppIntents
import Foundation
@testable import HealthLog
import Testing

/// What a "Taken" tap on the Home widget or the next-dose control did, shown
/// until the app writes a newer snapshot; and the control's freshness and slot
/// binding, the same rules the widget button already followed.
@MainActor
@Suite("Widget dose outcome and next-dose control")
struct WidgetDoseOutcomeTests {
    private let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private var slot: Date {
        generatedAt.addingTimeInterval(30 * 60)
    }

    private var dose: WidgetSnapshot.NextDose {
        WidgetSnapshot.NextDose(medicationId: "med-1", medicationName: "Vitamin D", doseText: "1000 IE", scheduledAt: slot)
    }

    private func snapshot(generatedAt: Date) -> WidgetSnapshot {
        WidgetSnapshot(nextDose: dose, compliance: .init(scheduled: 1, taken: 0), generatedAt: generatedAt)
    }

    private func outcome(_ kind: WidgetDoseOutcomeStore.Kind, at: Date, medicationId: String = "med-1") -> WidgetDoseOutcomeStore.Outcome {
        .init(medicationId: medicationId, scheduledAt: slot, kind: kind, at: at)
    }

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    // MARK: - Applicability

    @Test("an outcome after the snapshot applies to exactly its dose")
    func appliesToItsDose() {
        let later = generatedAt.addingTimeInterval(60)
        #expect(WidgetDoseOutcomeStore.applicableKind(
            outcome(.recorded, at: later),
            to: dose,
            snapshotGeneratedAt: generatedAt,
            now: later
        ) == .recorded)
        #expect(WidgetDoseOutcomeStore.applicableKind(
            outcome(.recorded, at: later, medicationId: "med-2"),
            to: dose,
            snapshotGeneratedAt: generatedAt,
            now: later
        ) == nil)
    }

    @Test("a newer snapshot is the app's answer and wins over the outcome")
    func newerSnapshotWins() {
        let tap = generatedAt.addingTimeInterval(60)
        let rewritten = generatedAt.addingTimeInterval(120)
        #expect(WidgetDoseOutcomeStore.applicableKind(
            outcome(.recorded, at: tap),
            to: dose,
            snapshotGeneratedAt: rewritten,
            now: rewritten
        ) == nil)
    }

    @Test("a not-saved note leaves after its window")
    func notSavedExpires() {
        let tap = generatedAt.addingTimeInterval(60)
        let soon = tap.addingTimeInterval(60)
        let late = tap.addingTimeInterval(WidgetDoseOutcomeStore.notSavedWindow + 1)
        #expect(WidgetDoseOutcomeStore
            .applicableKind(outcome(.notSaved, at: tap), to: dose, snapshotGeneratedAt: generatedAt, now: soon) == .notSaved)
        #expect(WidgetDoseOutcomeStore
            .applicableKind(outcome(.notSaved, at: tap), to: dose, snapshotGeneratedAt: generatedAt, now: late) == nil)
    }

    @Test("commit kinds: landed, queued, nothing saved")
    func commitKinds() {
        #expect(WidgetDoseOutcomeStore.kind(signedIn: true, error: nil) == .recorded)
        #expect(WidgetDoseOutcomeStore.kind(signedIn: true, error: HLError.offline) == .queued)
        #expect(WidgetDoseOutcomeStore.kind(signedIn: true, error: HLError.server(status: 422, code: "x", message: "no")) == .notSaved)
        #expect(WidgetDoseOutcomeStore.kind(signedIn: false, error: nil) == .notSaved)
    }

    @Test("the store round-trips an outcome")
    func storeRoundTrip() {
        let url = tempURL("dose-outcome")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetDoseOutcomeStore(url: url)
        store.record(medicationId: "med-1", scheduledFor: slot, kind: .queued, now: generatedAt)
        #expect(store.read() == outcome(.queued, at: generatedAt))
        store.clear()
        #expect(store.read() == nil)
    }

    // MARK: - Control decision

    @Test("a snapshot older than the widget's cutoff records nothing")
    func staleSnapshot() {
        let now = generatedAt.addingTimeInterval(WidgetTimelinePolicy.nextDoseStaleThreshold + 60)
        #expect(MarkNextDoseTakenIntent.decide(snapshot: snapshot(generatedAt: generatedAt), outcome: nil, now: now) == .stale)
    }

    @Test("a fresh snapshot records its dose, on its slot")
    func freshRecords() {
        let now = generatedAt.addingTimeInterval(60)
        #expect(MarkNextDoseTakenIntent.decide(snapshot: snapshot(generatedAt: generatedAt), outcome: nil, now: now) == .record(dose))
    }

    @Test("a slot a tap already saved is not recorded a second time")
    func alreadyRecorded() {
        let tap = generatedAt.addingTimeInterval(60)
        let now = tap.addingTimeInterval(60)
        #expect(MarkNextDoseTakenIntent.decide(
            snapshot: snapshot(generatedAt: generatedAt),
            outcome: outcome(.recorded, at: tap),
            now: now
        ) == .alreadyRecorded)
        #expect(MarkNextDoseTakenIntent
            .decide(snapshot: snapshot(generatedAt: generatedAt), outcome: outcome(.queued, at: tap), now: now) == .alreadyRecorded)
        #expect(MarkNextDoseTakenIntent.decide(
            snapshot: snapshot(generatedAt: generatedAt),
            outcome: outcome(.notSaved, at: tap),
            now: now
        ) == .record(dose))
    }

    @Test("no snapshot or no dose → nothing to record")
    func noDose() {
        #expect(MarkNextDoseTakenIntent.decide(snapshot: nil, outcome: nil, now: generatedAt) == .noDose)
    }

    // MARK: - Intents end to end

    @Test("control on a stale snapshot sends nothing")
    func controlStaleSendsNothing() async throws {
        let api = try installOverride(signedIn: true)
        let snapshotURL = tempURL("snapshot")
        let outcomeURL = tempURL("outcome")
        defer {
            clearOverrides()
            try? FileManager.default.removeItem(at: snapshotURL)
            try? FileManager.default.removeItem(at: outcomeURL)
        }
        let snapshots = WidgetSnapshotStore(url: snapshotURL)
        try snapshots.write(snapshot(generatedAt: generatedAt))
        MarkNextDoseTakenIntent.snapshotStoreOverride = snapshots
        MarkNextDoseTakenIntent.outcomeStoreOverride = WidgetDoseOutcomeStore(url: outcomeURL)
        MarkNextDoseTakenIntent.nowOverride = generatedAt.addingTimeInterval(WidgetTimelinePolicy.nextDoseStaleThreshold + 60)

        _ = try await MarkNextDoseTakenIntent().perform()

        #expect(await api.sentPaths.isEmpty)
        #expect(WidgetDoseOutcomeStore(url: outcomeURL).read() == nil)
    }

    @Test("control on a fresh snapshot records once and notes the outcome; a second tap sends nothing")
    func controlRecordsOnce() async throws {
        let api = try installOverride(signedIn: true)
        let snapshotURL = tempURL("snapshot")
        let outcomeURL = tempURL("outcome")
        defer {
            clearOverrides()
            try? FileManager.default.removeItem(at: snapshotURL)
            try? FileManager.default.removeItem(at: outcomeURL)
        }
        let snapshots = WidgetSnapshotStore(url: snapshotURL)
        try snapshots.write(snapshot(generatedAt: generatedAt))
        MarkNextDoseTakenIntent.snapshotStoreOverride = snapshots
        MarkNextDoseTakenIntent.outcomeStoreOverride = WidgetDoseOutcomeStore(url: outcomeURL)
        MarkNextDoseTakenIntent.nowOverride = generatedAt.addingTimeInterval(60)

        _ = try await MarkNextDoseTakenIntent().perform()
        MarkNextDoseTakenIntent.nowOverride = generatedAt.addingTimeInterval(120)
        _ = try await MarkNextDoseTakenIntent().perform()

        #expect(await api.sentPaths == ["/api/medications/intake/bulk"])
        let noted = WidgetDoseOutcomeStore(url: outcomeURL).read()
        #expect(noted?.kind == .recorded)
        #expect(noted?.scheduledAt == slot)
    }

    @Test("widget tap notes a saved outcome; signed out notes not saved")
    func widgetNotesOutcome() async throws {
        for signedIn in [true, false] {
            _ = try installOverride(signedIn: signedIn)
            let pendingURL = tempURL("pending")
            let outcomeURL = tempURL("outcome")
            let pending = WidgetPendingConfirmStore(url: pendingURL)
            MarkNextDoseFromWidgetIntent.pendingStoreOverride = pending
            MarkNextDoseFromWidgetIntent.outcomeStoreOverride = WidgetDoseOutcomeStore(url: outcomeURL)
            MarkNextDoseFromWidgetIntent.externalTakeLogOverride = ExternalTakeLog(url: tempURL("ext"))

            _ = try await MarkNextDoseFromWidgetIntent(
                medicationId: "med-1",
                medicationName: "Vitamin D",
                scheduledForEpoch: slot.timeIntervalSince1970
            ).perform()

            #expect(WidgetDoseOutcomeStore(url: outcomeURL).read()?.kind == (signedIn ? .recorded : .notSaved))
            clearOverrides()
            try? FileManager.default.removeItem(at: pendingURL)
            try? FileManager.default.removeItem(at: outcomeURL)
        }
    }

    // MARK: - Harness

    private func installOverride(signedIn: Bool) throws -> OutcomeStubAPIClient {
        let keychain = InMemoryKeychain()
        if signedIn {
            try keychain.setString("test-bearer", forKey: KeychainKey.authToken)
        }
        let api = OutcomeStubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        IntentDependencies.testOverride = IntentDependencies.Resolved(
            keychain: keychain,
            api: api,
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox)
        )
        return api
    }

    private func clearOverrides() {
        IntentDependencies.testOverride = nil
        MarkNextDoseTakenIntent.snapshotStoreOverride = nil
        MarkNextDoseTakenIntent.outcomeStoreOverride = nil
        MarkNextDoseTakenIntent.nowOverride = nil
        MarkNextDoseFromWidgetIntent.pendingStoreOverride = nil
        MarkNextDoseFromWidgetIntent.externalTakeLogOverride = nil
        MarkNextDoseFromWidgetIntent.outcomeStoreOverride = nil
    }
}

/// Records the paths it was asked to POST and answers the bulk intake route.
private actor OutcomeStubAPIClient: APIClientProtocol {
    private(set) var sentPaths: [String] = []

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        sentPaths.append(request.path)
        let json = """
        {"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"taken","id":"i-1","reason":null}]}
        """
        return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        sentPaths.append(request.path)
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("download not stubbed")
    }
}
