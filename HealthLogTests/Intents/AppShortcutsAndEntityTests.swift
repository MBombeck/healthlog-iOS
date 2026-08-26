import AppIntents
import Foundation
@testable import HealthLog
import Testing

/// **v0.15 W-SIRI** — coverage for the medication `AppEntity` disambiguation
/// query and the `AppShortcutsProvider` exposure.
///
/// Two layers:
///   - ``MedicationEntityQuery`` resolves the user's medications by name from
///     the shared server-first list (`MedicationsRepository.list()`), so Siri /
///     Spotlight can offer "the naproxen". Both `suggestedEntities()` (the
///     picker) and `entities(for:)` (id resolution) are covered, plus the
///     signed-out empty-set degrade.
///   - ``HealthLogAppShortcuts`` compiles + exposes the registered shortcuts,
///     including the new generic log-measurement intent.
@Suite("App Intents — entity query + shortcut provider")
@MainActor
struct AppShortcutsAndEntityTests {
    // MARK: - Medication entity query

    @Test("suggestedEntities lists the user's medications by name")
    func suggestedEntitiesListsMeds() async throws {
        installOverride(signedIn: true)
        defer { IntentDependencies.testOverride = nil }

        let entities = try await MedicationEntityQuery().suggestedEntities()
        let names = entities.map(\.name)
        #expect(names.contains("Naproxen"))
        #expect(names.contains("Lisinopril"))
    }

    @Test("entities(for:) resolves a medication by its id")
    func entitiesByIdResolves() async throws {
        installOverride(signedIn: true)
        defer { IntentDependencies.testOverride = nil }

        let resolved = try await MedicationEntityQuery().entities(for: ["med-ibu"])
        #expect(resolved.count == 1)
        #expect(resolved.first?.name == "Naproxen")
    }

    @Test("Signed out returns an empty entity set (the intent's own gate handles sign-in)")
    func signedOutReturnsEmpty() async throws {
        installOverride(signedIn: false)
        defer { IntentDependencies.testOverride = nil }

        let entities = try await MedicationEntityQuery().suggestedEntities()
        #expect(entities.isEmpty)
    }

    // MARK: - AppShortcutsProvider exposure

    @Test("AppShortcutsProvider exposes the registered shortcuts incl. the generic log intent")
    func providerExposesShortcuts() {
        // The provider compiles + builds its shortcut list. We assert the set
        // is non-empty and within Apple's 10-shortcut budget — a regression
        // guard if a future edit overflows or empties it.
        let shortcuts = HealthLogAppShortcuts.appShortcuts
        #expect(shortcuts.isEmpty == false)
        #expect(shortcuts.count <= 10)
    }

    // MARK: - Harness

    private func installOverride(signedIn: Bool) {
        let keychain = InMemoryKeychain()
        if signedIn {
            try? keychain.setString("test-bearer", forKey: KeychainKey.authToken)
        }
        let api = MedicationListStubAPIClient()
        // Force-unwrap is fine in a test seam — the in-memory store always opens.
        let outbox = try! OutboxQueue(inMemory: true) // swiftlint:disable:this force_try
        IntentDependencies.testOverride = IntentDependencies.Resolved(
            keychain: keychain,
            api: api,
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox)
        )
    }
}

/// Answers `/api/medications` with two named medications so the entity query
/// has real names + ids to resolve. Other paths are unused by these tests.
private actor MedicationListStubAPIClient: APIClientProtocol {
    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        guard request.path == "/api/medications" else {
            throw HLError.unknown("unexpected path \(request.path)")
        }
        let json = """
        [
          {"id":"med-ibu","name":"Naproxen","dose":"400 mg","schedules":[],"active":true},
          {"id":"med-ram","name":"Lisinopril","dose":"5 mg","schedules":[],"active":true}
        ]
        """
        return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("download not stubbed")
    }
}
