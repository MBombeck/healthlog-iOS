import Foundation
import Testing

/// **H4 — first watch-target tests (audit-v0162).**
///
/// `WatchSnapshotStore` is the watch app ⇄ complication bridge: the watch app
/// writes the phone-pushed `WatchSnapshot` into a file the complication's
/// `TimelineProvider` reads (offline-safe, no WatchConnectivity round-trip). It
/// shipped with ZERO automated tests. These exercise the store's real contract
/// through its injectable `url` seam (the production default is the per-device
/// App-Group container, unavailable in a test): encode/decode round-trip, the
/// logout `clear()` wipe (Privacy H4), and safe behaviour on a corrupt blob /
/// absent container.
@Suite("WatchSnapshotStore")
struct WatchSnapshotStoreTests {
    /// A rich, fully-populated snapshot. All dates are on exact second
    /// boundaries so the store's `.iso8601` (second-precision) encoding
    /// round-trips them byte-exactly and `Equatable` holds.
    private func makeSnapshot() -> WatchSnapshot {
        let t = Date(timeIntervalSince1970: 1_733_400_000)
        return WatchSnapshot(
            doses: [
                .init(
                    id: "synth:1",
                    medicationName: "Vitamin D",
                    doseText: "1000 IE",
                    scheduledAt: t,
                    isTaken: false,
                    isActionable: true,
                    isInjection: false
                )
            ],
            scheduledCount: 2,
            takenCount: 1,
            recentMoodScore: 4,
            moodCountToday: 1,
            signedIn: true,
            healthScore: .init(score: 82, band: "green"),
            latestMeasurement: .init(
                kindRaw: "weight",
                title: "Weight",
                formattedValue: "72.4",
                unit: "kg",
                symbol: "scalemass",
                recordedAt: t
            ),
            generatedAt: t
        )
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-snapshot-\(UUID().uuidString).json")
    }

    @Test("write → read round-trips the full snapshot")
    func writeThenReadRoundTrips() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WatchSnapshotStore(url: url)
        let snapshot = makeSnapshot()

        store.write(snapshot)
        let read = store.read()

        #expect(read == snapshot)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let values = try? url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values?.isExcludedFromBackup == true)
    }

    @Test("clear() removes the at-rest file and a subsequent read is nil (Privacy H4)")
    func clearRemovesFileAndReadReturnsNil() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WatchSnapshotStore(url: url)

        store.write(makeSnapshot())
        #expect(FileManager.default.fileExists(atPath: url.path))

        store.clear()

        #expect(store.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("clear() is idempotent — a missing file is a safe no-op")
    func clearIsIdempotentWhenNoFile() {
        let url = tempURL()
        let store = WatchSnapshotStore(url: url)
        // No prior write. Clearing twice must not throw / crash.
        store.clear()
        store.clear()
        #expect(store.read() == nil)
    }

    @Test("read() returns nil (safe empty state) for a corrupt payload")
    func readReturnsNilForCorruptPayload() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("not-json-{".utf8).write(to: url)

        let store = WatchSnapshotStore(url: url)
        // A garbage file must decode to nil so the complication falls back to
        // its placeholder glance rather than the store trapping.
        #expect(store.read() == nil)
    }

    @Test("a nil container URL makes write / read / clear safe no-ops")
    func nilURLIsSafeNoOp() {
        let store = WatchSnapshotStore(url: nil)
        store.write(makeSnapshot())
        store.clear()
        #expect(store.read() == nil)
    }
}
