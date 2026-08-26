import AppIntents
import Foundation
@testable import HealthLog
import Testing

/// **v0.10.0 W-Widget-2Tap** — coverage for the Home-screen next-dose
/// widget's two-step "Genommen" confirm.
///
/// Two load-bearing contracts, mirrored from the Live Activity:
///   1. ``WidgetPendingConfirmStore`` arm → armed → stale-revert state machine.
///   2. The intent's FIRST tap NEVER writes (only arms); the SECOND tap
///      (armed marker present) records the intake against the slot instant.
///
/// The widget intent resolves its repository stack via
/// `IntentDependencies.resolve()`, which we override with a stub `APIClient`
/// + in-memory Outbox so `perform()` runs the REAL `recordFromReminder`
/// write path without touching the network or the live Keychain.
@Suite("Widget next-dose two-step confirm")
@MainActor
struct MarkNextDoseFromWidgetIntentTests {
    // MARK: - Harness

    private func installOverride(
        signedIn: Bool,
        apiBehaviour: IntentStubAPIClient.Behaviour
    ) throws -> (api: IntentStubAPIClient, outbox: OutboxQueue) {
        let keychain = InMemoryKeychain()
        if signedIn {
            try keychain.setString("test-bearer", forKey: KeychainKey.authToken)
        }
        let api = IntentStubAPIClient(behaviour: apiBehaviour)
        let outbox = try OutboxQueue(inMemory: true)
        IntentDependencies.testOverride = IntentDependencies.Resolved(
            keychain: keychain,
            api: api,
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox)
        )
        return (api, outbox)
    }

    private func clearOverride() {
        IntentDependencies.testOverride = nil
        MarkNextDoseFromWidgetIntent.pendingStoreOverride = nil
    }

    /// A pending-confirm store backed by a throwaway temp file so each test
    /// runs isolated (never the live App Group container).
    private func tempPendingStore() -> (store: WidgetPendingConfirmStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-confirm-\(UUID().uuidString).json")
        return (WidgetPendingConfirmStore(url: url), url)
    }

    // MARK: - Store state machine

    @Test("arm then read returns the marker for the same medication")
    func storeArmAndRead() throws {
        let (store, url) = tempPendingStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let slot = Date(timeIntervalSince1970: 1_799_999_000)
        try store.arm(medicationId: "med-1", scheduledFor: slot, now: now)

        #expect(store.armed(for: "med-1", now: now))
        #expect(store.armed(for: "med-2", now: now) == false)
        #expect(store.read(now: now)?.scheduledAt == slot)
    }

    @Test("a marker older than the confirm window reads as absent (auto-revert)")
    func storeStaleReverts() throws {
        let (store, url) = tempPendingStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let armedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try store.arm(medicationId: "med-1", scheduledFor: armedAt, now: armedAt)

        // Just past the window → stale → treated as not armed.
        let later = armedAt.addingTimeInterval(WidgetPendingConfirmStore.pendingConfirmWindow + 0.1)
        #expect(store.armed(for: "med-1", now: later) == false)
        #expect(store.read(now: later) == nil)
    }

    @Test("clear removes the marker")
    func storeClear() throws {
        let (store, url) = tempPendingStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.arm(medicationId: "med-1", scheduledFor: .now)
        store.clear()
        #expect(store.read() == nil)
    }

    // MARK: - Intent two-step

    @Test("FIRST tap only arms — no POST, no Outbox write")
    func firstTapNeverWrites() async throws {
        let (api, outbox) = try installOverride(signedIn: true, apiBehaviour: .succeed)
        let (store, url) = tempPendingStore()
        MarkNextDoseFromWidgetIntent.pendingStoreOverride = store
        defer {
            clearOverride()
            try? FileManager.default.removeItem(at: url)
        }

        let slot = Date(timeIntervalSince1970: 1_799_999_000)
        let intent = MarkNextDoseFromWidgetIntent(
            medicationId: "med-1",
            medicationName: "Vitamin D",
            scheduledForEpoch: slot.timeIntervalSince1970
        )
        _ = try await intent.perform()

        // Armed, but NOTHING recorded.
        #expect(store.armed(for: "med-1"))
        #expect(await api.sentPaths.isEmpty)
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("SECOND tap (armed) records the intake and clears the marker")
    func secondTapRecords() async throws {
        let (api, outbox) = try installOverride(signedIn: true, apiBehaviour: .succeed)
        let (store, url) = tempPendingStore()
        MarkNextDoseFromWidgetIntent.pendingStoreOverride = store
        defer {
            clearOverride()
            try? FileManager.default.removeItem(at: url)
        }

        let slot = Date(timeIntervalSince1970: 1_799_999_000)
        // Pre-arm (as if the first tap landed).
        try store.arm(medicationId: "med-1", scheduledFor: slot)

        let intent = MarkNextDoseFromWidgetIntent(
            medicationId: "med-1",
            medicationName: "Vitamin D",
            scheduledForEpoch: slot.timeIntervalSince1970
        )
        _ = try await intent.perform()

        // Recorded via the bulk endpoint + marker cleared.
        #expect(await api.sentPaths == ["/api/medications/intake/bulk"])
        #expect(store.read() == nil)
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("signed out → arms but never writes even on the second tap")
    func signedOutNeverWrites() async throws {
        let (api, outbox) = try installOverride(signedIn: false, apiBehaviour: .succeed)
        let (store, url) = tempPendingStore()
        MarkNextDoseFromWidgetIntent.pendingStoreOverride = store
        defer {
            clearOverride()
            try? FileManager.default.removeItem(at: url)
        }

        let slot = Date(timeIntervalSince1970: 1_799_999_000)
        try store.arm(medicationId: "med-1", scheduledFor: slot)

        let intent = MarkNextDoseFromWidgetIntent(
            medicationId: "med-1",
            medicationName: "Vitamin D",
            scheduledForEpoch: slot.timeIntervalSince1970
        )
        _ = try await intent.perform()

        #expect(await api.sentPaths.isEmpty)
        #expect(await outbox.snapshot.isEmpty)
    }
}

// MARK: - Stub APIClient

/// Records the paths it was asked to POST + replays a canned outcome —
/// self-contained so this suite stays independent of the sibling
/// `HealthLogIntentsTests` stub. `.offline` throws a retriable `HLError` so
/// the repo routes the write to the Outbox.
private actor IntentStubAPIClient: APIClientProtocol {
    enum Behaviour {
        case succeed
        case offline
    }

    private let behaviour: Behaviour
    private(set) var sentPaths: [String] = []

    init(behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        sentPaths.append(request.path)
        switch behaviour {
        case .offline:
            throw HLError.offline
        case .succeed:
            let json = """
            {"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"taken","id":"i-1","reason":null}]}
            """
            return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
        }
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        sentPaths.append(request.path)
        if case .offline = behaviour { throw HLError.offline }
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("download not stubbed")
    }
}
