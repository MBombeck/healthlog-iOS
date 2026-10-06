// N1 — `notificationPrefs.medication.clientManaged` was never written.
//
// `NotificationsRepository.setMedicationClientManaged` existed since CU-20 and
// had no caller, so on an instance that can reach the App Store app over APNs
// every dose was announced twice: once by the phone's local reminder, once by
// the server's `MEDICATION_REMINDER` push. These suites pin the decision, the
// account fence, the wire shapes of server v1.39.3 and the composition.

// swiftlint:disable force_unwrapping file_length type_body_length

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    // MARK: - Fixtures (server v1.39.3 shapes)

    enum MedicationReminderDeliveryFixtures {
        static let owner = "user-n1"

        /// `notificationPrefs` exactly as `parseNotificationPrefs` resolves it at
        /// v1.39.3 (`src/lib/validations/notification-prefs.ts`), which is what
        /// both `GET /api/auth/me` and `GET|PATCH /api/auth/me/notification-prefs`
        /// carry.
        static func prefsJSON(clientManaged: Bool, deliveryDefault: String = "server") -> String {
            """
            {"medication":{"clientManaged":\(clientManaged),"deliveryDefault":"\(deliveryDefault)",\
            "lowStockRunwayDays":7,"reorderLeadDays":10},"mood":{"reminderHour":22},\
            "cycle":{"clientManaged":false},"coach":{"nudgesEnabled":true,"nudgeMedication":true,\
            "nudgeVitals":true,"nudgeRoutine":true,"nudgeFrequency":"weekly","ambientSuggestions":true,\
            "nudgeAiComposed":false},"measurementReminder":{"clientManaged":false}}
            """
        }

        /// A tracked daily medication with reminders on (the v1.39.1 list shape).
        static func remindedMedication(id: String = "med-a") throws -> Medication {
            try MedicationTrackIntakeV1391Tests.tracked(id: id)
        }

        /// The same medication with its reminders switched off.
        static func silencedMedication(id: String = "med-a") throws -> Medication {
            let json = MedicationTrackIntakeV1391Tests.medicationJSON(
                id: id, trackIntake: true, schedules: [MedicationTrackIntakeV1391Tests.schedule("21:00")]
            ).replacingOccurrences(of: #""notificationsEnabled":true"#, with: #""notificationsEnabled":false"#)
            return try MedicationTrackIntakeV1391Tests.decode(json)
        }

        static let serverPushes = MedicationReminderServerDelivery(clientManaged: false, deliveryDefault: "server")
        static let serverQuiet = MedicationReminderServerDelivery(clientManaged: true, deliveryDefault: "server")
        static let serverPinned = MedicationReminderServerDelivery(clientManaged: true, deliveryDefault: "client")
    }

    // MARK: - Policy

    @Suite("N1 — clientManaged decision table")
    struct MedicationReminderDeliveryPolicyTests {
        private typealias F = MedicationReminderDeliveryFixtures

        @Test("delivers locally, server still pushes → claim")
        func claimsWhenServerStillPushes() {
            #expect(MedicationReminderDeliveryPolicy.decide(
                server: F.serverPushes, deliversLocally: true, claimedHere: false
            ) == .claim)
        }

        @Test("delivers locally, server already quiet → remember, no write")
        func notesExistingSuppression() {
            #expect(MedicationReminderDeliveryPolicy.decide(
                server: F.serverQuiet, deliversLocally: true, claimedHere: false
            ) == .noteClaim)
            #expect(MedicationReminderDeliveryPolicy.decide(
                server: F.serverQuiet, deliversLocally: true, claimedHere: true
            ) == .none)
        }

        @Test("stops delivering after claiming → release")
        func releasesOwnClaim() {
            #expect(MedicationReminderDeliveryPolicy.decide(
                server: F.serverQuiet, deliversLocally: false, claimedHere: true
            ) == .release)
        }

        @Test("never claimed here → another device's flag is left alone")
        func leavesForeignClaim() {
            #expect(MedicationReminderDeliveryPolicy.decide(
                server: F.serverQuiet, deliversLocally: false, claimedHere: false
            ) == .none)
        }

        @Test("deliveryDefault \"client\" pins the flag → no write that cannot land")
        func pinnedByDeliveryDefault() {
            #expect(MedicationReminderDeliveryPolicy.decide(
                server: F.serverPinned, deliversLocally: false, claimedHere: true
            ) == .dropClaim)
        }

        @Test("server without the field → nothing, in every state")
        func olderServerNeverWritten() {
            for delivers in [true, false] {
                for claimed in [true, false] {
                    #expect(MedicationReminderDeliveryPolicy.decide(
                        server: nil, deliversLocally: delivers, claimedHere: claimed
                    ) == .none)
                }
            }
        }

        @Test("local delivery needs the permission AND a medication the planner arms")
        func deliversLocallyInputs() throws {
            let reminded = try F.remindedMedication()
            #expect(MedicationReminderDeliveryPolicy.deliversLocally(
                notificationsAuthorized: true, medications: [reminded]
            ))
            #expect(!MedicationReminderDeliveryPolicy.deliversLocally(
                notificationsAuthorized: false, medications: [reminded]
            ))
            #expect(try !MedicationReminderDeliveryPolicy.deliversLocally(
                notificationsAuthorized: true, medications: [F.silencedMedication()]
            ))
            #expect(try !MedicationReminderDeliveryPolicy.deliversLocally(
                notificationsAuthorized: true, medications: [MedicationTrackIntakeV1391Tests.recordOnly()]
            ))
            #expect(!MedicationReminderDeliveryPolicy.deliversLocally(
                notificationsAuthorized: true, medications: []
            ))
        }
    }

    // MARK: - Coordinator

    /// Records every write and scripts its outcome.
    private final class ClaimWriterSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [Bool] = []
        private var _releases = 0
        var failWrites = false
        var failRelease = false
        var echoDeliveryDefault = "server"

        var writes: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return _writes
        }

        var releases: Int {
            lock.lock()
            defer { lock.unlock() }
            return _releases
        }

        func write(_ value: Bool) throws -> MedicationReminderServerDelivery? {
            lock.lock()
            _writes.append(value)
            lock.unlock()
            if failWrites { throw HLError.offline }
            return MedicationReminderServerDelivery(clientManaged: value, deliveryDefault: echoDeliveryDefault)
        }

        func release() throws {
            lock.lock()
            _releases += 1
            lock.unlock()
            if failRelease { throw HLError.offline }
        }
    }

    @MainActor
    @Suite("N1 — the coordinator writes clientManaged only on a real change")
    struct MedicationReminderDeliveryCoordinatorTests {
        private typealias F = MedicationReminderDeliveryFixtures

        private struct Harness {
            let coordinator: MedicationReminderDeliveryCoordinator
            let spy: ClaimWriterSpy
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: AuthenticatedSessionLease
            let defaults: UserDefaults
            let marker: MedicationReminderClaimMarker
        }

        private func makeHarness(authorized: Bool, claimed: Bool = false) throws -> Harness {
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.n1.\(UUID().uuidString)"))
            let marker = MedicationReminderClaimMarker(defaults: defaults)
            if claimed { marker.claim(for: F.owner) }
            let spy = ClaimWriterSpy()
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try #require(registry.activate(ownerID: F.owner))
            let coordinator = MedicationReminderDeliveryCoordinator(
                defaults: defaults,
                notificationsAuthorized: { authorized },
                writeClaim: { try spy.write($0) },
                releaseOnSignOut: { try spy.release() }
            )
            return Harness(
                coordinator: coordinator, spy: spy, registry: registry,
                lease: lease, defaults: defaults, marker: marker
            )
        }

        @Test("permission granted, reminders armed, server still pushes → PATCH true once")
        func grantedClaimsOnce() async throws {
            let h = try makeHarness(authorized: true)
            h.coordinator.noteServerDelivery(F.serverPushes, lease: h.lease)
            try h.coordinator.noteMedications([F.remindedMedication()], ownerID: F.owner)
            await h.coordinator.settle()
            #expect(h.spy.writes == [true])
            #expect(h.marker.isClaimed(by: F.owner))

            // The next load (every foreground, every edit) finds nothing to do.
            try h.coordinator.noteMedications([F.remindedMedication()], ownerID: F.owner)
            h.coordinator.noteServerDelivery(F.serverQuiet, lease: h.lease)
            await h.coordinator.settle()
            #expect(h.spy.writes == [true])
        }

        @Test("server already quiet → no request, the claim is remembered")
        func alreadyQuietWritesNothing() async throws {
            let h = try makeHarness(authorized: true)
            h.coordinator.noteServerDelivery(F.serverQuiet, lease: h.lease)
            try h.coordinator.noteMedications([F.remindedMedication()], ownerID: F.owner)
            await h.coordinator.settle()
            #expect(h.spy.writes.isEmpty)
            #expect(h.marker.isClaimed(by: F.owner))
        }

        @Test("permission denied after claiming → PATCH false, claim dropped")
        func deniedReleases() async throws {
            let h = try makeHarness(authorized: false, claimed: true)
            h.coordinator.noteServerDelivery(F.serverQuiet, lease: h.lease)
            try h.coordinator.noteMedications([F.remindedMedication()], ownerID: F.owner)
            await h.coordinator.settle()
            #expect(h.spy.writes == [false])
            #expect(!h.marker.isClaimed(by: F.owner))
        }

        @Test("permission denied, never claimed here → the server is never silenced, nothing written")
        func deniedNeverClaims() async throws {
            let h = try makeHarness(authorized: false)
            h.coordinator.noteServerDelivery(F.serverPushes, lease: h.lease)
            try h.coordinator.noteMedications([F.remindedMedication()], ownerID: F.owner)
            await h.coordinator.settle()
            #expect(h.spy.writes.isEmpty)

            // …and a flag another device set stays where it is.
            h.coordinator.noteServerDelivery(F.serverQuiet, lease: h.lease)
            await h.coordinator.settle()
            #expect(h.spy.writes.isEmpty)
        }

        @Test("reminders switched off in the app after claiming → PATCH false")
        func remindersOffReleases() async throws {
            let h = try makeHarness(authorized: true, claimed: true)
            h.coordinator.noteServerDelivery(F.serverQuiet, lease: h.lease)
            try h.coordinator.noteMedications([F.silencedMedication()], ownerID: F.owner)
            await h.coordinator.settle()
            #expect(h.spy.writes == [false])
            #expect(!h.marker.isClaimed(by: F.owner))
        }

        @Test("server without the field → no request, whatever the device does")
        func olderServerWritesNothing() async throws {
            let h = try makeHarness(authorized: true, claimed: true)
            h.coordinator.noteServerDelivery(nil, lease: h.lease)
            try h.coordinator.noteMedications([F.remindedMedication()], ownerID: F.owner)
            await h.coordinator.settle()
            try h.coordinator.noteMedications([F.silencedMedication()], ownerID: F.owner)
            await h.coordinator.settle()
            #expect(h.spy.writes.isEmpty)
        }

        @Test("deliveryDefault \"client\" pins the flag → no release write, claim dropped")
        func pinnedFlagIsNotFought() async throws {
            let h = try makeHarness(authorized: false, claimed: true)
            h.coordinator.noteServerDelivery(F.serverPinned, lease: h.lease)
            try h.coordinator.noteMedications([F.remindedMedication()], ownerID: F.owner)
            await h.coordinator.settle()
            #expect(h.spy.writes.isEmpty)
            #expect(!h.marker.isClaimed(by: F.owner))
        }

        @Test("a retired lease or another account's list writes nothing")
        func fencedToTheLease() async throws {
            let h = try makeHarness(authorized: true)
            h.coordinator.noteServerDelivery(F.serverPushes, lease: h.lease)
            try h.coordinator.noteMedications([F.remindedMedication()], ownerID: "someone-else")
            await h.coordinator.settle()
            #expect(h.spy.writes.isEmpty)

            h.registry.invalidate()
            try h.coordinator.noteMedications([F.remindedMedication()], ownerID: F.owner)
            await h.coordinator.settle()
            #expect(h.spy.writes.isEmpty)
            #expect(!h.marker.isClaimed(by: F.owner))
        }

        @Test("a failed claim is not remembered; the next load tries again")
        func failedClaimRetriesOnNextLoad() async throws {
            let h = try makeHarness(authorized: true)
            h.spy.failWrites = true
            h.coordinator.noteServerDelivery(F.serverPushes, lease: h.lease)
            try h.coordinator.noteMedications([F.remindedMedication()], ownerID: F.owner)
            await h.coordinator.settle()
            #expect(h.spy.writes == [true])
            #expect(!h.marker.isClaimed(by: F.owner))

            h.spy.failWrites = false
            try h.coordinator.noteMedications([F.remindedMedication()], ownerID: F.owner)
            await h.coordinator.settle()
            #expect(h.spy.writes == [true, true])
            #expect(h.marker.isClaimed(by: F.owner))
        }

        @Test("sign-out releases this device's claim; without a claim it sends nothing")
        func signOutReleasesOnlyOwnClaim() async throws {
            let claimed = try makeHarness(authorized: true, claimed: true)
            await claimed.coordinator.releaseForSignOut(ownerID: F.owner)
            #expect(claimed.spy.releases == 1)
            #expect(!claimed.marker.isClaimed(by: F.owner))

            let unclaimed = try makeHarness(authorized: true)
            await unclaimed.coordinator.releaseForSignOut(ownerID: F.owner)
            #expect(unclaimed.spy.releases == 0)

            let otherOwner = try makeHarness(authorized: true, claimed: true)
            await otherOwner.coordinator.releaseForSignOut(ownerID: "someone-else")
            #expect(otherOwner.spy.releases == 0)
        }

        @Test("a failed sign-out release keeps the claim for the account's next session")
        func failedSignOutReleaseKeepsClaim() async throws {
            let h = try makeHarness(authorized: true, claimed: true)
            h.spy.failRelease = true
            await h.coordinator.releaseForSignOut(ownerID: F.owner)
            #expect(h.spy.releases == 1)
            #expect(h.marker.isClaimed(by: F.owner))
        }
    }

    // MARK: - Wire (server v1.39.3)

    @Suite("N1 — clientManaged on the wire (server v1.39.3)", .serialized, .mockURLSession)
    struct MedicationReminderDeliveryWireTests {
        private typealias F = MedicationReminderDeliveryFixtures

        private func makeAPI() -> APIClient {
            APIClient(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://test.healthlog.local")!,
                    bundleID: "dev.healthlog.app",
                    appVersion: "0.1.0",
                    buildNumber: "1"
                ),
                keychain: InMemoryKeychain(),
                sessionConfiguration: .mock()
            )
        }

        private static func ok(_ req: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{\"data\":\(json),\"error\":null}".utf8)
            )
        }

        @Test("/me carries notificationPrefs.medication → decoded; an older /me → nil")
        func authMeDecodes() throws {
            let current = #"{"id":"u","avatarUrl":null,"notificationPrefs":"# + F.prefsJSON(clientManaged: true) + "}"
            let decoded = try JSONDecoder.hlDefault.decode(AuthMeServerPrefs.self, from: Data(current.utf8))
            #expect(decoded.medicationReminderDelivery == F.serverQuiet)

            let pinned = #"{"notificationPrefs":"# + F.prefsJSON(clientManaged: true, deliveryDefault: "client") + "}"
            let pinnedDecoded = try JSONDecoder.hlDefault.decode(AuthMeServerPrefs.self, from: Data(pinned.utf8))
            #expect(pinnedDecoded.medicationReminderDelivery?.isPinnedToClient == true)

            // Before v1.38.15 `/me` had no `notificationPrefs` at all.
            let older = try JSONDecoder.hlDefault.decode(
                AuthMeServerPrefs.self,
                from: Data(#"{"id":"u","unitPreference":"metric"}"#.utf8)
            )
            #expect(older.medicationReminderDelivery == nil)

            // A drifted block never takes the settings load down.
            let drifted = try JSONDecoder.hlDefault.decode(
                AuthMeServerPrefs.self,
                from: Data(#"{"unitPreference":"metric","notificationPrefs":{"medication":"x"}}"#.utf8)
            )
            #expect(drifted.medicationReminderDelivery == nil)
            #expect(drifted.unitPreference == "metric")
        }

        @Test("the claim PATCH sends exactly the medication leaf and returns the resolved echo")
        func claimWriteShapeAndEcho() async throws {
            let requests = N1RequestLog()
            MockURLProtocol.install { req in
                requests.note(req)
                if req.httpMethod == "PATCH" {
                    return Self.ok(
                        req,
                        #"{"medication":{"clientManaged":true,"deliveryDefault":"server","lowStockRunwayDays":7,"reorderLeadDays":10},"updatedAt":"2026-09-27T10:00:00.000Z"}"#
                    )
                }
                return Self.ok(req, "{}")
            }
            let repo = NotificationsRepository(api: makeAPI())
            let echoed = try await repo.setMedicationClientManaged(true)

            #expect(echoed == F.serverQuiet)
            let write = try #require(requests.items.first { $0.method == "PATCH" })
            #expect(write.path == "/api/auth/me/notification-prefs")
            #expect(write.body?.keys.sorted() == ["medication"], "no token held yet → no baseUpdatedAt")
            let medication = try #require(write.body?["medication"] as? [String: Any])
            #expect(medication.count == 1)
            #expect(medication["clientManaged"] as? Bool == true)
        }

        @Test("the sign-out release is one unconditional PATCH clientManaged:false, no retry")
        func releaseWriteShape() async throws {
            let requests = N1RequestLog()
            MockURLProtocol.install { req in
                requests.note(req)
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"unavailable"}"#.utf8)
                )
            }
            let repo = NotificationsRepository(api: makeAPI())
            await #expect(throws: (any Error).self) {
                try await repo.releaseMedicationClientManagedOnSignOut()
            }
            #expect(requests.items.count == 1, "maxRetries 0: sign-out never waits on a retry ladder")
            let write = try #require(requests.items.first)
            #expect(write.method == "PATCH")
            #expect(write.path == "/api/auth/me/notification-prefs")
            #expect(write.body?["baseUpdatedAt"] == nil)
            let medication = try #require(write.body?["medication"] as? [String: Any])
            #expect(medication["clientManaged"] as? Bool == false)
        }
    }

    // MARK: - Composition

    @MainActor
    @Suite("N1 — the composition root wires clientManaged", .serialized, .mockURLSession)
    struct MedicationReminderDeliveryCompositionTests {
        private typealias F = MedicationReminderDeliveryFixtures

        private nonisolated static let prefsPath = "/api/auth/me/notification-prefs"

        private func makeContainer(requests: N1RequestLog, authorized: Bool) throws -> AppContainer {
            MockURLProtocol.install { req in
                requests.note(req)
                if req.httpMethod == "PATCH", req.url?.path == Self.prefsPath {
                    let flag = requests.items.last?.clientManaged ?? false
                    return (
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":"#.utf8) + Data(F.prefsJSON(clientManaged: flag).utf8) + Data(#","error":null}"#.utf8)
                    )
                }
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"not found"}"#.utf8)
                )
            }
            let keychain = InMemoryKeychain()
            try keychain.setString(F.owner, forKey: KeychainKey.userID)
            try keychain.setString("token-n1", forKey: KeychainKey.authToken)
            let container = AppContainer(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://test.healthlog.local"),
                    bundleID: "dev.healthlog.app.tests",
                    appVersion: "0.0.0-test",
                    buildNumber: "0"
                ),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter(),
                apiSessionConfiguration: .mock(),
                notificationsAuthorized: { authorized }
            )
            container.authStore.setPhaseForTesting(
                .authenticated(User(id: F.owner, email: nil, username: nil, displayName: nil, createdAt: .now))
            )
            return container
        }

        private func clearMarker() {
            UserDefaults.standard.removeObject(forKey: MedicationReminderClaimMarker.defaultsKey)
        }

        @Test("the /me hook and the medications hook reach the coordinator, which claims")
        func hooksReachCoordinator() async throws {
            clearMarker()
            defer { clearMarker() }
            let requests = N1RequestLog()
            let container = try makeContainer(requests: requests, authorized: true)
            let lease = try #require(container.authenticatedSessionRegistry.capture(ownerID: F.owner))

            let onServer = try #require(container.settingsStore.onMedicationReminderServerDelivery)
            onServer(F.serverPushes, lease)
            let onMeds = try #require(container.medicationsStore.onMedicationsDidChange)
            try onMeds([F.remindedMedication()])
            await container.medicationReminderDelivery.settle()

            let writes = requests.items.filter { $0.method == "PATCH" && $0.path == Self.prefsPath }
            #expect(writes.map(\.clientManaged) == [true])
            #expect(MedicationReminderClaimMarker(defaults: .standard).isClaimed(by: F.owner))
        }

        @Test("sign-out takes the claim back BEFORE the credentials are revoked")
        func signOutReleasesBeforeRevoke() async throws {
            clearMarker()
            defer { clearMarker() }
            MedicationReminderClaimMarker(defaults: .standard).claim(for: F.owner)
            let requests = N1RequestLog()
            let container = try makeContainer(requests: requests, authorized: true)

            await container.authStore.logout()

            let paths = requests.items.map { "\($0.method) \($0.path)" }
            let release = try #require(paths.firstIndex(of: "PATCH \(Self.prefsPath)"))
            let revoke = try #require(paths.firstIndex { $0 == "POST /api/auth/logout" || $0 == "POST /api/auth/refresh" })
            #expect(release < revoke)
            #expect(requests.items[release].clientManaged == false)
            #expect(!MedicationReminderClaimMarker(defaults: .standard).isClaimed(by: F.owner))
        }

        @Test("sign-out on a device that never claimed sends no prefs write")
        func signOutWithoutClaimIsSilent() async throws {
            clearMarker()
            defer { clearMarker() }
            let requests = N1RequestLog()
            let container = try makeContainer(requests: requests, authorized: true)

            await container.authStore.logout()

            #expect(!requests.items.contains { $0.method == "PATCH" && $0.path == Self.prefsPath })
        }
    }

    /// Every request the mock transport saw, with its decoded JSON body.
    private final class N1RequestLog: @unchecked Sendable {
        struct Entry {
            let method: String
            let path: String
            let body: [String: Any]?

            var clientManaged: Bool? {
                (body?["medication"] as? [String: Any])?["clientManaged"] as? Bool
            }
        }

        private let lock = NSLock()
        private var _items: [Entry] = []

        var items: [Entry] {
            lock.lock()
            defer { lock.unlock() }
            return _items
        }

        func note(_ req: URLRequest) {
            let body = req.n1BodyOrStream().flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            lock.lock()
            _items.append(Entry(method: req.httpMethod ?? "?", path: req.url?.path ?? "?", body: body))
            lock.unlock()
        }
    }

    private extension URLRequest {
        /// URLSession moves a write body onto `httpBodyStream` by the time a
        /// `URLProtocol` sees it.
        func n1BodyOrStream() -> Data? {
            if let body = httpBody { return body }
            guard let stream = httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    // swiftlint:enable force_unwrapping file_length type_body_length
#endif
