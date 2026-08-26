import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// **Phase 07 / plan 07-06 — what a heart-event page is allowed to prove.**
    ///
    /// The query half of the sweep needs an authorized `HKHealthStore`, which a
    /// unit test does not have. Every rule this plan adds lives on the other side
    /// of that split, so the suite drives `transmit` directly against the **real**
    /// `APIClient` over `MockURLProtocol` (PROJECT_GUIDE.md: no mock server, or
    /// schema drift goes unseen) and hands the resulting page to the shared commit
    /// rule — the same rule `DurableHealthCursorStore.commit` applies internally.
    ///
    /// No real health sample is constructed and no event value is ever logged: the
    /// entries are synthetic wire rows carrying `value = 1, unit = "event"`, which
    /// is exactly what the importer emits.
    @Suite("Heart-event import durability — admitted, exact, durable", .serialized)
    struct HeartEventImportDurabilityTests {
        static let owner = "account-a"
        private static let highHeartRate = HKCategoryTypeIdentifier.highHeartRateEvent.rawValue

        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )

        /// Retained on purpose — `AuthenticatedSessionLease` holds the registry
        /// weakly, so a dropped registry turns every admission stale.
        private struct Admitted {
            let registry: AuthenticatedSessionLeaseRegistry
            let lease: HealthSyncAuthenticatedLease
        }

        private func admit(owner: String = owner) throws -> Admitted {
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: owner)
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: owner,
                source: .heartEvent,
                bearerProvider: { "bearer-a" }
            )
            return Admitted(registry: registry, lease: lease)
        }

        private func makeUploader() -> MeasurementBatchUploader {
            let keychain = InMemoryKeychain()
            try? keychain.setString("bearer-a", forKey: KeychainKey.authToken)
            try? keychain.setString(Self.owner, forKey: KeychainKey.userID)
            let api = APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
            return MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0),
                syncTrigger: SyncTriggerContext(),
                authenticationSnapshot: {
                    MeasurementUploadAuthenticationSnapshot(ownerUserID: Self.owner, bearerToken: "bearer-a")
                }
            )
        }

        private func makeImporter(
            uploader: MeasurementBatchUploader,
            lease: HealthSyncAuthenticatedLease,
            retry: (any HealthSyncBatchRetryEnqueuing)?
        ) -> HeartHealthEventImporter {
            HeartHealthEventImporter(
                store: HKHealthStore(),
                uploader: uploader,
                userID: Self.owner,
                defaults: UserDefaults(suiteName: "hk-event-durability-\(UUID().uuidString)")!,
                admission: { lease },
                cursors: nil,
                retry: retry
            )
        }

        /// Two flagged events, in the exact wire shape the importer emits.
        private static func entries(_ identities: [String]) -> [HealthKitBatchEntryDTO] {
            identities.enumerated().map { index, identity in
                HealthKitBatchEntryDTO(
                    hkIdentifier: highHeartRate,
                    value: 1,
                    unit: "event",
                    startDate: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                    endDate: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                    categoryValue: 1,
                    externalId: identity
                )
            }
        }

        private func respond(_ json: String, status: Int = 200) {
            MockURLProtocol.handler = { req in
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(json.utf8))
            }
        }

        private static func decide(_ page: HealthSyncPageOutcome) -> HealthSyncCommitDecision {
            HealthSyncCursorPolicy.installed.decide(page)
        }

        // MARK: - Exact acceptance

        @Test("a fully accepted page carries every index and lets the cursor move")
        func acceptedPageCommits() async throws {
            respond("""
            {"processed":2,"inserted":2,"duplicates":0,"skipped":[],
             "entries":[{"index":0,"status":"inserted"},{"index":1,"status":"inserted"}]}
            """)
            let admitted = try admit()
            let importer = makeImporter(uploader: makeUploader(), lease: admitted.lease, retry: nil)

            let page = await importer.transmit(Self.entries(["evt-1", "evt-2"]), requiring: admitted.lease)

            #expect(page.postedCount == 2)
            #expect(page.coversEveryPostedIndex)
            #expect(!page.hasNonterminalEntry)
            #expect(page.entries.map(\.stableIdentity) == ["evt-1", "evt-2"])
            #expect(Self.decide(page) == .commit)
        }

        @Test("an index the server cannot map holds — and only that index")
        func unmappableIndexHoldsAlone() async throws {
            respond("""
            {"processed":2,"inserted":1,"duplicates":0,
             "skipped":[{"index":1,"reason":"unmappable_identifier"}],
             "entries":[{"index":0,"status":"inserted"},
                        {"index":1,"status":"skipped","reason":"unmappable_identifier"}]}
            """)
            let admitted = try admit()
            let retry = RecordingStatsRetryQueue()
            let importer = makeImporter(uploader: makeUploader(), lease: admitted.lease, retry: retry)

            let page = await importer.transmit(Self.entries(["evt-1", "evt-2"]), requiring: admitted.lease)

            // The envelope is complete — `unmappable_identifier` is terminal for
            // `MeasurementBatchAcceptance`, which is what keeps a page of 500
            // from retrying because of one row. This importer still owes that ONE
            // index, exactly as `HealthSampleConsumption` does.
            #expect(page.entries.map(\.classification) == [.terminalAccepted, .nonterminal])
            #expect(page.durableRetryPersisted)
            #expect(!page.durableRetryFailed)
            #expect(await retry.externalIds() == [["evt-2"]])
            #expect(Self.decide(page) == .commit)
        }

        @Test("a raised transport says nothing about any row — all of them hold")
        func transportFailureHoldsEveryIndex() async throws {
            respond(#"{"error":{"code":"server_error","message":"boom"}}"#, status: 500)
            let admitted = try admit()
            let retry = RecordingStatsRetryQueue()
            let importer = makeImporter(uploader: makeUploader(), lease: admitted.lease, retry: retry)

            let page = await importer.transmit(Self.entries(["evt-1", "evt-2"]), requiring: admitted.lease)

            #expect(page.transportThrew)
            #expect(page.entries.allSatisfy { $0.classification == .nonterminal })
            #expect(page.durableRetryPersisted)
            #expect(await retry.externalIds() == [["evt-1", "evt-2"]])
            // Durably queued is progress: the rows exist somewhere that survives
            // a relaunch, so the window may close behind them.
            #expect(Self.decide(page) == .commit)
        }

        @Test("a lost durable write holds the cursor")
        func lostDurableWriteHoldsCursor() async throws {
            respond(#"{"error":{"code":"server_error","message":"boom"}}"#, status: 500)
            let admitted = try admit()
            let importer = makeImporter(
                uploader: makeUploader(),
                lease: admitted.lease,
                retry: RefusingStatsRetryQueue()
            )

            let page = await importer.transmit(Self.entries(["evt-1"]), requiring: admitted.lease)

            #expect(page.durableRetryFailed)
            #expect(Self.decide(page) == .hold(reason: .retryPersistenceFailed))
        }

        @Test("a page with nowhere durable to land holds rather than claiming ground")
        func pageWithoutRetryQueueHolds() async throws {
            respond(#"{"error":{"code":"server_error","message":"boom"}}"#, status: 500)
            let admitted = try admit()
            let importer = makeImporter(uploader: makeUploader(), lease: admitted.lease, retry: nil)

            let page = await importer.transmit(Self.entries(["evt-1"]), requiring: admitted.lease)

            #expect(!page.durableRetryPersisted)
            #expect(page.durableRetryFailed)
            #expect(Self.decide(page) != .commit)
        }

        // MARK: - Account boundary

        @Test("a page whose account was replaced never reaches the wire")
        func replacedAccountNeverPosts() async throws {
            let posted = EcgRequestRecorder()
            MockURLProtocol.handler = { req in
                if req.targets("/api/measurements/batch") { posted.record(req) }
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"processed":1,"inserted":1,"duplicates":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]}"#.utf8)
                )
            }
            let admitted = try admit()
            let importer = makeImporter(uploader: makeUploader(), lease: admitted.lease, retry: nil)
            // Account B signs in on the same device before the page is posted.
            admitted.registry.activate(ownerID: "account-b")

            let page = await importer.transmit(Self.entries(["evt-1"]), requiring: admitted.lease)

            #expect(posted.isEmpty)
            #expect(!page.leaseIsCurrent)
            #expect(Self.decide(page) == .hold(reason: .leaseLost))
        }

        // MARK: - Restart identity

        @Test("a relaunch replays the held page under the same derived key")
        func retryIdentityIsRestartStable() async throws {
            respond(#"{"error":{"code":"server_error","message":"boom"}}"#, status: 500)
            let admitted = try admit()
            let retry = RecordingStatsRetryQueue()
            let importer = makeImporter(uploader: makeUploader(), lease: admitted.lease, retry: retry)

            _ = await importer.transmit(Self.entries(["evt-1", "evt-2"]), requiring: admitted.lease)
            // The relaunch: a second process, a second importer, the same page
            // re-read from the same held anchor.
            let relaunched = makeImporter(uploader: makeUploader(), lease: admitted.lease, retry: retry)
            _ = await relaunched.transmit(Self.entries(["evt-1", "evt-2"]), requiring: admitted.lease)

            let keys = await retry.keys()
            #expect(keys.count == 2)
            #expect(keys[0] == keys[1])
            // And it is the envelope's key, derived from the samples' own UUIDs —
            // not a freshly minted one.
            let envelope = try #require(
                HealthSyncRetryEnvelope(
                    ownerID: Self.owner,
                    source: .heartEvent,
                    stableIdentity: "evt-1|evt-2"
                )
            )
            #expect(keys[0] == envelope.idempotencyKey)
        }

        @Test("another account's replay of the same events is a different operation")
        func retryIdentitySeparatesAccounts() throws {
            let mine = try #require(
                HealthSyncRetryEnvelope(ownerID: Self.owner, source: .heartEvent, stableIdentity: "evt-1")
            )
            let theirs = try #require(
                HealthSyncRetryEnvelope(ownerID: "account-b", source: .heartEvent, stableIdentity: "evt-1")
            )
            #expect(mine.idempotencyKey != theirs.idempotencyKey)
        }

        // MARK: - Empty page

        @Test("an empty page is terminally accounted for by construction")
        func emptyPageCommits() async throws {
            let admitted = try admit()
            let importer = makeImporter(uploader: makeUploader(), lease: admitted.lease, retry: nil)

            let page = await importer.transmit([], requiring: admitted.lease)

            #expect(page.postedCount == 0)
            #expect(Self.decide(page) == .commit)
        }
    }

#endif

// swiftlint:enable force_unwrapping
