import Foundation
@testable import HealthLog
import Testing

/// **1.4 decision 3** — "Zuletzt synchronisiert" stays on Today; every other
/// screen's sync footer appears only for a real state. Locks the pure ladder
/// of the quiet footer and that Today is the one screen that opts out of it.
@Suite("Sync footer — real states only outside Today (1.4 decision 3)")
struct SyncFooterRealStateTests {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a healthy state shows nothing, not even the settled time")
    func healthyIsHidden() {
        let state = SyncStatusCaption.resolveRealStateOnly(
            firstLoginPreparing: false,
            attention: nil,
            lastSyncAt: stamp
        )
        #expect(state == .hidden)
    }

    @Test("a day-old or failed sync says so and names the time of the last one")
    func staleAndFailedShowTheLastSync() {
        #expect(SyncStatusCaption.resolveRealStateOnly(
            firstLoginPreparing: false, attention: .failed, lastSyncAt: stamp
        ) == .failedSince(stamp))
        #expect(SyncStatusCaption.resolveRealStateOnly(
            firstLoginPreparing: false, attention: .stale(since: stamp), lastSyncAt: stamp
        ) == .staleSince(stamp))
    }

    @Test("outside Today no state reads as the plain last-synced line (1.4 B4)")
    func neverThePlainLastSyncedLine() {
        let states: [SyncAttention?] = [nil, .failed, .stale(since: stamp), .queued(2), .failedWrites(1)]
        for attention in states {
            for lastSync in [stamp, nil] as [Date?] {
                let state = SyncStatusCaption.resolveRealStateOnly(
                    firstLoginPreparing: false, attention: attention, lastSyncAt: lastSync
                )
                if case .lastSynced = state { Issue.record("\(String(describing: attention)) reads as „Zuletzt synchronisiert“") }
            }
        }
    }

    @Test("the two state lines say what happened, in both languages")
    func stateLinesNameTheState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("HealthLog/Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        func value(_ key: String, _ language: String) -> String? {
            let entry = strings[key] as? [String: Any]
            let locs = entry?["localizations"] as? [String: [String: [String: String]]]
            return locs?[language]?["stringUnit"]?["value"]
        }
        #expect(value("sync.status.failedSince %@", "de")?.contains("fehlgeschlagen") == true)
        #expect(value("sync.status.failedSince %@", "en")?.contains("failed") == true)
        #expect(value("sync.status.staleSince %@", "de")?.contains("nicht synchronisiert") == true)
        #expect(value("sync.status.staleSince %@", "en")?.contains("Not synced") == true)
    }

    @Test("a failed sync that never had a good one says so in a sentence")
    func failedWithoutHistory() {
        let state = SyncStatusCaption.resolveRealStateOnly(
            firstLoginPreparing: false,
            attention: .failed,
            lastSyncAt: nil
        )
        #expect(state == .attention(.failed))
    }

    @Test("waiting and given-up writes are said as what they are")
    func writesAreNamed() {
        #expect(SyncStatusCaption.resolveRealStateOnly(
            firstLoginPreparing: false, attention: .queued(3), lastSyncAt: stamp
        ) == .attention(.queued(3)))
        #expect(SyncStatusCaption.resolveRealStateOnly(
            firstLoginPreparing: false, attention: .failedWrites(2), lastSyncAt: stamp
        ) == .attention(.failedWrites(2)))
    }

    @Test("a running sync is not a state the footer reports")
    func inFlightIsHidden() {
        let attention = SyncAttention.resolve(
            isInFlight: true,
            failedWriteCount: 0,
            handshakeFailed: false,
            queuedWriteCount: 4,
            queuedSince: stamp,
            lastSync: SyncActivity(at: stamp, channel: .foreground),
            now: stamp.addingTimeInterval(3600)
        )
        let state = SyncStatusCaption.resolveRealStateOnly(
            firstLoginPreparing: false,
            attention: attention,
            lastSyncAt: stamp
        )
        #expect(state == .hidden)
    }

    @Test("the first-login hint still wins where a screen passes it")
    func preparingWins() {
        let state = SyncStatusCaption.resolveRealStateOnly(
            firstLoginPreparing: true,
            attention: .failed,
            lastSyncAt: stamp
        )
        #expect(state == .preparing)
    }

    @Test("Today is the only footer that keeps the settled line: one switch, one opt-in")
    func todayIsTheOnlyOptIn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DesignSystem
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repo root
        let screens = root.appendingPathComponent("HealthLog/Screens")
        let walker = try #require(FileManager.default.enumerator(at: screens, includingPropertiesForKeys: nil))
        var optIns: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("scope: .today") { optIns.append(url.lastPathComponent) }
        }
        #expect(optIns == ["DashboardSlots.swift"])

        let footer = try String(
            contentsOf: root.appendingPathComponent("HealthLog/DesignSystem/HLSyncStatusFooter.swift"),
            encoding: .utf8
        )
        #expect(footer.contains("var scope: Scope = .realStateOnly"))
    }
}
