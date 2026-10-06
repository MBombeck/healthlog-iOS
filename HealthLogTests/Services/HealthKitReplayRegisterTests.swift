#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    // swiftlint:disable force_unwrapping

    /// INT-A (#115 / 0.3) — the outbox replay is no longer the one path where a
    /// refused or unconfirmed HealthKit reading disappears without a trace.
    ///
    /// * A replayed page whose rows the server skips for a deterministic reason
    ///   (`value_out_of_range`) used to pass the acceptance gate and be deleted
    ///   by `onReplaySuccess`; the refused rows now go into the skip register
    ///   first.
    /// * A replayed page the server never confirmed used to age into the
    ///   dead-letter lane, which nothing in the app offers again; it now moves
    ///   into the skip register, and so do rows an earlier build dead-lettered.
    /// * Parked rows are counted for Sync Diagnostics.
    ///
    /// Driven against the real `APIClient` over `MockURLProtocol`.
    @Suite("HealthKit replay → skip register (INT-A)", .serialized, .mockURLSession)
    struct HealthKitReplayRegisterTests {
        static let owner = "account-int-a"

        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.0.4",
            buildNumber: "1"
        )

        private func makeAPI() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("bearer-a", forKey: KeychainKey.authToken)
            try? keychain.setString(Self.owner, forKey: KeychainKey.userID)
            return APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
        }

        private func respond(status: Int, _ json: String) {
            MockURLProtocol.install { req in
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(json.utf8))
            }
        }

        private func makeReplay(outbox: OutboxQueue, maxAttempts: Int = 8, deadLetterMinAge: TimeInterval = 7 * 86400)
            -> OutboxReplayService
        {
            let api = makeAPI()
            return OutboxReplayService(
                outbox: outbox,
                measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
                moodRepo: MoodRepository(api: api, outbox: outbox),
                medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
                currentUserProvider: { Self.owner },
                maxAttempts: maxAttempts,
                deadLetterMinAge: deadLetterMinAge,
                attemptBackoff: 0
            )
        }

        private static func readings(_ identities: [String]) -> [HealthKitBatchEntryDTO] {
            identities.enumerated().map { index, identity in
                HealthKitBatchEntryDTO(
                    hkIdentifier: HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
                    value: 0.95,
                    unit: "%",
                    startDate: Date(timeIntervalSince1970: TimeInterval(1_790_000_000 + index)),
                    endDate: Date(timeIntervalSince1970: TimeInterval(1_790_000_000 + index)),
                    externalId: identity
                )
            }
        }

        private func enqueue(_ outbox: OutboxQueue, _ identities: [String]) async throws {
            try await outbox.enqueueHealthKitBatch(
                Self.readings(identities),
                encoder: .hlBatch,
                idempotencyKey: "int-a-\(UUID().uuidString)",
                requiringCurrentOwner: Self.owner
            )
        }

        // MARK: - A refused row on replay

        /// `value_out_of_range` for index 0, `inserted` for index 1 — the shape
        /// of the deployed route (`entries[]` plus the mirrored `skipped[]`).
        private static let outOfRange = #"""
        {"data":{"processed":2,"inserted":1,"duplicates":0,
        "skipped":[{"index":0,"reason":"value_out_of_range"}],
        "entries":[{"index":0,"status":"skipped","reason":"value_out_of_range"},{"index":1,"status":"inserted"}]},"error":null}
        """#

        @Test("a replayed row the server refuses as out of range is registered, then the row drains")
        func replayRegistersOutOfRange() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            try await enqueue(outbox, ["fat-1", "fat-2"])
            respond(status: 200, Self.outOfRange)

            await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await makeReplay(outbox: outbox).runOnce()
            }

            #expect(await outbox.snapshot.isEmpty, "the page itself was answered")
            let rows = await register.rows(ownerID: Self.owner)
            #expect(rows.map(\.id) == ["fat-1"], "only the refused row, not the stored one")
            #expect(rows.first?.reason == MeasurementBatchAcceptance.Reason.valueOutOfRange)
            #expect(rows.first?.entry?.value == 0.95, "the exact posted row, for the re-offer")
        }

        @Test("a refused row the register cannot keep parks the page instead of draining it")
        func replayParksWhenRegisterFails() async throws {
            let lossy = HealthKitSkippedRowRegister(storage: SkipRegisterBacking(lossy: true).storage)
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            try await enqueue(outbox, ["fat-1", "fat-2"])
            respond(status: 200, Self.outOfRange)

            await HealthKitSkippedRowRegister.$bound.withValue(lossy) {
                await makeReplay(outbox: outbox).runOnce()
            }

            let parked = try #require(await outbox.snapshot.first)
            #expect(parked.attempts == 0, "parked, not counted toward the dead-letter lane")
            #expect(await outbox.parkedRowCount(ownerID: Self.owner) == 1)
            #expect(await outbox.parkedRowCount(ownerID: "account-b") == 0, "counted per account")
        }

        // MARK: - A page the server never confirmed

        /// A skip reason this build cannot classify: the acceptance gate holds,
        /// the replay counts an attempt.
        private static let unclassifiable = #"""
        {"data":{"processed":1,"inserted":0,"duplicates":0,
        "skipped":[{"index":0,"reason":"zz_from_the_future"}],
        "entries":[{"index":0,"status":"skipped","reason":"zz_from_the_future"}]},"error":null}
        """#

        @Test("a page never confirmed within the retry budget moves into the skip register, not the dead-letter lane")
        func unconfirmedPageMovesToRegister() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            try await enqueue(outbox, ["fat-9"])
            respond(status: 200, Self.unclassifiable)

            await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await makeReplay(outbox: outbox, maxAttempts: 1, deadLetterMinAge: 0).runOnce()
            }

            #expect(await outbox.snapshot.isEmpty)
            #expect(await outbox.deadLetterCount == 0, "nothing ages into a lane no one offers again")
            let rows = await register.rows(ownerID: Self.owner)
            #expect(rows.map(\.id) == ["fat-9"])
            #expect(rows.first?.reason == OutboxReplayService.notConfirmedReason)
        }

        /// The update path: an install that already dead-lettered a HealthKit
        /// page under an earlier build gets it back as a visible, re-offered row.
        @Test("a HealthKit page an earlier build dead-lettered moves into the skip register")
        func earlierDeadLetterMovesToRegister() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            try await enqueue(outbox, ["fat-old"])
            _ = try await outbox.markDeadLetters(maxAttempts: 0, minAge: 0)
            #expect(await outbox.deadLetterCount == 1)

            await HealthKitSkippedRowRegister.$bound.withValue(register) {
                await makeReplay(outbox: outbox).runOnce()
            }

            #expect(await outbox.deadLetterCount == 0)
            #expect(await register.rows(ownerID: Self.owner).map(\.id) == ["fat-old"])
        }
    }

    // swiftlint:enable force_unwrapping

#endif
