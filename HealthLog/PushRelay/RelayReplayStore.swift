import Foundation

/// Remembers every opened envelope id until its expiry, so the same envelope
/// opens once. The app and the extension share one store in the App Group.
public protocol RelayReplayStoring: Sendable {
    /// Throws `.replayed` for a known id and `.replayStoreFull` when every slot
    /// holds an id that has not expired yet; records the id otherwise.
    func checkAndRecord(id: String, expiresAt: Int64, now: Int64) throws(RelayEnvelopeError)
}

/// The replay rule itself, over a plain list of entries. Pure, so the file
/// store and the tests share it.
public enum RelayReplayRule {
    /// The spec's capacity, above the relay's day quota per device.
    public static let capacity = 512

    public struct Entry: Codable, Sendable, Equatable {
        public let id: String
        public let exp: Int64
    }

    /// The entries after recording `id`; throws without changing anything.
    public static func record(
        id: String,
        expiresAt: Int64,
        now: Int64,
        in entries: [Entry],
        capacity: Int = capacity
    ) throws(RelayEnvelopeError) -> [Entry] {
        // An envelope opens until `exp + skew`; its id is kept exactly as long.
        var live = entries.filter { $0.exp + RelayEnvelope.clockSkew >= now }
        if live.contains(where: { $0.id == id }) { throw .replayed }
        guard live.count < capacity else { throw .replayStoreFull }
        live.append(Entry(id: id, exp: expiresAt))
        return live
    }
}

/// The App Group file store, written under an exclusive `flock` so the app and
/// the extension never interleave a read and a write.
public struct RelayFileReplayStore: RelayReplayStoring {
    public static let filename = "push-relay-replay.json"
    let url: URL?

    public init(url: URL? = RelayAppGroupFile.url(RelayFileReplayStore.filename)) {
        self.url = url
    }

    public func checkAndRecord(id: String, expiresAt: Int64, now: Int64) throws(RelayEnvelopeError) {
        guard let url else { throw .replayStoreFull }
        let outcome: Result<Void, RelayEnvelopeError> = RelayAppGroupFile.withLock(url) {
            // D1 (6): fail closed. A file that is there but cannot be read is
            // not an empty store; it is reset only once every id it could
            // hold has expired. A write that fails records nothing, so the
            // envelope does not open either.
            let entries: [RelayReplayRule.Entry]
            switch RelayAppGroupFile.readOutcome([RelayReplayRule.Entry].self, from: url) {
            case .missing:
                entries = []
            case let .found(stored):
                entries = stored
                RelayAppGroupFile.remove(Self.unreadableMarker(for: url))
            case .unreadable:
                guard Self.mayReset(url, now: now) else { return .failure(.replayStoreFull) }
                entries = []
            }
            do {
                let next = try RelayReplayRule.record(id: id, expiresAt: expiresAt, now: now, in: entries)
                guard RelayAppGroupFile.writeChecked(next, to: url) else { return .failure(.replayStoreFull) }
                return .success(())
            } catch {
                return .failure((error as? RelayEnvelopeError) ?? .replayStoreFull)
            }
        } ?? .failure(.replayStoreFull)
        try outcome.get()
    }

    /// The longest an id may need remembering: the longest lifetime of any
    /// class plus the clock skew.
    static var longestWindow: Int64 {
        (RelayPushClass.allCases.map(\.maxLifetime).max() ?? 0) + RelayEnvelope.clockSkew
    }

    /// An unreadable file may go once it has been unreadable for longer than
    /// ``longestWindow``: nothing it held can still open. The first sighting
    /// is noted in a marker next to it (no file timestamps are read).
    static func mayReset(_ url: URL, now: Int64) -> Bool {
        let marker = unreadableMarker(for: url)
        guard let firstSeen = RelayAppGroupFile.read(Int64.self, from: marker) else {
            RelayAppGroupFile.write(now, to: marker)
            return false
        }
        guard now - firstSeen > longestWindow else { return false }
        RelayAppGroupFile.remove(marker)
        return true
    }

    static func unreadableMarker(for url: URL) -> URL {
        url.appendingPathExtension("unreadable")
    }
}

/// A process-local store for tests.
public final class RelayMemoryReplayStore: RelayReplayStoring, @unchecked Sendable {
    // `@unchecked`: `entries` is only touched under `lock`.
    private let lock = NSLock()
    private var entries: [RelayReplayRule.Entry] = []
    private let capacity: Int

    public init(capacity: Int = RelayReplayRule.capacity) {
        self.capacity = capacity
    }

    public func checkAndRecord(id: String, expiresAt: Int64, now: Int64) throws(RelayEnvelopeError) {
        lock.lock()
        defer { lock.unlock() }
        entries = try RelayReplayRule.record(id: id, expiresAt: expiresAt, now: now, in: entries, capacity: capacity)
    }
}

/// JSON files in the App Group, read and written under an exclusive lock.
public enum RelayAppGroupFile {
    public static let appGroup = "group.dev.healthlog.app"

    public static func url(_ filename: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(filename, isDirectory: false)
    }

    /// Runs `body` while holding `flock(LOCK_EX)` on `<file>.lock`. `nil` when
    /// the lock file cannot be opened.
    public static func withLock<T>(_ url: URL, _ body: () -> T) -> T? {
        let lockPath = url.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    /// What a read found: no file, a file that does not decode, or the value.
    public enum ReadOutcome<T> {
        case missing
        case unreadable
        case found(T)
    }

    public static func readOutcome<T: Decodable>(_: T.Type, from url: URL) -> ReadOutcome<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(T.self, from: data) else {
            return .unreadable
        }
        return .found(value)
    }

    /// Like ``write(_:to:)``, and says whether the bytes reached the disk.
    @discardableResult
    public static func writeChecked(_ value: some Encodable, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return false
        }
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
        return true
    }

    public static func read<T: Decodable>(_: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public static func write(_ value: some Encodable, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    public static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
