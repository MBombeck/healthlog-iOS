import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// 1.2: the SWR cache, standalone, GLP-1 and coach chat stores deleted their
/// directory on any open failure. A store sealed before the first unlock is
/// transient and must survive; only a corrupt store reaches `discardCorrupt`.
@Suite("ModelContainerRecovery.openPersistentOrDegrade (transient keeps the store)", .serialized)
struct ModelContainerOpenOrDegradeTests {
    private struct OpenFailure: Error {}

    private final class Calls {
        var opens = 0
        var discarded: [URL] = []
    }

    private func inMemory() throws -> ModelContainer {
        try ModelContainer(for: Schema([]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hl-open-or-degrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite")
    }

    private func run(storeURL: URL?, failingOpens: Int, calls: Calls) -> ModelContainer {
        ModelContainerRecovery.openPersistentOrDegrade(
            log: HLLog.storage,
            subsystem: "Test",
            openPersistent: {
                calls.opens += 1
                if calls.opens <= failingOpens { throw OpenFailure() }
                return try inMemory()
            },
            persistentStoreURL: { storeURL },
            discardCorrupt: { calls.discarded.append($0) },
            makeInMemory: inMemory
        )
    }

    @Test("store sealed by data protection: degrades, keeps the file, never discards")
    func sealedStoreIsKept() throws {
        let url = try tempStoreURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let bytes = Data("local-only rows".utf8)
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let calls = Calls()

        _ = run(storeURL: url, failingOpens: .max, calls: calls)

        #expect(calls.discarded.isEmpty)
        #expect(calls.opens == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("store path unresolvable (directory sealed): degrades without discarding")
    func unresolvablePathDegrades() {
        let calls = Calls()

        _ = run(storeURL: nil, failingOpens: .max, calls: calls)

        #expect(calls.discarded.isEmpty)
        #expect(calls.opens == 1)
    }

    @Test("readable but rejected store is corrupt: discarded once, then reopened")
    func corruptStoreIsDiscardedAndReopened() throws {
        let url = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("not sqlite".utf8).write(to: url)
        let calls = Calls()

        _ = run(storeURL: url, failingOpens: 1, calls: calls)

        #expect(calls.discarded == [url])
        #expect(calls.opens == 2)
    }

    @Test("healthy store opens once and discards nothing")
    func healthyStoreOpensOnce() {
        let calls = Calls()

        _ = run(storeURL: nil, failingOpens: 0, calls: calls)

        #expect(calls.opens == 1)
        #expect(calls.discarded.isEmpty)
    }
}
