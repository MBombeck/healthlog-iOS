import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    // swiftlint:disable force_unwrapping

    /// **v0.7.0 W-SEC-M-2 — defensive allowlist for `medicationId` from
    /// APN payloads.**
    ///
    /// `DeepLinkRoute.idAllowlist` covers IDs that travel through a
    /// `healthlog://medications/<id>` URL. A `medicationId` pulled
    /// straight off an APN's `userInfo` bypassed that gate and reached
    /// `MedicationsRepository.recordFromReminder` unchecked. These
    /// tests pin that:
    ///
    ///  1. The pure validator accepts cuid-style IDs (`med_xxxxxxxxxxxx`,
    ///     `cuid2` 24-char, UUIDs) and short alnum + `_` + `-` strings
    ///     up to 64 chars.
    ///  2. The validator rejects path-traversal payloads (`..`, `/`,
    ///     URL-encoded bytes that survived decoding), over-length
    ///     blobs, embedded whitespace, and unicode look-alikes.
    ///  3. `dispatchAction(.medicationTaken / .medicationSkipped)`
    ///     never POSTs to `/api/medications/intake/bulk` when the
    ///     payload's `medicationId` fails the allowlist — even though
    ///     the field is non-nil. Falls back to the medications-tab
    ///     deep-link instead.
    ///  4. `sanitisedForSnooze` strips the rejected `medicationId`
    ///     before the snooze re-schedule fires (so the rescheduled
    ///     banner can never re-introduce a tampered ID into the action
    ///     pipeline).
    @Suite("NotificationService — medicationId allowlist guard (W-SEC-M-2)", .serialized)
    @MainActor
    struct NotificationServiceMedicationIdAllowlistTests {
        // MARK: - Pure validator unit contract

        @Test(
            "validatedMedicationId accepts cuid2 / med_ / UUID / short alnum",
            arguments: [
                "med_abc123",
                "ck1234567890abcdefghij",
                "01HFA9BZW4P0Y8E5GQXN7TZ3KM",
                "550e8400-e29b-41d4-a716-446655440000",
                "a",
                "Z9",
                String(repeating: "x", count: 64)
            ]
        )
        func validatorAcceptsAllowlistedIds(input: String) {
            #expect(NotificationService.validatedMedicationId(input) == input)
        }

        @Test(
            "validatedMedicationId rejects path-traversal + over-length + whitespace + unicode",
            arguments: [
                "../etc/passwd",
                "a/b",
                "a b",
                "a\nb",
                "id\u{200B}injected", // zero-width-space (unicode look-alike for nothing)
                "ümlaut",
                "%2F..%2Fbad",
                String(repeating: "x", count: 65), // one over the 64-char cap
                "" // empty string is not 1..64
            ]
        )
        func validatorRejectsBogusIds(input: String) {
            #expect(NotificationService.validatedMedicationId(input) == nil)
        }

        @Test("validatedMedicationId returns nil for nil input")
        func validatorRejectsNil() {
            #expect(NotificationService.validatedMedicationId(nil) == nil)
        }

        // MARK: - dispatchAction integration

        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.7.0",
            buildNumber: "1"
        )

        private func makeAPI() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            return APIClient(
                environment: Self.env,
                keychain: keychain,
                sessionConfiguration: .mock()
            )
        }

        private func payloadWithRawMedicationId(_ id: String) -> APNsPayload {
            APNsPayload(
                title: "Lisinopril",
                body: "Mittag-Dosis",
                eventType: "MEDICATION_REMINDER",
                metricType: nil,
                deepLink: nil,
                medicationId: id,
                scheduleId: "sched-1",
                scheduledFor: Date(timeIntervalSince1970: 1_779_710_400)
            )
        }

        nonisolated static func okResponse(_ req: URLRequest) -> HTTPURLResponse {
            HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        }

        @Test("med.taken with traversal-style medicationId never POSTs to bulk-intake")
        func medTakenRejectsTraversalId() async throws {
            let appRouter = AppRouter()
            let api = makeAPI()
            let outbox = try OutboxQueue(inMemory: true)
            let repo = MedicationsRepository(api: api, outbox: outbox)

            nonisolated(unsafe) var sawBulkIntakePost = false
            MockURLProtocol.handler = { req in
                if req.url?.path == "/api/medications/intake/bulk" {
                    sawBulkIntakePost = true
                }
                let body = #"{"data":{"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"inserted","id":"new"}]}}"#
                return (Self.okResponse(req), Data(body.utf8))
            }
            let svc = NotificationService(
                api: api,
                environment: Self.env,
                keychain: InMemoryKeychain(),
                deepLinks: DeepLinkRouter(router: appRouter, isAuthenticated: { true }),
                medicationsRepo: repo
            )

            await svc.dispatchAction(
                actionID: NotificationService.actionMedicationTaken,
                payload: payloadWithRawMedicationId("../../../etc/passwd")
            )

            #expect(
                sawBulkIntakePost == false,
                "Traversal-style medicationId reached `/api/medications/intake/bulk` — allowlist regression"
            )
            // Fall-through path: medications-tab deep-link (no id) → `.unknown` route → no detail push.
            #expect(appRouter.medsPath.isEmpty)
        }

        @Test("med.skipped with over-length medicationId never POSTs to bulk-intake")
        func medSkippedRejectsOverlengthId() async throws {
            let appRouter = AppRouter()
            let api = makeAPI()
            let outbox = try OutboxQueue(inMemory: true)
            let repo = MedicationsRepository(api: api, outbox: outbox)
            let overLong = String(repeating: "A", count: 200)

            nonisolated(unsafe) var sawBulkIntakePost = false
            MockURLProtocol.handler = { req in
                if req.url?.path == "/api/medications/intake/bulk" {
                    sawBulkIntakePost = true
                }
                let body = #"{"data":{"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"inserted","id":"new"}]}}"#
                return (Self.okResponse(req), Data(body.utf8))
            }
            let svc = NotificationService(
                api: api,
                environment: Self.env,
                keychain: InMemoryKeychain(),
                deepLinks: DeepLinkRouter(router: appRouter, isAuthenticated: { true }),
                medicationsRepo: repo
            )

            await svc.dispatchAction(
                actionID: NotificationService.actionMedicationSkipped,
                payload: payloadWithRawMedicationId(overLong)
            )

            #expect(
                sawBulkIntakePost == false,
                "Over-length medicationId reached `/api/medications/intake/bulk` — allowlist regression"
            )
        }

        @Test("med.taken with whitespace-injected medicationId never POSTs to bulk-intake")
        func medTakenRejectsWhitespace() async throws {
            let appRouter = AppRouter()
            let api = makeAPI()
            let outbox = try OutboxQueue(inMemory: true)
            let repo = MedicationsRepository(api: api, outbox: outbox)

            nonisolated(unsafe) var sawBulkIntakePost = false
            MockURLProtocol.handler = { req in
                if req.url?.path == "/api/medications/intake/bulk" {
                    sawBulkIntakePost = true
                }
                let body = #"{"data":{"processed":1,"inserted":1,"duplicates":0,"entries":[]}}"#
                return (Self.okResponse(req), Data(body.utf8))
            }
            let svc = NotificationService(
                api: api,
                environment: Self.env,
                keychain: InMemoryKeychain(),
                deepLinks: DeepLinkRouter(router: appRouter, isAuthenticated: { true }),
                medicationsRepo: repo
            )

            await svc.dispatchAction(
                actionID: NotificationService.actionMedicationTaken,
                payload: payloadWithRawMedicationId("med id space")
            )

            #expect(sawBulkIntakePost == false)
        }

        // MARK: - sanitisedForSnooze

        @Test("sanitisedForSnooze strips rejected medicationId, keeps the rest of the payload")
        func sanitisedSnoozeStripsBogusId() {
            let bogus = payloadWithRawMedicationId("../etc/passwd")
            let cleaned = NotificationService.sanitisedForSnooze(payload: bogus)
            #expect(cleaned != nil)
            #expect(cleaned?.medicationId == nil, "Bogus medicationId not stripped by sanitisedForSnooze")
            // Untouched fields pass through.
            #expect(cleaned?.title == bogus.title)
            #expect(cleaned?.scheduleId == bogus.scheduleId)
            #expect(cleaned?.scheduledFor == bogus.scheduledFor)
            #expect(cleaned?.eventType == bogus.eventType)
        }

        @Test("sanitisedForSnooze preserves allowlisted medicationId")
        func sanitisedSnoozePreservesGoodId() {
            let good = payloadWithRawMedicationId("med_abc123")
            let cleaned = NotificationService.sanitisedForSnooze(payload: good)
            #expect(cleaned?.medicationId == "med_abc123")
        }

        @Test("buildMedicationSnoozeRequest with sanitised bogus ID omits medicationId from userInfo")
        func snoozeRequestOmitsBogusId() {
            let bogus = payloadWithRawMedicationId("../etc/passwd")
            let cleaned = NotificationService.sanitisedForSnooze(payload: bogus)
            let req = NotificationService.buildMedicationSnoozeRequest(payload: cleaned)
            #expect(
                req.content.userInfo["medicationId"] == nil,
                "Bogus medicationId leaked into snoozed banner's userInfo — regression"
            )
            // Schedule id + scheduledFor passing through are not security
            // sensitive: scheduleId and scheduledFor never enter a server
            // POST without a co-validated medicationId.
        }
    }
#endif
