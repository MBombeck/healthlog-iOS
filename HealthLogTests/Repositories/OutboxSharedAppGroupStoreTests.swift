import AppIntents
import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping force_try

/// **audit-v0162 H2 — the offline "Genommen"/mood write-loss regression.**
///
/// The Lock-Screen widget + Live-Activity App Intents run inside the
/// *widget-extension* process. Pre-fix, an offline "Genommen" tap enqueued its
/// durable write-ahead row into the extension's **own sandbox** outbox
/// (`<extension-sandbox>/…/Outbox/outbox.sqlite`), which the app's
/// `OutboxReplayService` could never see — the intake was permanently lost.
///
/// The fix resolves `OutboxStore.persistentStoreURL()` into the **shared App
/// Group container** (`group.dev.healthlog.app`) so the app and the extension
/// open ONE outbox store, and the app's existing replay loop drains
/// extension-enqueued writes.
///
/// These tests prove both halves:
///   1. the resolved store URL lives inside the injected App Group container;
///   2. an op enqueued through the extension's `IntentDependencies` path is
///      visible to an app-side `OutboxQueue` reading the same store, and a
///      subsequent app-side drain removes it.
@Suite("Outbox shared App Group store (audit-v0162 H2)", .serialized)
@MainActor
struct OutboxSharedAppGroupStoreTests {
    // MARK: - Helpers

    /// A throwaway temp directory that stands in for the provisioned App Group
    /// container (unit-test bundles are not provisioned for the real group, so
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil — we
    /// inject this instead).
    private func makeTempAppGroupContainer() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appgroup-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real on-disk `OutboxStore` container at `url` — the single shared file
    /// both the app and the widget extension open post-fix.
    private func makePersistentContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: OutboxSchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogOutbox",
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, migrationPlan: nil, configurations: [config])
    }

    private func makeAPI(behaviour: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data?)) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        MockURLProtocol.handler = behaviour
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    // MARK: - (1) URL resolves into the shared container

    @Test("persistentStoreURL resolves into the shared App Group container when provisioned")
    func storeURLLivesInAppGroupContainer() throws {
        let container = makeTempAppGroupContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let dir = try OutboxStore.outboxDirectory(appGroupContainer: container)
        #expect(dir.path.hasPrefix(container.path))
        #expect(dir.lastPathComponent == "Outbox")

        let url = try OutboxStore.persistentStoreURL(appGroupContainer: container)
        #expect(url.path.hasPrefix(container.path))
        #expect(url.lastPathComponent == "outbox.sqlite")
    }

    @Test("nil App Group container falls back to the process-local Application Support path")
    func fallsBackToSandboxWhenGroupUnavailable() throws {
        // Preserves the app-target / unit-test behavior where the group is not
        // provisioned — must NOT throw and must resolve a usable local path.
        let url = try OutboxStore.persistentStoreURL(appGroupContainer: nil)
        #expect(url.lastPathComponent == "outbox.sqlite")
        #expect(url.path.contains("HealthLog/Outbox"))
    }

    // MARK: - (2) Extension-enqueued write is visible to + drainable by the app

    @Test("offline widget intake enqueued via IntentDependencies lands in the shared store the app drains")
    func extensionEnqueueVisibleToAppDrain() async throws {
        let appGroup = makeTempAppGroupContainer()
        defer { try? FileManager.default.removeItem(at: appGroup) }

        // The single on-disk outbox at the resolved App Group URL. Both the
        // extension-role and app-role queues bind to THIS container — the
        // in-process equivalent of "the widget extension and the app open the
        // same shared file" (mirrors the OutboxPersistenceTests cross-process
        // approximation).
        let storeURL = try OutboxStore.persistentStoreURL(appGroupContainer: appGroup)
        #expect(storeURL.path.hasPrefix(appGroup.path)) // the fix is in effect
        let shared = try makePersistentContainer(at: storeURL)

        // --- Widget-extension process role: enqueue offline via the intent ---
        let keychain = InMemoryKeychain()
        try keychain.setString("test-bearer", forKey: KeychainKey.authToken)
        let offlineAPI = OfflineStubAPIClient()
        let extOutbox = OutboxQueue(testContainer: shared)
        IntentDependencies.testOverride = IntentDependencies.Resolved(
            keychain: keychain,
            api: offlineAPI,
            outbox: extOutbox,
            measurementsRepo: MeasurementsRepository(api: offlineAPI, outbox: extOutbox),
            medicationsRepo: MedicationsRepository(api: offlineAPI, outbox: extOutbox),
            moodRepo: MoodRepository(api: offlineAPI, outbox: extOutbox)
        )
        let pendingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-confirm-\(UUID().uuidString).json")
        let pendingStore = WidgetPendingConfirmStore(url: pendingURL)
        MarkNextDoseFromWidgetIntent.pendingStoreOverride = pendingStore
        defer {
            IntentDependencies.testOverride = nil
            MarkNextDoseFromWidgetIntent.pendingStoreOverride = nil
            try? FileManager.default.removeItem(at: pendingURL)
        }

        let slot = Date(timeIntervalSince1970: 1_799_999_000)
        // Pre-arm so this is the SECOND (recording) tap of the two-step confirm.
        try pendingStore.arm(medicationId: "med-1", scheduledFor: slot)
        let intent = MarkNextDoseFromWidgetIntent(
            medicationId: "med-1",
            medicationName: "Vitamin D",
            scheduledForEpoch: slot.timeIntervalSince1970
        )
        // Offline → recordFromReminder's write-ahead keeps a durable row and the
        // send re-throws; the intent surfaces the queued state.
        _ = try? await intent.perform()

        #expect(await extOutbox.snapshot.count == 1, "offline intake must be durably enqueued into the shared store")

        // --- App process role: a fresh OutboxQueue on the SAME shared store ---
        let appOutbox = OutboxQueue(testContainer: shared)
        #expect(
            await appOutbox.snapshot.count == 1,
            "the app must SEE the extension-enqueued write — the whole point of the shared App Group store"
        )

        // The app's replay loop drains it once the server is reachable.
        let appAPI = makeAPI { req in
            let body = #"""
            {"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"taken","id":"i-1","reason":null}]}
            """#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let replay = OutboxReplayService(
            outbox: appOutbox,
            measurementsRepo: MeasurementsRepository(api: appAPI, outbox: appOutbox),
            moodRepo: MoodRepository(api: appAPI, outbox: appOutbox),
            medicationsRepo: MedicationsRepository(api: appAPI, outbox: appOutbox),
            maxAttempts: 8,
            deadLetterMinAge: 0,
            attemptBackoff: 0
        )
        await replay.runOnce()

        #expect(await appOutbox.snapshot.isEmpty, "app-side drain must clear the extension-enqueued intake")
    }
}

// MARK: - Offline stub

/// Always throws a retriable `HLError.offline` so the repo routes the write to
/// the Outbox's write-ahead path — the offline-subway scenario the fix targets.
private actor OfflineStubAPIClient: APIClientProtocol {
    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.offline
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.offline
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.offline
    }
}

// swiftlint:enable force_unwrapping force_try
