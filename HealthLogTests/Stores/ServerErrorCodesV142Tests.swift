// Server v1.42: the new error codes the app now names.
//
// Passkey sign-in: `401 passkey.challenge.expired`, `404 passkey.unknown`,
// `422 passkey.response.invalid`, `401 passkey.verification.failed`, each in
// `meta.errorCode` (before v1.42 the first two were a generic 500).
// Medications: `422 medication.intake.notTracked` on the intake routes and the
// per-entry `intake_not_tracked` skip on `POST /api/medications/intake/bulk`.
//
// Bodies follow `ErrorEnvelope` and `BulkMedicationIntakeEntryResult` in
// `docs/api/openapi.yaml` on `release/v1.42.0` (`402c50378`).

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @MainActor
    @Suite("Server v1.42 error codes: passkey sign-in and untracked intake", .serialized, .mockURLSession)
    struct ServerErrorCodesV142Tests {
        private func makeStore() -> AuthStore {
            let keychain = InMemoryKeychain()
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.2.0",
                buildNumber: "300"
            )
            let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
            let service = AuthService(api: api, keychain: keychain, passkey: Phase09AuthStubPasskey(assertionError: nil))
            return AuthStore(auth: service, keychain: keychain)
        }

        private func makeSignedInAPI() throws -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.2.0",
                buildNumber: "300"
            )
            let keychain = InMemoryKeychain()
            try keychain.setString("bearer", forKey: KeychainKey.authToken)
            return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        }

        private func respondToVerify(status: Int, code: String) {
            let body = Data(#"{"data":null,"error":"Passkey sign-in failed","meta":{"errorCode":"\#(code)"}}"#.utf8)
            MockURLProtocol.install { req in
                let url = req.url!
                if url.path.hasSuffix("/api/auth/passkey/login-options") {
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Phase09AuthBody.passkeyOptions
                    )
                }
                return (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
            }
        }

        // MARK: - Passkey sign-in

        @Test("each named passkey failure gets its own sentence on the sign-in form", arguments: [
            (401, "passkey.challenge.expired", "auth.passkey.error.challengeExpired"),
            (404, "passkey.unknown", "auth.passkey.error.unknownPasskey"),
            (422, "passkey.response.invalid", "auth.passkey.error.responseInvalid"),
            (401, "passkey.verification.failed", "auth.passkey.error.rejected")
        ])
        func passkeyCodes(status: Int, code: String, key: String) async throws {
            let store = makeStore()
            respondToVerify(status: status, code: code)
            await store.loginWithPasskey(anchor: Phase09AuthStubAnchor())

            let error = try #require(store.lastError)
            guard case let .server(_, carried, _) = error else {
                Issue.record("expected .server, got \(error)")
                return
            }
            #expect(carried == code, "the 401 body reaches the mapping instead of collapsing to .unauthorized")
            #expect(error.signInFacingDescription == String(localized: String.LocalizationValue(key)))
            #expect(error.signInFacingDescription != HLError.unauthorized.userFacingDescription)
            #expect(store.phase == .unknown)
        }

        @Test("passkey.unknown sends the person to another way of signing in")
        func unknownPasskeyNamesAnotherWay() {
            let mapped = AuthStore.passkeyLoginFailure(.server(status: 404, code: "passkey.unknown", message: "x"))
            #expect(mapped.signInFacingDescription == String(localized: "auth.passkey.error.unknownPasskey"))
            #expect(mapped.signInFacingDescription != String(localized: "auth.passkey.error.rejected"))
        }

        @Test("only login-verify keeps its 401 body; the options leg and every other route keep theirs")
        func preservedPaths() {
            #expect(APIClient.preserves401Body(path: "/api/auth/passkey/login-verify"))
            #expect(!APIClient.preserves401Body(path: "/api/auth/passkey/login-options"))
            #expect(!APIClient.preserves401Body(path: "/api/auth/mfa/webauthn/verify"))
            #expect(!APIClient.preserves401Body(path: "/api/measurements"))
        }

        // MARK: - medication.intake.notTracked

        static let notTracked = HLError.server(
            status: 422,
            code: "medication.intake.notTracked",
            message: "This medication is kept as a record only."
        )

        @Test("the intake refusal reads as a human sentence, not the server prose")
        func intakeCopy() {
            let text = Self.notTracked.userFacingDescription
            #expect(text == String(localized: "med.intake.error.notTracked"))
            #expect(text != "This medication is kept as a record only.")
        }

        @Test("the intake refusal is final: never retried, never queued, dead-lettered with its own reason")
        func intakeIsFinal() {
            #expect(!Self.notTracked.isRetriable)
            #expect(!Self.notTracked.shouldPersistToOutbox)
            #expect(OutboxReplayService.discardReason(for: Self.notTracked) == .intakeNotTracked)
            #expect(OutboxReplayService.discardReason(for: HLError.server(status: 422, code: nil, message: "x")) == .serverRejected)
        }

        @Test("a bulk skip with intake_not_tracked carries the code, so the reminder path names it too")
        func bulkSkipCarriesCode() async throws {
            let api = try makeSignedInAPI()
            let outbox = try OutboxQueue(inMemory: true)
            let repo = MedicationsRepository(api: api, outbox: outbox)
            MockURLProtocol.install { req in
                let body = Data(#"""
                {"data":{"processed":1,"inserted":0,"updated":0,"duplicates":0,
                "skipped":[{"index":0,"reason":"intake_not_tracked"}],
                "entries":[{"index":0,"status":"skipped","reason":"intake_not_tracked"}]},"error":null}
                """#.utf8)
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            let entry = MedicationsRepository.BulkIntakeEntry(
                medicationId: "med-record",
                scheduledFor: Date(timeIntervalSince1970: 1_791_000_000),
                takenAt: Date(timeIntervalSince1970: 1_791_000_060),
                skipped: false,
                idempotencyKey: "k-1"
            )
            do {
                try await repo.replayReminderIntake(entry: entry, idempotencyKey: "k-1")
                Issue.record("expected the skip to throw")
            } catch let error as HLError {
                #expect(error.isMedicationIntakeNotTracked)
                #expect(error.userFacingDescription == String(localized: "med.intake.error.notTracked"))
                #expect(!error.shouldPersistToOutbox)
            }
        }
    }

#endif

// swiftlint:enable force_unwrapping
