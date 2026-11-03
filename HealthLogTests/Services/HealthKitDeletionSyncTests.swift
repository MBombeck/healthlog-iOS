#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **A5 (1.4, R3 S4)** — a reading deleted in Apple Health leaves the server.
    ///
    /// Since Phase 07 the app-owned collector only counted `deletedObjects` and
    /// moved its anchor past them, so a wrong weight or blood pressure deleted
    /// in the Health app stayed on the server for good. These tests run the real
    /// collector, the real `HealthLogStandard`, the real repository over the
    /// real `APIClient`, and the real outbox; only HealthKit and the server are
    /// stand-ins.
    @Suite("Apple Health deletions reach the server (A5)", .serialized, .mockURLSession)
    struct HealthKitDeletionSyncTests {
        private func collect(
            _ types: [String],
            pages: [AnchoredHealthSamplePage],
            consumer: HealthLogStandard,
            cursors: DurableHealthCursorStore,
            lease: HealthSyncAuthenticatedLease
        ) async -> (ScriptedPageSource, [AnchoredHealthSampleCollector.TypeResult]) {
            let source = ScriptedPageSource(pages: pages)
            let collector = AnchoredHealthSampleCollector(cursors: cursors, query: source, consumer: consumer)
            let results = await collector.collect(typeIdentifiers: types, trigger: .manual, notBefore: .distantPast, requiring: lease)
            return (source, results)
        }

        // MARK: - Online

        @Test("a weight deleted in Apple Health goes to the delete route under its HealthKit UUID, and the cursor moves")
        func weightDeletionReachesTheServer() async throws {
            let wire = DeletionWire()
            wire.install()
            let api = DeletionFixture.api()
            let outbox = try DeletionFixture.outbox()
            let standard = await DeletionFixture.standard(
                api: api,
                outbox: outbox,
                reconciler: MeasurementsRepository(api: api, outbox: outbox)
            )
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let (cursors, keys) = try await DeletionFixture.cursors(for: [DeletionFixture.weight], lease: lease)
            let deleted = "6F1C2A4E-0B7D-4C1A-9E55-2D3B4C5D6E7F"

            let (_, results) = await collect(
                [DeletionFixture.weight],
                pages: [DeletionFixture.deletions([deleted], anchor: 7)],
                consumer: standard,
                cursors: cursors,
                lease: lease
            )

            let request = try #require(wire.all.first)
            #expect(wire.all.count == 1)
            #expect(request.method == "DELETE")
            #expect(request.path == "/api/measurements/by-external-ids")
            #expect(request.keys == ["externalIds"], "the route is strict: no other key, no syncTrigger")
            #expect(request.externalIds == [deleted])
            #expect(await outbox.snapshot.isEmpty)
            #expect(results.first?.holdReason == nil)
            let key = try #require(keys[DeletionFixture.weight])
            #expect(await cursors.queryAnchor(for: key) == HKQueryAnchor(fromValue: 7))
        }

        @Test("a blood pressure deleted in Apple Health takes both halves, each under its own UUID")
        func bloodPressureDeletesBothHalves() async throws {
            let wire = DeletionWire()
            wire.install()
            let api = DeletionFixture.api()
            let outbox = try DeletionFixture.outbox()
            let standard = await DeletionFixture.standard(
                api: api,
                outbox: outbox,
                reconciler: MeasurementsRepository(api: api, outbox: outbox)
            )
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let types = [DeletionFixture.systolic, DeletionFixture.diastolic]
            let (cursors, _) = try await DeletionFixture.cursors(for: types, lease: lease)

            // The server keeps a reading as two rows, BLOOD_PRESSURE_SYS and
            // BLOOD_PRESSURE_DIA, each under its own sample's UUID.
            _ = await collect(
                types,
                pages: [DeletionFixture.deletions(["SYS-UUID"], anchor: 3), DeletionFixture.deletions(["DIA-UUID"], anchor: 4)],
                consumer: standard,
                cursors: cursors,
                lease: lease
            )

            #expect(wire.all.map(\.externalIds) == [["SYS-UUID"], ["DIA-UUID"]])
            #expect(await outbox.snapshot.isEmpty)
        }

        // MARK: - Offline

        @Test("offline: the deletion waits in the outbox under its owner, the cursor moves, and the replay sends it once")
        func offlineDeletionWaitsAndReplays() async throws {
            let wire = DeletionWire()
            wire.install()
            wire.answer(.offline)
            let api = DeletionFixture.api()
            let outbox = try DeletionFixture.outbox()
            let standard = await DeletionFixture.standard(
                api: api,
                outbox: outbox,
                reconciler: MeasurementsRepository(api: api, outbox: outbox)
            )
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let (cursors, keys) = try await DeletionFixture.cursors(for: [DeletionFixture.weight], lease: lease)

            let (_, results) = await collect(
                [DeletionFixture.weight],
                pages: [DeletionFixture.deletions(["W-1", "W-2"], anchor: 9)],
                consumer: standard,
                cursors: cursors,
                lease: lease
            )

            #expect(wire.all.isEmpty, "nothing reached the server")
            let row = try #require(await outbox.snapshot.first)
            #expect(await outbox.snapshot.count == 1)
            #expect(row.kind == .deleteHealthKitSamples)
            #expect(row.ownerUserID == DeletionFixture.owner)
            let payload = try JSONDecoder.hlDefault.decode(OutboxQueue.Payloads.DeleteHealthKitSamples.self, from: row.payload)
            #expect(payload.externalIds == ["W-1", "W-2"])
            #expect(results.first?.holdReason == nil, "kept durably, so the page may pass")
            let key = try #require(keys[DeletionFixture.weight])
            #expect(await cursors.queryAnchor(for: key) == HKQueryAnchor(fromValue: 9))

            // Back online: the replay sends exactly the kept batch.
            wire.answer(.deleted)
            let replay = DeletionFixture.replay(outbox: outbox, api: api)
            await replay.runOnce()
            #expect(wire.all.map(\.externalIds) == [["W-1", "W-2"]])
            #expect(wire.all.first?.method == "DELETE")
            #expect(wire.all.first?.keys == ["externalIds"])
            #expect(await outbox.snapshot.isEmpty)

            // A second pass has nothing left to send.
            await replay.runOnce()
            #expect(wire.all.count == 1)
        }

        @Test("a deletion with nowhere to go holds the page, so the next read reports it again")
        func deletionWithNowhereToGoHolds() async throws {
            let wire = DeletionWire()
            wire.install()
            let api = DeletionFixture.api()
            let outbox = try DeletionFixture.outbox()
            // No reconciler attached yet, and a queue that keeps no deletions.
            let standard = await DeletionFixture.standard(api: api, outbox: outbox, retryQueue: PagesOnlyRetryQueue())
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let (cursors, keys) = try await DeletionFixture.cursors(for: [DeletionFixture.weight], lease: lease)

            let (source, results) = await collect(
                [DeletionFixture.weight],
                pages: [DeletionFixture.deletions(["W-9"], anchor: 5), DeletionFixture.deletions(["W-9"], anchor: 5)],
                consumer: standard,
                cursors: cursors,
                lease: lease
            )

            #expect(results.first?.holdReason == .retryPersistenceFailed)
            let key = try #require(keys[DeletionFixture.weight])
            #expect(await cursors.anchor(for: key) == nil, "the anchor did not pass the deletion")
            #expect(source.queryCount == 1)
            #expect(wire.all.isEmpty)
        }

        @Test("a delete the server refuses is not retried: no outbox row, the cursor moves")
        func refusedDeletionIsNotRetried() async throws {
            let wire = DeletionWire()
            wire.install()
            wire.answer(.refused)
            let api = DeletionFixture.api()
            let outbox = try DeletionFixture.outbox()
            let standard = await DeletionFixture.standard(
                api: api,
                outbox: outbox,
                reconciler: MeasurementsRepository(api: api, outbox: outbox)
            )
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let (cursors, keys) = try await DeletionFixture.cursors(for: [DeletionFixture.weight], lease: lease)

            _ = await collect(
                [DeletionFixture.weight],
                pages: [DeletionFixture.deletions(["W-4"], anchor: 6)],
                consumer: standard,
                cursors: cursors,
                lease: lease
            )

            #expect(wire.all.count == 1)
            #expect(await outbox.snapshot.isEmpty)
            let key = try #require(keys[DeletionFixture.weight])
            #expect(await cursors.queryAnchor(for: key) == HKQueryAnchor(fromValue: 6))
        }

        // MARK: - No loop through the mirror

        @Test("a deleted mirror copy names only its own HealthKit UUID, never the server row it mirrors")
        func mirrorCopyDeletionCannotReachTheOriginal() async throws {
            let wire = DeletionWire()
            wire.install()
            let api = DeletionFixture.api()
            let outbox = try DeletionFixture.outbox()
            let standard = await DeletionFixture.standard(
                api: api,
                outbox: outbox,
                reconciler: MeasurementsRepository(api: api, outbox: outbox)
            )
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let (cursors, _) = try await DeletionFixture.cursors(for: [DeletionFixture.weight], lease: lease)

            // A weight typed on the web (MANUAL), written into Apple Health by
            // the server mirror of a build before 1.4: server id and origin
            // marker, no sync identifier, so its deletion carries no metadata
            // (A6 covers the copies that carry one).
            let original = HealthLog.Measurement(
                id: "srv-weight-1",
                kind: .weight,
                recordedAt: Date(timeIntervalSince1970: 1_790_000_000),
                value: .scalar(81.2),
                source: .manual
            )
            let copy = DeletionFixture.legacyCopy(of: original, kilograms: 81.2)
            // The read path never uploads the copy, so the server holds no row
            // under its UUID: deleting it there is a no-op by construction.
            #expect(HealthKitSampleOwnership.isOwnEcho(
                externalUUID: copy.metadata?[HKMetadataKeyExternalUUID] as? String,
                isFromThisApp: true
            ))

            _ = await collect(
                [DeletionFixture.weight],
                pages: [DeletionFixture.deletions([copy.uuid.uuidString], anchor: 2)],
                consumer: standard,
                cursors: cursors,
                lease: lease
            )

            #expect(wire.deletedIDs == [copy.uuid.uuidString])
            #expect(!wire.deletedIDs.contains(original.id), "the MANUAL original is never named")
            // And the way back is closed too: a row the server took from Apple
            // Health is never mirrored into it, so the server's tombstone of
            // such a row cannot come back as a Health write or a new deletion.
            let fromHealth = HealthLog.Measurement(
                id: "srv-weight-2",
                kind: .weight,
                recordedAt: original.recordedAt,
                value: .scalar(81.2),
                source: .appleHealth
            )
            #expect(!HealthKitService.shouldMirrorFromServer(fromHealth))
        }

        // MARK: - Folded and summed types

        @Test("of a pass over folded, summed and hand-kept types only the weight's deletion is sent; every cursor moves")
        func foldedAndSummedTypesAreNotSent() async throws {
            let wire = DeletionWire()
            wire.install()
            let api = DeletionFixture.api()
            let outbox = try DeletionFixture.outbox()
            let standard = await DeletionFixture.standard(
                api: api,
                outbox: outbox,
                reconciler: MeasurementsRepository(api: api, outbox: outbox)
            )
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let types: [HKQuantityTypeIdentifier] = [
                .heartRate, .heartRateVariabilitySDNN, .oxygenSaturation, .respiratoryRate, .stepCount, .activeEnergyBurned, .bodyMass
            ]
            let ids = types.map(\.rawValue)
            let (cursors, keys) = try await DeletionFixture.cursors(for: ids, lease: lease)
            let pages = ids.indices.map { DeletionFixture.deletions(["X-\($0)"], anchor: 40 + $0) }

            let (_, results) = await collect(ids, pages: pages, consumer: standard, cursors: cursors, lease: lease)

            #expect(wire.deletedIDs == ["X-6"], "only the weight, the last type")
            #expect(await outbox.snapshot.isEmpty)
            #expect(results.allSatisfy { $0.holdReason == nil })
            for (index, type) in ids.enumerated() {
                let key = try #require(keys[type])
                #expect(await cursors.queryAnchor(for: key) == HKQueryAnchor(fromValue: 40 + index))
            }
        }
    }
#endif
