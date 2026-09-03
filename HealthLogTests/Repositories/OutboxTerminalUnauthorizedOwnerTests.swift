import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// Build 273 (sync audit A2) — a write that hits a TERMINAL 401 must be
/// enqueued under the user who made it, not as an ownerless row.
///
/// Sequence on device: `APIClient` gets a 401, the refresh handler answers
/// `.authFailure`, `onUnauthorized` runs `AuthStore.handleUnauthorized`, which
/// wipes `KeychainKey.userID` — and only THEN does the repository's catch
/// enqueue the write. The enqueue chokepoint read the live keychain, found no
/// user, and stamped `nil`; after re-login the replay quarantined the row as
/// `.unownedRow` forever while `pendingOutboxCount` kept counting it.
@Suite("Outbox — terminal 401 keeps the previous owner (A2)", .serialized)
struct OutboxTerminalUnauthorizedOwnerTests {
    private func makeAPI(
        keychain: KeychainStoring,
        refresh: @escaping @Sendable () async -> RefreshOutcome,
        onUnauthorized: (@Sendable () async -> Void)?
    ) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock(),
            onUnauthorized: onUnauthorized,
            refreshHandler: refresh
        )
    }

    private final class NoopPasskey: PasskeyServiceProtocol, @unchecked Sendable {
        @MainActor func register(
            challenge _: String, rpId _: String, rpName _: String,
            userID _: String, userName _: String, displayName _: String,
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyRegistration {
            throw HLError.unknown("noop")
        }

        @MainActor func assert(
            challenge _: String, rpId _: String, allowCredentialIDs _: [String],
            anchor _: ASPresentationAnchorProvider
        ) async throws -> PasskeyAssertion {
            throw HLError.unknown("noop")
        }
    }

    /// Inline-built so the parameter type resolves the domain `Measurement`.
    private func createSample(_ repo: MeasurementsRepository) async throws {
        _ = try await repo.create(
            .init(
                id: "local-\(UUID().uuidString)",
                kind: .weight,
                recordedAt: Date(timeIntervalSince1970: 1_714_550_400),
                value: .scalar(81.0)
            )
        )
    }

    @Test("the credential wipe remembers the user it signed out")
    func wipeRemembersLastSessionUser() async throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("user-a", forKey: KeychainKey.userID)
        try keychain.setString("bearer", forKey: KeychainKey.authToken)
        let auth = AuthService(
            api: makeAPI(keychain: keychain, refresh: { .authFailure }, onUnauthorized: nil),
            keychain: keychain,
            passkey: NoopPasskey()
        )
        _ = try await auth.invalidateAndWipeSessionCredentials()
        #expect(keychain.getString(forKey: KeychainKey.userID) == nil)
        #expect(keychain.getString(forKey: KeychainKey.lastSessionUserID) == "user-a")
    }

    @Test("the owner provider falls back to the last session user, and a live user wins")
    func ownerProviderFallsBack() throws {
        let keychain = InMemoryKeychain()
        let provider = OutboxQueue.ownerProvider(keychain: keychain)
        #expect(provider() == nil)
        try keychain.setString("user-a", forKey: KeychainKey.lastSessionUserID)
        #expect(provider() == "user-a")
        try keychain.setString("user-b", forKey: KeychainKey.userID)
        #expect(provider() == "user-b")
    }

    @Test("terminal 401 on create enqueues the write under the signed-out user")
    func terminalUnauthorizedEnqueuesWithPreviousOwner() async throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("user-a", forKey: KeychainKey.userID)
        try keychain.setString("bearer", forKey: KeychainKey.authToken)
        let wiper = AuthService(
            api: makeAPI(keychain: keychain, refresh: { .authFailure }, onUnauthorized: nil),
            keychain: keychain,
            passkey: NoopPasskey()
        )
        let api = makeAPI(
            keychain: keychain,
            refresh: { .authFailure },
            onUnauthorized: { _ = try? await wiper.invalidateAndWipeSessionCredentials() }
        )
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: OutboxQueue.ownerProvider(keychain: keychain))
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, nil)
        }
        let repo = MeasurementsRepository(api: api, outbox: outbox)

        await #expect(throws: HLError.unauthorized) {
            try await createSample(repo)
        }
        let rows = await outbox.snapshot
        #expect(rows.count == 1)
        #expect(rows.first?.ownerUserID == "user-a")
        // After re-login as the same user the row is attributable, not quarantined.
        #expect(rows.first?.quarantineReason(currentUserID: "user-a") == nil)
    }
}
