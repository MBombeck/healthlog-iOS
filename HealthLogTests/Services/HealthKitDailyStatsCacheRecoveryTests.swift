import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// 1.2 (INT-N, open point from V2): the daily-stats cache moved its store aside
/// on ANY open failure, also when the file was only sealed by data protection
/// in a background launch before the first unlock. Such a store is fine and
/// opens on the next launch; it must stay where it is. Only a store whose bytes
/// are readable but rejected is moved aside, as before.
@Suite("HealthKitDailyStatsCache recovery (sealed store is kept)", .serialized)
struct HealthKitDailyStatsCacheRecoveryTests {
    private struct OpenFailure: Error {}

    private final class Opens {
        var count = 0
    }

    private func inMemory() throws -> ModelContainer {
        try ModelContainer(for: Schema([]), configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func tempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hl-hkstats-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hkstats.sqlite")
    }

    private func quarantined(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("hkstats-quarantined-") }
    }

    private func open(storeURL: URL?, failingOpens: Int, opens: Opens) -> ModelContainer {
        HealthKitDailyStatsCache.openWithRecovery(
            openPersistent: {
                opens.count += 1
                if opens.count <= failingOpens { throw OpenFailure() }
                return try inMemory()
            },
            persistentStoreURL: { storeURL },
            makeInMemory: inMemory
        )
    }

    @Test("store sealed by data protection: degrades to memory, file stays in place")
    func sealedStoreIsKept() throws {
        let url = try tempStoreURL()
        let dir = url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let bytes = Data("last posted day totals".utf8)
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let opens = Opens()

        _ = open(storeURL: url, failingOpens: .max, opens: opens)

        #expect(opens.count == 1)
        #expect(try quarantined(in: dir).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("store path unresolvable (directory sealed): degrades without moving anything")
    func unresolvablePathDegrades() {
        let opens = Opens()

        _ = open(storeURL: nil, failingOpens: .max, opens: opens)

        #expect(opens.count == 1)
    }

    @Test("readable but rejected store is corrupt: moved aside once, then reopened")
    func corruptStoreIsMovedAsideAndReopened() throws {
        let url = try tempStoreURL()
        let dir = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("not sqlite".utf8)
        try bytes.write(to: url)
        let opens = Opens()

        _ = open(storeURL: url, failingOpens: 1, opens: opens)

        #expect(opens.count == 2)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let aside = try quarantined(in: dir)
        #expect(aside.count == 1)
        let moved = try #require(aside.first)
        #expect(try Data(contentsOf: dir.appendingPathComponent(moved)) == bytes)
    }

    @Test("healthy store opens once and moves nothing")
    func healthyStoreOpensOnce() throws {
        let url = try tempStoreURL()
        let dir = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("rows".utf8).write(to: url)
        let opens = Opens()

        _ = open(storeURL: url, failingOpens: 0, opens: opens)

        #expect(opens.count == 1)
        #expect(try quarantined(in: dir).isEmpty)
    }
}
