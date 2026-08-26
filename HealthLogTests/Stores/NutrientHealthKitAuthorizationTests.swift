import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **N2 — die Lücke, durch die die Nährstoffe nie gefragt wurden.**
///
/// Bis N2 stand `requestNutrientAuthorizationIfNeeded()` an genau einer Stelle:
/// im Moment, in dem jemand den `nutrients`-Schalter umlegt
/// (`SettingsModulesScreen`). Der Modulzustand liegt aber auf dem **Server**.
/// Ein Konto mit bereits eingeschaltetem Modul, getroffen auf einem Gerät, auf
/// dem die App neu installiert wurde, fragt damit nie — und ein nie angefragter
/// HealthKit-Lesetyp antwortet exakt wie ein leerer: keine Proben, kein Fehler.
/// Der Koordinator lief, fand nichts und meldete nichts.
///
/// **Genau dieser Ausgangszustand — „Modul serverseitig AN, Gerät hat nie
/// gefragt" — kam in keinem Szenario vor.** Er ist der Kern dieser Datei.
///
/// Die Behebung hängt die Anfrage an den ZUSTAND statt an die Handlung, nach dem
/// Muster von `CycleStore.refreshGateLifecycle`: Modul an + auf diesem Gerät
/// noch nichts gefragt ⇒ fragen, und zwar an der Nährstoff-Fläche, die der
/// Nutzer ohnehin ansteuert (nicht im Koordinator, der auch aus dem
/// Vordergrund-Sweep und dem Hintergrund-Task läuft — ein Berechtigungsblatt
/// mitten in einer anderen Tätigkeit wäre schlechter als keins).
///
/// Getrieben über den echten ``APIClient`` + `MockURLProtocol` (PROJECT_GUIDE.md — nie
/// ein Mock-Server), damit ein Schema-Drift auf `/api/nutrients` oder
/// `/api/auth/me/modules` hier auffliegt. `.serialized`, weil
/// `MockURLProtocol.handler` prozessweit ist.
@Suite("N2 — Nährstoff-Berechtigung hängt am Zustand, nicht an der Handlung", .serialized)
@MainActor
struct NutrientHealthKitAuthorizationTests {
    // MARK: - Fixtures

    private func makeAPIClient() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-abc", forKey: KeychainKey.authToken)
        try? keychain.setString("user-123", forKey: KeychainKey.userID)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.17.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private func makeRepo(api: APIClientProtocol) throws -> NutrientReadRepository {
        let outbox = try OutboxQueue(inMemory: true)
        return NutrientReadRepository(api: api, outbox: outbox)
    }

    /// `GET /api/nutrients` answers an EMPTY window — the shape the operator's
    /// device saw, and the shape a never-authorized read produces.
    private nonisolated static func emptyWindow(_ request: URLRequest) -> (HTTPURLResponse, Data?) {
        let body = #"{"data":{"windowDays":14,"nutrients":[]},"error":null}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    /// A store wired the way the composition root wires it, with the module map
    /// pinned to `enabled`.
    private func makeStore(
        moduleEnabled: Bool,
        writer: SpyNutrientHealthKitWriter,
        sync: SpyNutrientSync,
        gate: ModuleGate? = nil
    ) throws -> (NutrientStore, ModuleGate) {
        let api = makeAPIClient()
        let resolvedGate = gate ?? ModuleGate(modules: ["nutrients": moduleEnabled])
        let store = try NutrientStore(
            repository: makeRepo(api: api),
            moduleGate: resolvedGate,
            healthKit: writer,
            dailySync: sync
        )
        return (store, resolvedGate)
    }

    // MARK: - Der Kern: Modul serverseitig AN, Gerät hat nie gefragt

    @Test("Modul serverseitig AN + auf diesem Gerät nie gefragt ⇒ es wird gefragt und danach synchronisiert")
    func moduleOnAndNeverAskedRequestsAuthorization() async throws {
        MockURLProtocol.handler = { Self.emptyWindow($0) }
        let writer = SpyNutrientHealthKitWriter()
        let sync = SpyNutrientSync()
        let (store, _) = try makeStore(moduleEnabled: true, writer: writer, sync: sync)

        // Der Ausgangszustand, der ausgeliefert wurde: das Konto hat das Modul
        // an, das Gerät hat die Berechtigung noch nie angefragt.
        #expect(store.isModuleEnabled)
        #expect(!store.hasRequestedAuthorization)

        await store.prepareHealthKitAccessIfNeeded()

        #expect(writer.nutrientAuthorizationRequests == 1, "die Lücke: hier wurde vorher NIE gefragt")
        let syncCount = await sync.triggerCount
        #expect(syncCount == 1, "eine frisch erteilte Berechtigung holt sofort ihre 30 Tage nach")
        #expect(store.hasRequestedAuthorization)
        #expect(!store.isPreparingHealthKitAccess, "der Arbeitszustand löst sich auf")
    }

    @Test("Modul serverseitig AUS ⇒ es wird nicht gefragt (wer nicht zugestimmt hat, wird nicht behelligt)")
    func moduleOffNeverPrompts() async throws {
        MockURLProtocol.handler = { Self.emptyWindow($0) }
        let writer = SpyNutrientHealthKitWriter()
        let sync = SpyNutrientSync()
        let (store, _) = try makeStore(moduleEnabled: false, writer: writer, sync: sync)

        await store.prepareHealthKitAccessIfNeeded()

        let syncCount = await sync.triggerCount
        #expect(writer.nutrientAuthorizationRequests == 0)
        #expect(syncCount == 0)
        #expect(!store.hasRequestedAuthorization)
    }

    @Test("Zweiter Besuch derselben Fläche fragt nicht erneut — keine Schleife")
    func repeatedVisitsAskOnlyOnce() async throws {
        MockURLProtocol.handler = { Self.emptyWindow($0) }
        let writer = SpyNutrientHealthKitWriter()
        let sync = SpyNutrientSync()
        let (store, _) = try makeStore(moduleEnabled: true, writer: writer, sync: sync)

        await store.prepareHealthKitAccessIfNeeded()
        await store.prepareHealthKitAccessIfNeeded()
        await store.prepareHealthKitAccessIfNeeded()

        #expect(writer.nutrientAuthorizationRequests == 1)
    }

    @Test("Eine fehlgeschlagene Anfrage stoppt nichts — der Server bleibt die Wahrheit")
    func failedAuthorizationDoesNotStopTheFlow() async throws {
        MockURLProtocol.handler = { Self.emptyWindow($0) }
        let writer = SpyNutrientHealthKitWriter(failAuthorization: true)
        let sync = SpyNutrientSync()
        let (store, _) = try makeStore(moduleEnabled: true, writer: writer, sync: sync)

        await store.prepareHealthKitAccessIfNeeded()

        // Genau die CycleStore-Haltung: protokollieren und weiterlaufen. Der
        // Ablauf findet dann eben nichts — er behauptet aber nichts.
        let syncCount = await sync.triggerCount
        #expect(writer.nutrientAuthorizationRequests == 1)
        #expect(syncCount == 1)
        #expect(store.hasRequestedAuthorization, "gefragt wurde, unabhängig vom Ausgang")
        #expect(!store.isPreparingHealthKitAccess)
        // Und: kein „abgelehnt"-Zustand. HealthKit sagt es nicht, also sagt die
        // App es nicht.
        let state = NutrientEmptyState.resolve(
            isModuleEnabled: store.isModuleEnabled,
            isPreparingHealthKitAccess: store.isPreparingHealthKitAccess
        )
        #expect(state == .noData)
    }

    @Test("Abmelden setzt die Merkung zurück — der nächste Nutzer bekommt seinen eigenen Nachlauf")
    func logoutRearmsTheLifecycle() async throws {
        MockURLProtocol.handler = { Self.emptyWindow($0) }
        let writer = SpyNutrientHealthKitWriter()
        let sync = SpyNutrientSync()
        let (store, _) = try makeStore(moduleEnabled: true, writer: writer, sync: sync)

        await store.prepareHealthKitAccessIfNeeded()
        store.clearOnLogout()
        #expect(!store.hasRequestedAuthorization)
        await store.prepareHealthKitAccessIfNeeded()

        // Die Berechtigung selbst bleibt geräteweit entschieden (iOS zeigt kein
        // Blatt mehr); was zählt, ist der zweite Sync — der trägt den
        // nutzer-eigenen 30-Tage-Nachlauf.
        let syncCount = await sync.triggerCount
        #expect(syncCount == 2)
    }

    // MARK: - „Noch nie gefragt" wird nicht persistiert

    @Test("Die Merkung ist prozess-lokal — ein neuer Prozess fragt wieder (und iOS bleibt stumm, wenn entschieden)")
    func theMemoIsNotPersisted() async throws {
        MockURLProtocol.handler = { Self.emptyWindow($0) }
        let writer = SpyNutrientHealthKitWriter()
        let sync = SpyNutrientSync()
        let gate = ModuleGate(modules: ["nutrients": true])
        let (first, _) = try makeStore(moduleEnabled: true, writer: writer, sync: sync, gate: gate)
        await first.prepareHealthKitAccessIfNeeded()

        // Ein zweiter Store steht für den nächsten App-Start. Eine persistierte
        // Merkung würde hier schweigen — und damit auch dann schweigen, wenn der
        // Nutzer die Berechtigung in den iOS-Einstellungen zurückgesetzt hat.
        // HealthKit verrät den Lesestatus nicht, also darf die App ihn sich
        // nicht selbst merken.
        let (second, _) = try makeStore(moduleEnabled: true, writer: writer, sync: sync, gate: gate)
        #expect(!second.hasRequestedAuthorization)
        await second.prepareHealthKitAccessIfNeeded()
        #expect(writer.nutrientAuthorizationRequests == 2)
    }

    // MARK: - Die Einschalt-Schaltfläche des Leerzustands

    @Test("Einschalten aus dem Leerzustand schaltet das Modul ein und fragt dann die Berechtigung")
    func enableFromEmptyStateFlipsModuleThenAsks() async throws {
        let recorder = PathRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request.url?.path ?? "")
            if request.url?.path == "/api/auth/me/modules" {
                let body = #"{"data":{"modules":{"nutrients":true},"updatedAt":"2026-08-08T00:00:00Z"},"error":null}"#
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(body.utf8))
            }
            return Self.emptyWindow(request)
        }
        let api = makeAPIClient()
        let gate = ModuleGate(repo: ModuleGateRepository(api: api), modules: ["nutrients": false])
        let writer = SpyNutrientHealthKitWriter()
        let sync = SpyNutrientSync()
        let store = try NutrientStore(
            repository: makeRepo(api: api),
            moduleGate: gate,
            healthKit: writer,
            dailySync: sync
        )
        #expect(!store.isModuleEnabled)

        await store.enableModuleAndPrepare()

        #expect(gate.isEnabled(.nutrients), "die Schaltfläche schaltet wirklich ein")
        #expect(recorder.paths.contains("/api/auth/me/modules"))
        let syncCount = await sync.triggerCount
        #expect(writer.nutrientAuthorizationRequests == 1, "und fragt im selben Zug die Berechtigung an")
        #expect(syncCount == 1)
    }

    // MARK: - Der Leerzustand unterscheidet die drei echten Fälle

    @Test("Die drei Zustände werden auseinandergehalten")
    func emptyStateResolution() {
        #expect(
            NutrientEmptyState.resolve(isModuleEnabled: false, isPreparingHealthKitAccess: false) == .moduleOff
        )
        #expect(
            NutrientEmptyState.resolve(isModuleEnabled: false, isPreparingHealthKitAccess: true) == .moduleOff,
            "ausgeschaltet schlägt jeden Arbeitszustand — es gibt nichts vorzubereiten"
        )
        #expect(
            NutrientEmptyState.resolve(isModuleEnabled: true, isPreparingHealthKitAccess: true) == .preparing
        )
        #expect(
            NutrientEmptyState.resolve(isModuleEnabled: true, isPreparingHealthKitAccess: false) == .noData
        )
    }

    @Test("Nur der Modul-aus-Fall trägt eine Handlung — und die schaltet das Modul ein")
    func onlyModuleOffOffersAnAction() {
        #expect(NutrientEmptyState.moduleOff.presentationDescriptor()?.primaryAction == .enableModule)
        #expect(NutrientEmptyState.noData.presentationDescriptor()?.primaryAction == nil)
        // `preparing` bekommt gar keinen Textblock: der Ladezustand ist dort die
        // ehrliche Darstellung, jeder Satz wäre eine erfundene Ursache.
        #expect(NutrientEmptyState.preparing.presentationDescriptor() == nil)
    }
}

// MARK: - Doubles

/// Minimal ``AnyHealthKitWriter`` double — alles andere kommt aus den
/// Protokoll-Vorgaben. Genau die Naht, die den Nährstoff-Pfad ohne HealthKit
/// testbar macht.
private final class SpyNutrientHealthKitWriter: AnyHealthKitWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _nutrientAuthorizationRequests = 0
    private let failAuthorization: Bool

    init(failAuthorization: Bool = false) {
        self.failAuthorization = failAuthorization
    }

    var nutrientAuthorizationRequests: Int {
        lock.withLock { _nutrientAuthorizationRequests }
    }

    func requestNutrientAuthorizationIfNeeded() async throws {
        lock.withLock { _nutrientAuthorizationRequests += 1 }
        if failAuthorization { throw URLError(.userAuthenticationRequired) }
    }

    func write(_: HealthLog.Measurement) async throws {}
    func writeMood(_: MoodEntry) async throws {}
    func deleteMood(id _: String) async throws {}
    func requestMoodAuthorization() async throws {}
    func startMoodImport(repo _: MoodRepository, userID _: String?) async {}
    func stopMoodImport() async {}
    func resetMoodImport() async {}
    func activateBackgroundDeliveries() async throws {}
    func runBackgroundSyncPass() async {}
    func attachUploader(_: MeasurementBatchUploader) async {}
    func attachDeletionReconciler(_: MeasurementDeletionReconciler) async {}
    func setInitialBackfillCutoff(_: Date?) async {}
    func attachFeatureFlags(_: (any FeatureFlagsServicing)?) async {}
    func stopWorkoutImportObserver() async {}
    func resetWorkoutImportObserver() async {}
}

/// Counts the sweeps the store kicks after an authorization request.
private actor SpyNutrientSync: NutrientDailySyncing {
    private(set) var triggerCount = 0

    func triggerNutrientSync() async {
        triggerCount += 1
    }
}

/// Records the request paths the store drove, so "the enable button really
/// PATCHes the module route" is asserted rather than assumed.
private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []

    var paths: [String] {
        lock.withLock { _paths }
    }

    func record(_ path: String) {
        lock.withLock { _paths.append(path) }
    }
}

// swiftlint:enable force_unwrapping
