import Foundation
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping

/// E1 (C4, open point) — a write from the UI whose own request is cut off on
/// the wire (`URLError.cancelled` while the task is still running: the app was
/// suspended, a background window ended, the certificate pin failed) used to
/// arrive as `HLError.canceled`, which is not `shouldPersistToOutbox`. The
/// repository did not queue it, the store rolled back and showed an error, and
/// the person had to type it again.
///
/// Now `APIClient` reports it as `.network(.writeCancelled)`: queued under the
/// SAME idempotency key the cut-off request carried, so a request that did reach
/// the server is answered from its 24 h cache on replay instead of counting
/// twice. A read, and a task that was cancelled on purpose, keep `.canceled`.
@Suite("A cut-off live write is queued, not lost", .serialized, .mockURLSession)
@MainActor
struct LiveWriteCancellationTests {
    nonisolated static let owner = "account-e1w"

    private static func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-e1w", forKey: KeychainKey.authToken)
        try? keychain.setString(owner, forKey: KeychainKey.userID)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    @Test("a cut-off allergy create is queued under the key it was sent with; the store keeps it")
    func cutOffCreateIsQueued() async throws {
        let sentKeys = OSAllocatedUnfairLock<[String]>(initialState: [])
        MockURLProtocol.install { req in
            sentKeys.withLock { $0.append(req.value(forHTTPHeaderField: "Idempotency-Key") ?? "") }
            throw URLError(.cancelled)
        }
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        let store = AllergiesStore(repository: AllergiesRepository(api: Self.makeAPI(), outbox: outbox))

        let saved = await store.create(AllergyCreate(substance: "Penicillin", category: .medication))

        #expect(saved != nil, "the person's entry stays on screen")
        #expect(store.lastError == nil)
        let row = try #require(await outbox.snapshot.first)
        #expect(row.kind == .createAllergy)
        #expect(sentKeys.withLock { $0 } == [row.idempotencyKey], "one send, and the queued row reuses its key")
    }

    @Test("the transport tells a cut-off write from a cut-off read")
    func onlyWritesBecomeQueueable() async throws {
        MockURLProtocol.install { _ in throw URLError(.cancelled) }
        let api = Self.makeAPI()

        await #expect(throws: HLError.network(.writeCancelled)) {
            let request: APIRequest<AllergyDTO> = try .post(
                "/api/allergies",
                body: AllergyCreate(substance: "Latex", category: .other)
            )
            _ = try await api.send(request)
        }
        await #expect(throws: HLError.canceled) {
            let request: APIRequest<[AllergyDTO]> = .get("/api/allergies")
            _ = try await api.send(request)
        }
        #expect(HLError.network(.writeCancelled).shouldPersistToOutbox)
        #expect(!HLError.network(.writeCancelled).isRetriable, "a pin failure would repeat at once")
        #expect(!HLError.canceled.shouldPersistToOutbox)
    }
}

// swiftlint:enable force_unwrapping
