import Foundation
@testable import HealthLog
import Testing

/// **Phase 09 Wave 0 — the deterministic fixture and counting-seam bench.**
///
/// Phase 9's whole premise is that a measurement precedes a claim. That only
/// works if the *input* to every measurement is frozen: the same bytes, the
/// same entry sequence, the same invocation ledger, on the baseline capture and
/// on the post-change capture. This file is that frozen input.
///
/// Three rules govern everything below.
///
/// **1. A large fixture may not cost large storage.** The Apple-Health import
/// budget is stated against 16 MiB, 256 MiB and 1.5 GiB archives. Materialising
/// 1.5 GiB of real bytes per test run on a machine whose simulator graveyard
/// already regrows hundreds of megabytes a run is not acceptable, and it would
/// measure the disk rather than the code. ``Phase09SparseFile`` therefore
/// produces files with the correct *logical* length and a near-zero *allocated*
/// length, using the POSIX hole semantics APFS provides.
/// ``Phase09SparseFile/allocatedBytes`` is exposed so a test can prove the hole
/// is real instead of trusting it.
///
/// **2. No fixture carries anything patient-like.** Mood scores are produced by
/// a pure index formula, ids are `phase09-mood-000123`, tags come from a
/// synthetic `phase09-factor-*` catalogue, and notes are always `nil`. Nothing
/// here should ever be mistakable for a real record if it leaks into a log.
///
/// **3. Counting seams count, they do not simulate.** The doubles record
/// invocations, ordering and the categorical size of what they were handed.
/// They never sleep on a real clock, never touch the network, and never assert
/// a wall-clock budget — elapsed-time budgets are physical-device evidence
/// only (see `09-VALIDATION.md`, "Sampling Rate").
enum Phase09Fixture {
    /// The three frozen Apple-Health archive sizes the import budget is stated
    /// against. Raw values are the logical byte counts.
    enum ArchiveSize: UInt64, CaseIterable, Sendable {
        case small = 16_777_216 // 16 MiB
        case medium = 268_435_456 // 256 MiB
        case large = 1_610_612_736 // 1.5 GiB

        var label: String {
            switch self {
            case .small: "16MiB"
            case .medium: "256MiB"
            case .large: "1.5GiB"
            }
        }
    }

    /// The two frozen Mood history depths: one ordinary year, and the synthetic
    /// stress history the bounded-cache budget is stated against.
    enum MoodHistoryDepth: Int, CaseIterable, Sendable {
        case year = 365
        case stress = 10000

        var label: String {
            switch self {
            case .year: "365"
            case .stress: "10000"
            }
        }
    }

    /// The two frozen export payload sizes. The large one is allocated lazily
    /// and only by tests that actually need real bytes.
    enum ExportPayloadSize: Int, CaseIterable, Sendable {
        case small = 1_048_576 // 1 MiB
        case large = 262_144_000 // 250 MB
    }
}

// MARK: - Sparse archive fixtures

/// A file with a large logical size and an almost-zero allocated size.
///
/// The file is not empty: a deterministic 512-byte header sits at offset 0, and
/// everything after it is a hole produced by extending the file with
/// `truncate`. A consumer therefore gets stable bytes at the front, zeroes for
/// the rest, and the correct total length — enough to exercise a chunked copy,
/// a length calculation and a multipart envelope without allocating the middle.
///
/// **Why there is no trailing marker.** The obvious design writes a second
/// marker at `logicalBytes - 512` so both ends are identifiable. Measured on
/// this machine's APFS volume, that write allocates *every block before the
/// offset*: a 16 MiB fixture built that way reserved a full 16 MiB, and a
/// 1.5 GiB one would have reserved 1.5 GiB. Header-plus-`truncate` reserves
/// 4 KiB for all three sizes. The tail assertion moved to "the tail reads as a
/// hole", which is a stronger statement than "the tail reads as my marker"
/// anyway — it proves the middle was never materialised.
final class Phase09SparseFile: @unchecked Sendable {
    let url: URL
    let logicalBytes: UInt64

    static let markerLength = 512

    /// Deterministic marker bytes. Index-derived, so the same offset always
    /// yields the same byte and a truncation is detectable.
    static func marker(seed: UInt8) -> Data {
        Data((0 ..< markerLength).map { UInt8(($0 &* 31 &+ Int(seed)) % 251) })
    }

    /// Creates the sparse fixture inside `directory`.
    ///
    /// It does **not** swallow a failure: a fixture that silently produced a
    /// zero-length file would turn every downstream memory measurement into a
    /// measurement of nothing — exactly the "hermetic fixture guarded the wrong
    /// endpoint and never fired" failure this phase exists to avoid.
    convenience init(size: Phase09Fixture.ArchiveSize, in directory: URL) throws {
        try self.init(logicalBytes: size.rawValue, in: directory, name: "phase09-archive-\(size.label).zip")
    }

    init(logicalBytes: UInt64, in directory: URL, name: String) throws {
        precondition(
            logicalBytes > UInt64(Self.markerLength),
            "a sparse fixture must be larger than its header marker"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw Phase09FixtureError.cannotCreateFile
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.write(contentsOf: Self.marker(seed: 1))
        try handle.truncate(atOffset: logicalBytes)
        try handle.synchronize()
        url = target
        self.logicalBytes = logicalBytes
    }

    /// Blocks actually reserved on disk, in bytes.
    ///
    /// Read from `st_blocks` rather than from `URLResourceValues`, because the
    /// block count is the primitive the file system cannot round up: a resource
    /// value that answers with the logical size would make a non-sparse fixture
    /// look sparse, which is precisely the assertion that must not be able to
    /// pass for the wrong reason.
    var allocatedBytes: UInt64 {
        var status = stat()
        let outcome = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &status)
        }
        guard outcome == 0 else { return .max }
        return UInt64(status.st_blocks) * 512
    }

    /// The logical size the file system reports, read back rather than assumed.
    var reportedLogicalBytes: UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

enum Phase09FixtureError: Error, Equatable {
    case cannotCreateFile
    case noCannedResponse(path: String)
}

/// A private, self-cleaning scratch directory for one test.
final class Phase09Scratch: @unchecked Sendable {
    let url: URL

    init(_ label: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase09-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Counting seams

/// A lock-guarded invocation ledger. Deliberately not an actor: the seams it
/// backs are called from synchronous production code (a SwiftUI body, a
/// `@MainActor` store write) where an `await` would change the very thing being
/// measured.
final class Phase09Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ label: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(label)
    }

    var invocations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        invocations.count
    }

    func count(of label: String) -> Int {
        invocations.filter { $0 == label }.count
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

/// A clock that never sleeps. Records every requested duration so a poll-cadence
/// or deadline contract can be asserted without spending the wall clock.
final class Phase09Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [UInt64] = []

    var requestedSleeps: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    /// The lock is taken here rather than inside the async closure below:
    /// `NSLock.lock()` is unavailable from an asynchronous context, and a
    /// suspension while holding it would be a real bug rather than a
    /// diagnostic pedantry.
    private func record(_ nanos: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        requested.append(nanos)
    }

    /// Drop-in for `Task.sleep(nanoseconds:)`. Honours cancellation — a clock
    /// seam that swallowed cancellation would make a cancellation-latency
    /// budget unprovable.
    var sleeper: @Sendable (UInt64) async throws -> Void {
        { [self] nanos in
            record(nanos)
            try Task.checkCancellation()
        }
    }
}

/// A counting `APIClientProtocol` that answers from canned bodies.
///
/// It records, per call: the path, the method, and the **byte count of the body
/// the caller handed it**. That last field is the one Plan 09-02 needs — it is
/// how "the whole archive plus the whole multipart envelope was materialised in
/// memory" becomes an assertion instead of an opinion.
final class Phase09CountingAPIClient: APIClientProtocol, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let method: HTTPMethod
        let path: String
        /// `nil` when the request carried no in-memory body at all — which is
        /// the post-09-02 expectation for the import upload.
        let bodyByteCount: Int?
        /// Byte length of the **file** the caller asked to be streamed, when
        /// the call arrived through ``Phase09CountingAPIClient/uploadFile(_:)``.
        /// A call with `bodyByteCount == nil` and `bodyFileByteCount != nil` is
        /// the post-09-02 shape: a body that exists, and a process that is not
        /// holding it.
        let bodyFileByteCount: Int?
        let maxRetries: Int
        let allowsAuthenticationRecovery: Bool

        init(
            method: HTTPMethod,
            path: String,
            bodyByteCount: Int?,
            bodyFileByteCount: Int? = nil,
            maxRetries: Int,
            allowsAuthenticationRecovery: Bool
        ) {
            self.method = method
            self.path = path
            self.bodyByteCount = bodyByteCount
            self.bodyFileByteCount = bodyFileByteCount
            self.maxRetries = maxRetries
            self.allowsAuthenticationRecovery = allowsAuthenticationRecovery
        }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var canned: [String: Data]

    init(canned: [String: Data] = [:]) {
        self.canned = canned
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var sendCount: Int {
        calls.count
    }

    func stub(path: String, json: String) {
        lock.lock()
        defer { lock.unlock() }
        canned[path] = Data(json.utf8)
    }

    private func record(_ call: Call) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        return canned[call.path]
    }

    private func call(for request: APIRequest<some Sendable>) -> Call {
        Call(
            method: request.method,
            path: request.path,
            bodyByteCount: request.body?.count,
            maxRetries: request.maxRetries,
            allowsAuthenticationRecovery: request.allowsAuthenticationRecovery
        )
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        let body = record(call(for: request))
        guard let body else { throw Phase09FixtureError.noCannedResponse(path: request.path) }
        return try JSONDecoder.hlDefault.decode(T.self, from: body)
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        _ = record(call(for: request))
    }

    /// The one-shot file-backed route (Plan 09-02). Records the call with **no**
    /// in-memory body byte count and the file's length instead — which is the
    /// whole assertion: this client cannot report an in-memory body for a call
    /// that never had one, and the old buffered route cannot report `nil`.
    ///
    /// The file itself is never read here. A counting double that opened it
    /// would allocate exactly the bytes the production change exists to avoid,
    /// inside the test that proves it avoids them.
    func uploadFile<T: Decodable & Sendable>(_ request: APIFileUploadRequest<T>) async throws -> T {
        let body = record(Call(
            method: request.method,
            path: request.path,
            bodyByteCount: nil,
            bodyFileByteCount: request.byteCount,
            maxRetries: 0,
            allowsAuthenticationRecovery: false
        ))
        guard let body else { throw Phase09FixtureError.noCannedResponse(path: request.path) }
        return try JSONDecoder.hlDefault.decode(T.self, from: body)
    }

    func download(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        let body = record(call(for: request))
        guard let body,
              let response = HTTPURLResponse(
                  url: URL(string: "https://phase09.invalid\(request.path)") ?? URL(fileURLWithPath: "/"),
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: nil
              ) else { throw Phase09FixtureError.noCannedResponse(path: request.path) }
        return (body, response)
    }
}

/// A counting persistence writer. Stands in for the byte-writing tail of an
/// export or widget persist so a test can prove *how many* writes happened, on
/// *which* thread, and under *which* protection class — without leaving
/// PHI-shaped files behind.
final class Phase09CountingWriter: @unchecked Sendable {
    struct Write: Sendable {
        let byteCount: Int
        let options: Data.WritingOptions
        let wasMainThread: Bool
    }

    private let lock = NSLock()
    private var recorded: [Write] = []
    private var pendingFailure: (any Error)?

    /// When set, every subsequent write throws instead of succeeding.
    func failNextWrites(with error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        pendingFailure = error
    }

    var writes: [Write] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var writeCount: Int {
        writes.count
    }

    var mainThreadWriteCount: Int {
        writes.filter(\.wasMainThread).count
    }

    /// Drop-in for the production write closure.
    var write: @Sendable (Data, URL, Data.WritingOptions) throws -> Void {
        { [self] data, _, options in
            lock.lock()
            recorded.append(Write(byteCount: data.count, options: options, wasMainThread: Thread.isMainThread))
            let failure = pendingFailure
            lock.unlock()
            if let failure { throw failure }
        }
    }
}

/// A counting widget-timeline reloader. WidgetKit's real `WidgetCenter` cannot
/// be observed from a unit test, so the production reload calls route through a
/// seam whose live default is WidgetKit and whose test default is this ledger.
final class Phase09CountingReloader: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var reloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var reload: @Sendable (String) -> Void {
        { [self] kind in
            lock.lock()
            recorded.append(kind)
            lock.unlock()
        }
    }

    func count(ofKind kind: String) -> Int {
        reloads.filter { $0 == kind }.count
    }
}

// MARK: - Adapters onto the production seams

extension Phase09Fixture.ArchiveSize {
    /// The categorical bucket the production signpost is expected to record for
    /// this fixture. A signpost never carries the byte count itself — a byte
    /// count of somebody's export is a weak fingerprint of that person.
    var magnitude: HLPerfSignpost.Magnitude {
        switch self {
        case .small: .small
        case .medium: .medium
        case .large: .large
        }
    }
}

extension Phase09CountingWriter {
    /// The counting writer, shaped for `ExportStore.persist` / `writeData`.
    var exportWriter: ExportPersistenceWriter {
        ExportPersistenceWriter(write)
    }
}

extension Phase09CountingReloader {
    /// The counting reloader, shaped for `WidgetSnapshotWriter`.
    var timelineReloader: WidgetTimelineReloader {
        WidgetTimelineReloader(reload: reload, reloadAll: { [self] in reload("all") })
    }
}

/// A counting analysis engine. Reports a caller-controlled cache verdict so both
/// `mood-analysis.cold` and `mood-analysis.hit` are reachable in a test even
/// though the production engine has no cache until Plan 09-04.
final class Phase09CountingAnalysisEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var computedCounts: [Int] = []
    private var probes = 0
    private let cached: Bool

    init(reportsCached: Bool = false) {
        cached = reportsCached
    }

    /// Entry counts handed to `compute`, in order. Its *length* is the number
    /// that matters: "exactly one engine invocation per unique key" is 09-04's
    /// whole contract.
    var computedEntryCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return computedCounts
    }

    var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return probes
    }

    private func recordProbe() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        probes += 1
        return cached
    }

    private func recordCompute(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        computedCounts.append(count)
    }

    var engine: MoodAnalysisEngine {
        MoodAnalysisEngine(
            isCached: { [self] _ in recordProbe() },
            compute: { [self] request in
                recordCompute(request.entries.count)
                return MoodInsights.compute(entries: request.entries)
            }
        )
    }
}

// 09-01's `Phase09CountingOutboxFactory` was retired by 09-05 in favour of
// `Phase09OutboxOpenLedger` (`Phase09PerformanceFixtures+Outbox.swift`), which
// counts the same opens and additionally records the thread each one ran on.
// Two counting seams over one factory is one seam too many.
