import Foundation
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping

/// SYNC-TRIG (1.5, #138, Regel 10 und 11) — a parked page replays under a
/// word today's server takes.
///
/// The outbox keeps the `syncTrigger` a page was posted under (A2, 1.4). A
/// 1.4.1 install parks a history page as `backfill` while its server reports
/// `features.syncTriggerBackfill`; when the server it replays against no
/// longer takes the word (a self-hosted rollback to 1.42, a new address), the
/// whole batch is refused with 422. Until 1.5 the replay then halved the page
/// down to single rows that all earned the refusal, and the page parked for
/// good under a word the server would never take.
@Suite("Outbox replay: backfill only where the server takes it (SYNC-TRIG)", .serialized, .mockURLSession)
struct OutboxBackfillReplayGateTests {
    typealias Harness = OutboxHealthKitTriggerAndBisectionTests

    /// A server before the flag: every batch with a word it does not know is
    /// refused as a whole, the way `z.enum` answers; everything else is stored.
    static func installOlderServer(knowing words: Set<SyncTrigger>, wire: Harness.Wire) {
        MockURLProtocol.install { request in
            wire.note(request)
            let last = wire.all.last
            let refused = last?.syncTrigger.map { !words.contains($0) } ?? false
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: refused ? 422 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let ids = last?.ids.count ?? 0
            return (response, Data((refused ? Harness.zodFailure : Harness.accepted(ids)).utf8))
        }
    }

    static func server(_ version: String?, backfillFlag: Bool) -> SyncTriggerContext {
        let context = SyncTriggerContext()
        if let version { context.noteServerVersion(ServerVersionInfo(version: version)) }
        context.noteServerFeatures(backfillFlag ? [.syncTriggerBackfill] : [])
        return context
    }

    /// Exactly the bytes 1.4.1 parked for a history page: entries plus
    /// `"syncTrigger": "backfill"`.
    static func park141HistoryPage(_ outbox: OutboxQueue, key: String) async throws {
        try await outbox.enqueueHealthKitBatch(
            Harness.rows(4, prefix: "hist"),
            encoder: .hlBatch,
            idempotencyKey: key,
            syncTrigger: .backfill,
            requiringCurrentOwner: Harness.owner
        )
        let stored = try #require(await outbox.snapshot.first)
        let object = try #require(try JSONSerialization.jsonObject(with: stored.payload) as? [String: Any])
        #expect(object["syncTrigger"] as? String == "backfill")
    }

    @Test(
        "update path from 1.4.1: a page parked as backfill replays as foreground against a server without the flag, delivered once, nothing registered",
        .timeLimit(.minutes(1))
    )
    func parkedBackfillAgainstOlderServer() async throws {
        let wire = Harness.Wire()
        Self.installOlderServer(knowing: [.foreground, .background, .push, .manual], wire: wire)
        let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Harness.owner })
        let key = "sync-trig-141-\(UUID().uuidString)"
        try await Self.park141HistoryPage(outbox, key: key)

        await HealthKitSkippedRowRegister.$bound.withValue(register) {
            await Harness.makeReplay(outbox: outbox, server: Self.server("1.42.4", backfillFlag: false)).runOnce()
        }

        #expect(wire.all.map(\.syncTrigger) == [.foreground], "one POST, under a word the server knows")
        #expect(wire.all.map(\.key) == [key], "the persisted key, so a repeat is folded")
        #expect(await outbox.snapshot.isEmpty, "the page is delivered, not parked")
        #expect(await register.rows(ownerID: Harness.owner).isEmpty, "no row is called refused")
    }

    @Test("a version without the flag is not enough: still foreground", .timeLimit(.minutes(1)))
    func versionWithoutFlag() async throws {
        let wire = Harness.Wire()
        Self.installOlderServer(knowing: [.foreground, .background, .push, .manual], wire: wire)
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Harness.owner })
        try await Self.park141HistoryPage(outbox, key: "sync-trig-noflag-\(UUID().uuidString)")

        await Harness.makeReplay(outbox: outbox, server: Self.server("1.43.0", backfillFlag: false)).runOnce()

        #expect(wire.all.map(\.syncTrigger) == [.foreground])
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("an unknown server (never probed) gets no backfill either", .timeLimit(.minutes(1)))
    func unknownServer() async throws {
        let wire = Harness.Wire()
        Self.installOlderServer(knowing: [.foreground, .background, .push], wire: wire)
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Harness.owner })
        try await Self.park141HistoryPage(outbox, key: "sync-trig-unknown-\(UUID().uuidString)")

        await Harness.makeReplay(outbox: outbox, server: Self.server(nil, backfillFlag: false)).runOnce()

        #expect(wire.all.map(\.syncTrigger) == [.foreground])
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("with the flag the kept word goes out unchanged", .timeLimit(.minutes(1)))
    func flaggedServerKeepsBackfill() async throws {
        let wire = Harness.Wire()
        Self.installOlderServer(knowing: Set(SyncTrigger.allCases), wire: wire)
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Harness.owner })
        try await Self.park141HistoryPage(outbox, key: "sync-trig-flag-\(UUID().uuidString)")

        await Harness.makeReplay(outbox: outbox, server: Self.server("1.47.0", backfillFlag: true)).runOnce()

        #expect(wire.all.map(\.syncTrigger) == [.backfill])
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("a page parked as manual replays as foreground against a server before 1.42", .timeLimit(.minutes(1)))
    func manualAgainstPre142() async throws {
        let wire = Harness.Wire()
        Self.installOlderServer(knowing: [.foreground, .background, .push], wire: wire)
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Harness.owner })
        try await outbox.enqueueHealthKitBatch(
            Harness.rows(2, prefix: "man"),
            encoder: .hlBatch,
            idempotencyKey: "sync-trig-manual-\(UUID().uuidString)",
            syncTrigger: .manual,
            requiringCurrentOwner: Harness.owner
        )

        await Harness.makeReplay(outbox: outbox, server: Self.server("1.41.9", backfillFlag: false)).runOnce()

        #expect(wire.all.map(\.syncTrigger) == [.foreground])
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("the replay value: nil stays nil, live words stay, the two gated words fall back")
    func replayValueTable() {
        let older = Self.server("1.41.0", backfillFlag: false)
        #expect(older.replayValue(nil) == nil)
        #expect(older.replayValue(.background) == .background)
        #expect(older.replayValue(.push) == .push)
        #expect(older.replayValue(.foreground) == .foreground)
        #expect(older.replayValue(.manual) == .foreground)
        #expect(older.replayValue(.backfill) == .foreground)
        let current = Self.server("1.47.0", backfillFlag: true)
        #expect(current.replayValue(.manual) == .manual)
        #expect(current.replayValue(.backfill) == .backfill)
        #expect(current.replayValue(nil) == nil)
    }
}
