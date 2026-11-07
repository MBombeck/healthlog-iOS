import Foundation
@testable import HealthLog
import Testing
#if canImport(AuthenticationServices)
    import AuthenticationServices
#endif

// swiftlint:disable force_unwrapping

/// 1.5 KONTO (#151, server 1.46.0) — account deletion and "delete all data"
/// with a grace window, and the sign-in refusal of a locked account. Every
/// point runs against "server without the field" and "server with the field"
/// (rule 10): the copy has to be true for both generations.
///
/// Real `APIClient` over `MockURLProtocol`; the server version lives in an
/// isolated `UserDefaults` suite.
@MainActor
@Suite("KONTO: deletion grace window, receipts and the locked sign-in", .serialized, .mockURLSession)
struct AccountDeletionGraceTests {
    private static let baseURL = URL(string: "https://test.healthlog.local")!
    private static let purgeISO = "2026-11-18T09:30:00.000Z"
    private static let purgeDate = AccountDeletionWire.date(purgeISO)!

    private static func makeAPI(keychain: KeychainStoring = InMemoryKeychain()) -> APIClient {
        APIClient(
            environment: AppEnvironment(baseURL: baseURL, bundleID: "dev.healthlog.app", appVersion: "1.5.0", buildNumber: "1"),
            keychain: keychain,
            sessionConfiguration: .mock()
        )
    }

    private static func respond(_ status: Int, _ json: String?) {
        MockURLProtocol.install { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                json.map { Data($0.utf8) }
            )
        }
    }

    private static func defaults(server version: String?) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "hl.test.konto.\(UUID().uuidString)"))
        if let version {
            KnownServerVersion.record(ServerVersionInfo(version: version), defaults: defaults)
        }
        return defaults
    }

    private static func authService(_ keychain: KeychainStoring) -> AuthService {
        AuthService(api: makeAPI(keychain: keychain), keychain: keychain, passkey: StubPasskeyServiceForKonto())
    }

    // MARK: - Receipts

    @Test("Delete account: 1.46 answers scheduledPurgeAt, the receipt carries it")
    func deleteReceiptWithField() async throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("token", forKey: KeychainKey.authToken)
        Self.respond(200, #"{"data":{"deleted":true,"scheduledPurgeAt":"\#(Self.purgeISO)"},"error":null}"#)
        let receipt = try await Self.authService(keychain).deleteAccount()
        #expect(receipt.scheduledPurgeAt == Self.purgeDate)
        #expect(keychain.getString(forKey: KeychainKey.authToken) == nil, "the account is locked: the local session goes")
    }

    @Test("Delete account: an older server (no field), a null field and an empty 204 all read as deleted now")
    func deleteReceiptWithoutField() async throws {
        for (status, body) in [
            (200, #"{"data":{"deleted":true}}"#),
            (200, #"{"data":{"deleted":true,"scheduledPurgeAt":null},"error":null}"#),
            (204, nil),
            (200, #"{"data":{"deleted":true,"scheduledPurgeAt":"not a date"}}"#)
        ] {
            let keychain = InMemoryKeychain()
            try keychain.setString("token", forKey: KeychainKey.authToken)
            Self.respond(status, body)
            let receipt = try await Self.authService(keychain).deleteAccount()
            #expect(receipt.scheduledPurgeAt == nil)
            #expect(keychain.getString(forKey: KeychainKey.authToken) == nil)
        }
    }

    @Test("Delete all data: restorableUntil reaches the success line; without it the old sentence stays")
    func wipeReceipt() async throws {
        Self.respond(200, #"{"data":{"cleared":true,"deletedRows":3,"models":{},"restorableUntil":"\#(Self.purgeISO)"},"error":null}"#)
        let repo = AccountDataResetRepository(api: Self.makeAPI())
        let receipt = try await repo.resetAllData()
        #expect(receipt.restorableUntil == Self.purgeDate)
        let line = AccountDeletionCopy.wipeSuccessMessage(receipt)
        #expect(line.contains(AccountDeletionCopy.dateText(Self.purgeDate)))

        Self.respond(200, #"{"data":{"cleared":true,"deletedRows":3,"models":{}},"error":null}"#)
        let old = try await repo.resetAllData()
        #expect(old.restorableUntil == nil)
        #expect(AccountDeletionCopy.wipeSuccessMessage(old) == String(localized: "resetData.success.body"))
    }

    @Test("Delete all data: 503 data_wipe.copy_failed says nothing was deleted, and is sent once")
    func wipeCopyFailed() async throws {
        let calls = KontoCallCounter()
        MockURLProtocol.install { req in
            calls.bump()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"copy failed","meta":{"errorCode":"data_wipe.copy_failed"}}"#.utf8)
            )
        }
        let repo = AccountDataResetRepository(api: Self.makeAPI())
        do {
            try await repo.resetAllData()
            Issue.record("a 503 must throw")
        } catch let error as HLError {
            #expect(ResetDataScreen.resetErrorText(error) == String(localized: "resetData.error.copyFailed"))
        }
        #expect(calls.count == 1, "the person repeats a destructive request, not the transport")
        // Another 503 without the code keeps the generic sentence.
        #expect(ResetDataScreen
            .resetErrorText(.server(status: 503, code: nil, message: "x")) != String(localized: "resetData.error.copyFailed"))
    }

    // MARK: - What the screens promise before the request

    @Test("Policy: older or unknown server erases at once; 1.46 locks first; a 0-day window is immediate")
    func policyByServer() throws {
        #expect(try AccountDeletionPolicy.initial(defaults: Self.defaults(server: nil)) == .immediate)
        #expect(try AccountDeletionPolicy.initial(defaults: Self.defaults(server: "1.45.9")) == .immediate)
        #expect(try AccountDeletionPolicy.initial(defaults: Self.defaults(server: "1.46.0")) == .graceWindow(days: nil))
        #expect(AccountDeletionPolicy.resolve(serverHasGraceWindow: true, graceDays: 0) == .immediate)
        #expect(AccountDeletionPolicy.resolve(serverHasGraceWindow: true, graceDays: 14) == .graceWindow(days: 14))
        #expect(AccountDeletionPolicy.resolve(serverHasGraceWindow: false, graceDays: 14) == .immediate)
    }

    @Test("Policy: the window length comes from privacy-summary; a server without the field keeps the general line")
    func policyReadsGraceDays() async throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("token", forKey: KeychainKey.authToken)
        let store = try AuthStore(auth: Self.authService(keychain), keychain: keychain, defaults: Self.defaults(server: nil))
        let modern = try Self.defaults(server: "1.46.6")

        Self.respond(
            200,
            #"{"data":{"retention":{"coachMessagesDays":365,"auditLogDays":365,"deliveryLogDays":90,"accountDeletionGraceDays":14}},"error":null}"#
        )
        #expect(await store.accountDeletionPolicy(defaults: modern) == .graceWindow(days: 14))

        Self.respond(200, #"{"data":{"retention":{"coachMessagesDays":365,"auditLogDays":365,"deliveryLogDays":90}},"error":null}"#)
        #expect(await store.accountDeletionPolicy(defaults: modern) == .graceWindow(days: nil))

        Self.respond(200, #"{"data":{"retention":{"accountDeletionGraceDays":0}},"error":null}"#)
        #expect(await store.accountDeletionPolicy(defaults: modern) == .immediate)

        Self.respond(500, #"{"data":null,"error":"x"}"#)
        #expect(await store.accountDeletionPolicy(defaults: modern) == .graceWindow(days: nil))

        // A server that publishes the window is a grace-window server even
        // before the version is known; without the field an older or unknown
        // server erases at once.
        Self.respond(200, #"{"data":{"retention":{"accountDeletionGraceDays":14}},"error":null}"#)
        #expect(try await store.accountDeletionPolicy(defaults: Self.defaults(server: nil)) == .graceWindow(days: 14))
        Self.respond(200, #"{"data":{"retention":{"coachMessagesDays":365}},"error":null}"#)
        #expect(try await store.accountDeletionPolicy(defaults: Self.defaults(server: "1.45.0")) == .immediate)
        #expect(try await store.accountDeletionPolicy(defaults: Self.defaults(server: nil)) == .immediate)
    }

    @Test("Copy: immediate keeps „cannot be undone“; the window names the day or says it is set by the admin")
    func finalLines() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(AccountDeletionCopy.deleteFinalLine(.immediate, now: now) == String(localized: "This action cannot be undone."))
        #expect(AccountDeletionCopy.resetFinalLine(.immediate, now: now) == String(localized: "resetData.explain.bullet.irreversible"))

        let day = try #require(Calendar.current.date(byAdding: .day, value: 14, to: now))
        let withDays = AccountDeletionCopy.deleteFinalLine(.graceWindow(days: 14), now: now)
        #expect(withDays.contains(AccountDeletionCopy.dateText(day)))
        #expect(withDays != String(localized: "This action cannot be undone."))
        #expect(AccountDeletionCopy.resetFinalLine(.graceWindow(days: 14), now: now).contains(AccountDeletionCopy.dateText(day)))

        #expect(AccountDeletionCopy.deleteFinalLine(.graceWindow(days: nil), now: now) == String(localized: "deleteAccount.grace.unknown"))
        #expect(AccountDeletionCopy.resetFinalLine(.graceWindow(days: nil), now: now) == String(localized: "resetData.grace.unknown"))
    }

    @Test("Receipt alert: a date says when it is erased; none says it is gone")
    func receiptCopy() {
        let scheduled = AccountDeletionCopy.receiptMessage(AccountDeletionReceipt(scheduledPurgeAt: Self.purgeDate))
        #expect(scheduled.contains(AccountDeletionCopy.dateText(Self.purgeDate)))
        #expect(AccountDeletionCopy
            .receiptMessage(AccountDeletionReceipt(scheduledPurgeAt: nil)) == String(localized: "account.deleted.receipt.now"))
    }

    @Test("AuthStore keeps the receipt for the sign-in flow after a deletion")
    func storeKeepsReceipt() async throws {
        let keychain = InMemoryKeychain()
        try keychain.setString("token", forKey: KeychainKey.authToken)
        try keychain.setString("user-1", forKey: KeychainKey.userID)
        let store = try AuthStore(auth: Self.authService(keychain), keychain: keychain, defaults: Self.defaults(server: nil))
        store.setPhaseForTesting(.authenticated(User(id: "user-1")))
        Self.respond(200, #"{"data":{"deleted":true,"scheduledPurgeAt":"\#(Self.purgeISO)"},"error":null}"#)
        #expect(await store.deleteAccount())
        #expect(store.phase == .unauthenticated)
        #expect(store.deletionReceipt == AccountDeletionReceipt(scheduledPurgeAt: Self.purgeDate))
    }

    // MARK: - Sign-in to a locked account

    @Test("403 auth.account.deletion_pending becomes its own error with meta.purgeAt")
    func deletionPendingTyped() async throws {
        Self.respond(
            403,
            #"{"data":null,"error":"Account pending deletion","meta":{"errorCode":"auth.account.deletion_pending","purgeAt":"\#(Self.purgeISO)"}}"#
        )
        let api = Self.makeAPI()
        do {
            _ = try await api.send(APIRequest<EmptyPayload>(method: .post, path: "/api/auth/login", maxRetries: 0))
            Issue.record("a 403 must throw")
        } catch let error as HLError {
            #expect(error == .accountDeletionPending(purgeAt: Self.purgeDate))
            #expect(!error.isRetriable)
            #expect(!error.shouldPersistToOutbox)
            let sentence = AuthStore.passwordLoginFailure(error).signInFacingDescription
            #expect(sentence.contains(AccountDeletionCopy.dateText(Self.purgeDate)))
            #expect(AuthStore.passkeyLoginFailure(error).signInFacingDescription == sentence)
        }
    }

    @Test("Without purgeAt the refusal still has its own sentence; an older server's 403 stays as it was")
    func deletionPendingWithoutDateAndOlderServer() async throws {
        Self.respond(403, #"{"data":null,"error":"Account pending deletion","meta":{"errorCode":"auth.account.deletion_pending"}}"#)
        let api = Self.makeAPI()
        do {
            _ = try await api.send(APIRequest<EmptyPayload>(method: .post, path: "/api/auth/mfa/verify", maxRetries: 0))
            Issue.record("a 403 must throw")
        } catch let error as HLError {
            #expect(error == .accountDeletionPending(purgeAt: nil))
            #expect(error.userFacingDescription == String(localized: "account.deletionPending.signIn.noDate"))
        }

        Self.respond(403, #"{"data":null,"error":"Password login is disabled","meta":{"errorCode":"oidc_only"}}"#)
        do {
            _ = try await api.send(APIRequest<EmptyPayload>(method: .post, path: "/api/auth/login", maxRetries: 0))
        } catch let error as HLError {
            #expect(error == .server(status: 403, code: "oidc_only", message: "Password login is disabled"))
        }
    }

    @Test("SSO: error=account_deletion_pending has its own sentence, with the date when one comes")
    func ssoDeletionPending() throws {
        let plain = try OidcCallback.parse(#require(URL(string: "healthlog://oidc-callback?error=account_deletion_pending")))
        #expect(plain == .error(.accountDeletionPending(purgeAt: nil)))
        if case let .error(reason) = plain {
            #expect(reason.localizedMessage == String(localized: "account.deletionPending.signIn.noDate"))
            #expect(reason.logLabel == "account_deletion_pending")
        }
        let dated = try OidcCallback
            .parse(#require(URL(string: "healthlog://oidc-callback?error=account_deletion_pending&purgeAt=\(Self.purgeISO)")))
        #expect(dated == .error(.accountDeletionPending(purgeAt: Self.purgeDate)))
        // An unknown reason still reads as the generic SSO failure.
        #expect(try OidcCallback
            .parse(#require(URL(string: "healthlog://oidc-callback?error=something_new"))) == .error(.unknown("something_new")))
    }
}

final class StubPasskeyServiceForKonto: PasskeyServiceProtocol, @unchecked Sendable {
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

final class KontoCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}
