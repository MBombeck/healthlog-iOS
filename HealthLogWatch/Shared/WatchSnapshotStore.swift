import Foundation

// MARK: - Watch-side snapshot persistence (app ⇄ complication)

//
// **v0.12 P2 — watch complications.** The watch app writes the latest
// `WatchSnapshot` (received from the phone via WatchConnectivity) into the
// watch's App Group container; the complication's `TimelineProvider` reads it
// (fast, offline-safe, no WC round-trip). Compiled into BOTH the watch app +
// the watch widget extension via source membership so the encode/decode
// contract is one piece of code.
//
// The App Group is per-device — this is the WATCH's own container, distinct
// from the phone's `group.dev.healthlog.app` container (App Groups don't sync
// iPhone↔Watch). The phone→watch sync is WatchConnectivity; this store only
// bridges the watch app process to its own complication process.

enum WatchAppGroup {
    static let identifier = "group.dev.healthlog.app"

    static func snapshotURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent("watch-snapshot.json")
    }
}

struct WatchSnapshotStore {
    private let url: URL?

    init(url: URL? = WatchAppGroup.snapshotURL()) {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            try? SensitiveDataBackupExclusion.secureCreatedItem(at: url)
        }
        self.url = url
    }

    func write(_ snapshot: WatchSnapshot) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        // The snapshot carries medication names + next-dose times (health-
        // adjacent), so pin an explicit protection class — same posture as the
        // iOS `WidgetSnapshotStore`. `…UntilFirstUserAuthentication` (not full
        // protection) so the complication can still read it post-lock to build
        // its timeline; bytes are still encrypted at rest before first unlock.
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try SensitiveDataBackupExclusion.secureCreatedItem(at: url)
        } catch {
            return
        }
    }

    func read() -> WatchSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WatchSnapshot.self, from: data)
    }

    /// **Privacy H4 (audit-v0162)** — delete the at-rest snapshot file. Called by
    /// the watch client when the phone pushes a cleared (logout) snapshot, so the
    /// previous user's medication names / doses / mood / measurement do not
    /// persist on the wrist in `watch-snapshot.json`. Idempotent — a missing file
    /// is a no-op. A subsequent `read()` returns `nil`, so complications fall
    /// back to their placeholder/em-dash glance.
    func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
