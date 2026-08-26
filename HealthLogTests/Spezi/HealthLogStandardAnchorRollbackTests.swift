#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// Phase 07 Wave 2 — what replaced the held floor.
    ///
    /// **This suite is the restatement of `HealthLogStandard — H3 held-floor
    /// redelivery`.** That suite pinned the exact mechanism this plan removes: a
    /// held upload recorded SpeziHealthKit's pre-wake resume anchor under a
    /// dedicated key, and the next wake wrote it back into the collector's anchor
    /// key to force redelivery. Both halves are gone, and they had to be: the query
    /// that produced the page ran from the *old* anchor before the handler was ever
    /// called, so the page was already consumed — `HealthKitDurableCursorTests`
    /// `/callbackRewindIsOverwritten` models the upstream order and shows the
    /// library overwrites the rewind on return. Rewinding bought a re-read of a
    /// window and no guarantee at all.
    ///
    /// The rule that replaces it is stated here, on the same three inputs the old
    /// suite used (a failing POST, a succeeding POST, and no wiring at all):
    ///
    ///   * A page the server did not terminally accept classifies as non-terminal
    ///     and the durable commit rule HOLDS it. The assertions name
    ///     `HealthSyncCursorPolicy.required` because that is the rule
    ///     `DurableHealthCursorStore.commit(page:…)` literally applies; the
    ///     Wave-0 matrix separately asserts that `installed` has become the same
    ///     rule once the Spezi cutover lands.
    ///   * The recovery is an owner-bound durable row, written under a derived
    ///     idempotency key — with one attached, the same page COMMITS.
    ///   * A successful page commits, and nothing is written anywhere else.
    ///
    /// The old suite's `InMemoryAnchorStore` is deliberately not replaced by an
    /// equivalent: there is no anchor surface on the Standard any more to assert
    /// against, which is itself the point.
    @Suite("HealthLogStandard — a held page holds, and the retry is durable")
    struct HealthLogStandardAnchorRollbackTests {
        // MARK: - Stubs

        /// API stub whose every batch POST throws — the network/server failure the
        /// old suite drove into `.keepAnchor`.
        private final class FailingAPI: APIClientProtocol, @unchecked Sendable {
            func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
                throw HLError.offline
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {
                throw HLError.offline
            }

            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.offline
            }
        }

        /// API stub whose batch POST succeeds with exact per-index acceptance.
        private final class SucceedingAPI: APIClientProtocol, @unchecked Sendable {
            func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
                guard let body = request.body else { throw HLError.unknown("no body") }
                let payload = try BatchUploadOutcomeTests.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                let entryResults: [HealthKitBatchResponseDTO.EntryResult] = payload.entries.indices.map {
                    HealthKitBatchResponseDTO.EntryResult(index: $0, status: .inserted)
                }
                let response = HealthKitBatchResponseDTO(
                    processed: payload.entries.count,
                    inserted: payload.entries.count,
                    duplicates: 0,
                    skipped: [],
                    entries: entryResults
                )
                guard let typed = response as? T else { throw HLError.unknown("T mismatch") }
                return typed
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.unknown("download not implemented")
            }
        }

        /// Records what the durable retry path was asked to persist. The old suite
        /// recorded anchor writes; this records the thing that actually survives a
        /// restart.
        private final class RecordingRetryQueue: HealthSyncBatchRetryEnqueuing, Sendable {
            /// One recorded durable write. A named shape rather than a tuple so
            /// the three fields cannot be read in the wrong order.
            struct Row: Sendable, Equatable {
                let entryCount: Int
                let idempotencyKey: String
                let owner: String
            }

            private let rows = Mutex<[Row]>([])
            private let refuse = Mutex<Bool>(false)

            init(refusing: Bool = false) {
                refuse.withLock { $0 = refusing }
            }

            var enqueuedRowCount: Int {
                rows.withLock { $0.count }
            }

            var idempotencyKeys: [String] {
                rows.withLock { $0.map(\.idempotencyKey) }
            }

            var owners: [String] {
                rows.withLock { $0.map(\.owner) }
            }

            func enqueueHealthKitRetry(
                _ entries: [HealthKitBatchEntryDTO],
                idempotencyKey: String,
                requiringCurrentOwner ownerUserID: String
            ) async throws {
                if refuse.withLock({ $0 }) { throw HLError.offline }
                rows.withLock {
                    $0.append(
                        Row(entryCount: entries.count, idempotencyKey: idempotencyKey, owner: ownerUserID)
                    )
                }
            }
        }

        private struct FlagStub: FeatureFlagsServicing {
            func isEnabled(_ flag: FeatureFlag) -> Bool {
                switch flag {
                case .enableDailyStats: false
                default: flag.defaultValue
                }
            }
        }

        private func makeUploader(api: APIClientProtocol) -> MeasurementBatchUploader {
            MeasurementBatchUploader(api: api, throttle: BatchSyncThrottle())
        }

        private func sample(_ value: Double) -> HKQuantitySample {
            let now = Date()
            return HKQuantitySample(
                type: HKQuantityType(.heartRate),
                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: value),
                start: now.addingTimeInterval(-60),
                end: now
            )
        }

        private func makeLease(
            owner: String = "account-a",
            registry: AuthenticatedSessionLeaseRegistry
        ) throws -> HealthSyncAuthenticatedLease {
            _ = registry.activate(ownerID: owner)
            return try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: owner,
                source: .speziSamples,
                bearerProvider: { "token-\(owner)" }
            )
        }

        private let typeID = HKQuantityTypeIdentifier.heartRate.rawValue

        // MARK: - Tests

        @Test("a failed POST classifies every posted index as non-terminal and the durable rule holds")
        func failedPostHoldsUnderTheDurableRule() async {
            let standard = HealthLogStandard()
            await standard.attachUploader(
                makeUploader(api: FailingAPI()),
                featureFlags: FlagStub()
            )

            let outcome = await standard.consumePage(
                [sample(72)],
                ofType: typeID,
                admitted: nil
            )

            #expect(outcome.transportThrew)
            #expect(outcome.postedCount == 1)
            #expect(outcome.hasNonterminalEntry)
            // Nothing durable was written, so the page has no recovery and the
            // cursor must not move.
            #expect(!outcome.durableRetryPersisted)
            #expect(
                HealthSyncCursorPolicy.required.decide(outcome) == .hold(reason: .nonterminalEntry)
            )
        }

        @Test("a durable owner-bound retry lets the same failed page commit")
        func durableRetryLetsTheFailedPageCommit() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try makeLease(registry: registry)
            let retry = RecordingRetryQueue()

            let standard = HealthLogStandard()
            await standard.attachUploader(
                makeUploader(api: FailingAPI()),
                featureFlags: FlagStub(),
                retryQueue: retry
            )

            let outcome = await standard.consumePage(
                [sample(72)],
                ofType: typeID,
                admitted: lease
            )

            #expect(outcome.durableRetryPersisted)
            #expect(!outcome.durableRetryFailed)
            #expect(retry.enqueuedRowCount == 1)
            #expect(retry.owners == ["account-a"])
            #expect(HealthSyncCursorPolicy.required.decide(outcome) == .commit)
        }

        @Test("the retry identity is derived, so a re-read of the same page rebuilds the same key")
        func retryIdentityIsRestartStable() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try makeLease(registry: registry)
            let retry = RecordingRetryQueue()
            let page = [sample(72)]

            let standard = HealthLogStandard()
            await standard.attachUploader(
                makeUploader(api: FailingAPI()),
                featureFlags: FlagStub(),
                retryQueue: retry
            )

            _ = await standard.consumePage(page, ofType: typeID, admitted: lease)
            // A relaunch rebuilds the operation from the same samples: same owner,
            // same source, same external ids.
            _ = await standard.consumePage(page, ofType: typeID, admitted: lease)

            #expect(retry.idempotencyKeys.count == 2)
            #expect(retry.idempotencyKeys[0] == retry.idempotencyKeys[1])
        }

        @Test("a lost durable write is reported, not swallowed")
        func lostDurableWriteHolds() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try makeLease(registry: registry)

            let standard = HealthLogStandard()
            await standard.attachUploader(
                makeUploader(api: FailingAPI()),
                featureFlags: FlagStub(),
                retryQueue: RecordingRetryQueue(refusing: true)
            )

            let outcome = await standard.consumePage([sample(72)], ofType: typeID, admitted: lease)

            #expect(outcome.durableRetryFailed)
            #expect(!outcome.durableRetryPersisted)
            #expect(
                HealthSyncCursorPolicy.required.decide(outcome) == .hold(reason: .retryPersistenceFailed)
            )
        }

        @Test("a successful POST commits and writes no retry row")
        func successfulPostCommits() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try makeLease(registry: registry)
            let retry = RecordingRetryQueue()

            let standard = HealthLogStandard()
            await standard.attachUploader(
                makeUploader(api: SucceedingAPI()),
                featureFlags: FlagStub(),
                retryQueue: retry
            )

            let outcome = await standard.consumePage([sample(72)], ofType: typeID, admitted: lease)

            #expect(!outcome.hasNonterminalEntry)
            #expect(outcome.coversEveryPostedIndex)
            #expect(retry.enqueuedRowCount == 0)
            #expect(HealthSyncCursorPolicy.required.decide(outcome) == .commit)
        }

        @Test("no retry queue and no admission is tolerated (pre-composition behaviour preserved)")
        func unwiredStandardIsTolerated() async {
            let standard = HealthLogStandard()
            await standard.attachUploader(
                makeUploader(api: FailingAPI()),
                featureFlags: FlagStub()
                // no retryQueue, no admission
            )
            // Passes if the held page returns without crashing, and holds.
            let outcome = await standard.consumePage([sample(72)], ofType: typeID, admitted: nil)
            #expect(HealthSyncCursorPolicy.required.decide(outcome) != .commit)
        }
    }
#endif
