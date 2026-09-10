import Foundation
@testable import HealthLog
import Testing

/// Audit B-1 (2026-09-10), follow-up — what the user *reads* when a write was
/// not persisted.
///
/// W1 made a refused outbox enqueue honest: the repositories now throw
/// `HLError.notPersisted` and the stores fall through to their failure arm. But
/// several stores build their visible error string from
/// `LogSanitizer.redact(String(describing: error))` (or, on an untyped `Error`,
/// from Foundation's generic `localizedDescription`). So the honest failure
/// arrived on screen as `notPersisted("…")` or as "The operation couldn't be
/// completed", while `HLError.userFacingDescription` already owns a localized
/// sentence for exactly this case.
///
/// These tests pin the sentence, not the Swift description: after a refused
/// enqueue the store's visible error is the localized copy and carries no enum
/// case name.
@Suite("Audit B-1 — a not-persisted write reads as its localized copy")
struct NotPersistedUserFacingCopyTests {
    // MARK: - Fixtures

    /// A lease that never grants background execution time — the build-274
    /// refusal (`OutboxQueue.WriteRefusal.noBackgroundExecutionTime`) that makes
    /// `notPersisted` reachable in the field.
    private struct RefusingLease: BackgroundExecutionLeasing {
        func withLease<T: Sendable>(
            named _: String,
            _: @escaping @Sendable () async throws -> T
        ) async throws -> T? {
            nil
        }
    }

    /// Every request fails retriably, so the repository takes its outbox arm.
    private struct FailingAPI: APIClientProtocol {
        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            throw HLError.network(.connectionLost)
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {
            throw HLError.network(.connectionLost)
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.network(.connectionLost)
        }
    }

    private func refusingOutbox() throws -> OutboxQueue {
        try OutboxQueue(inMemory: true, backgroundLease: RefusingLease())
    }

    /// The one sentence the user is owed for a write that reached neither the
    /// server nor the outbox. The associated value is triage-only, so any
    /// payload resolves to the same copy.
    private var notPersistedCopy: String {
        HLError.notPersisted("enqueue refused").userFacingDescription
    }

    // MARK: - Tests

    @Test("AllergiesStore.create shows the localized couldn't-save copy, not notPersisted(…)")
    @MainActor
    func allergiesCreateShowsLocalizedCopy() async throws {
        let outbox = try refusingOutbox()
        let store = AllergiesStore(repository: AllergiesRepository(api: FailingAPI(), outbox: outbox))

        _ = await store.create(AllergyCreate(substance: "Pollen"))

        let shown = try #require(store.lastError)
        #expect(shown == notPersistedCopy)
        #expect(!shown.contains("notPersisted("))
    }

    @Test("NutrientStore.addWater shows the localized couldn't-save copy, not a Foundation string")
    @MainActor
    func nutrientAddWaterShowsLocalizedCopy() async throws {
        let outbox = try refusingOutbox()
        let store = NutrientStore(repository: NutrientReadRepository(api: FailingAPI(), outbox: outbox))

        await store.addWater(amountMl: 250)

        let shown = try #require(store.lastError)
        #expect(shown == notPersistedCopy)
        #expect(!shown.contains("notPersisted("))
    }
}
