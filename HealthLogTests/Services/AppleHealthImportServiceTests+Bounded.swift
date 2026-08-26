import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **Phase 09 / plan 09-02 — the bounded, file-backed, one-shot import contract.**
///
/// A deliberate *extension of the same suite type* rather than a second suite,
/// following the split 09-01 made in `Phase09SignpostContractTests+Balance`:
/// `-only-testing:HealthLogTests/AppleHealthImportServiceTests` keeps running
/// both halves, where a new suite type would quietly stop being run while still
/// looking present in the tree.
///
/// What this file may and may not claim is worth stating once, because the
/// distinction is the whole reason Phase 9 exists. Every number below is a
/// **count** produced by a counting seam: bytes handed to a buffer, bytes
/// attached to a request, requests observed on a transport, chunks moved by a
/// copy. None of them is a duration and none is a resident-memory reading. The
/// peak-allocation statement is derived, not measured: the copy holds at most
/// one chunk and the request holds at most its in-memory body, so
/// `maxChunkBytes + inMemoryBodyBytes` is an upper bound on the import's peak
/// incremental allocation — and both terms are counted here. The 32 MiB budget
/// frozen in `scripts/validate-phase09-performance-evidence.sh` is an RSS
/// figure and stays a physical-device claim; this is the count-form of it.
extension AppleHealthImportServiceTests {
    static let uploadPath = "/api/import/apple-health-export"

    /// The archive sizes the bounded-import contract is stated against.
    ///
    /// **This list moved once, deliberately.** The RED run carried only the
    /// 16 MiB fixture, because the implementation it was written against reads
    /// the whole archive into a `Data` and then builds a second copy of it
    /// inside a multipart envelope — running that at 256 MiB or 1.5 GiB would
    /// have materialised, inside the test, the exact allocation the test exists
    /// to forbid. The RED therefore fails on *shape* ("the request carried an
    /// in-memory body") at a size the old code survives, and the full matrix
    /// lands with the implementation that can carry it.
    static let boundedFixtureSizes: [Phase09Fixture.ArchiveSize] = Phase09Fixture.ArchiveSize.allCases

    // MARK: - Bounded, file-backed, one-shot

    @Test("a large import is file-backed, bounded, non-scaling and one-shot")
    func largeImportIsFileBackedBoundedAndOneShot() async throws {
        let sources = try Phase09Scratch("09-02-bounded-src")
        let tempRoot = try Phase09Scratch("09-02-bounded-tmp")

        var inMemoryBodyBytes: [String: Int] = [:]
        var peakIncrementalBytes: [String: Int] = [:]
        var requestCounts: [String: Int] = [:]

        for size in Self.boundedFixtureSizes {
            let fixture = try Phase09SparseFile(size: size, in: sources.url)
            // The fixture must be a hole, not a file. A non-sparse fixture
            // would make every statement below a statement about the disk.
            #expect(fixture.allocatedBytes <= 65536)
            #expect(fixture.reportedLogicalBytes == size.rawValue)

            let temps = AppleHealthImportTempStore(directory: tempRoot.url)
            let chunks = ChunkLedger()
            let api = Phase09CountingAPIClient()
            api.stub(path: Self.uploadPath, json: #"{"jobId":"ij-bounded","status":"queued"}"#)

            let service = AppleHealthImportService(
                api: api,
                temps: temps,
                copyObserver: AppleHealthImportCopyObserver { chunks.record(chunkBytes: $0) }
            )
            let kickoff = try await service.upload(fileURL: fixture.url)
            #expect(kickoff.jobId == "ij-bounded")

            let calls = api.calls
            requestCounts[size.label] = calls.count
            let carried = calls.first?.bodyByteCount ?? 0
            inMemoryBodyBytes[size.label] = carried
            peakIncrementalBytes[size.label] = carried + chunks.maxChunkBytes

            // No chunk may exceed the declared ceiling, and the whole archive
            // must have gone through: a copy that stopped early would report a
            // small maximum for the best possible reason and the worst.
            #expect(chunks.maxChunkBytes <= AppleHealthImportService.maxCopyChunkBytes)
            #expect(chunks.totalBytes == Int(size.rawValue))
            // Nothing owned survives the call, at any size.
            let leftovers = await temps.ownedFiles()
            #expect(leftovers.isEmpty)
        }

        // Exactly one request per import, at every size. A body this large may
        // not be replayed by the transport for any reason.
        #expect(Set(requestCounts.values) == [1])

        // The marker assertion. `nil`/zero here is not "a small body" — it is
        // "the request never had a body in this process at all".
        let worstInMemoryBody = inMemoryBodyBytes.values.max() ?? 0
        #expect(
            worstInMemoryBody == 0,
            "EXPECTED_RED: Apple Health import still buffers the full multipart body"
        )

        // Bounded, and — the stronger half — bounded by the same number at
        // every size. A budget that is merely met at 1.5 GiB could still be a
        // budget that scales and happens to fit; one identical value across a
        // 96× size range cannot be.
        let worstPeak = peakIncrementalBytes.values.max() ?? 0
        #expect(worstPeak <= 32 * 1024 * 1024)
        // One exact value, not merely one value: the peak is a single copy
        // chunk at 16 MiB, at 256 MiB and at 1.5 GiB alike. "The set has one
        // element" would also be satisfied by a number that scaled and happened
        // to land on the same figure three times; naming the figure cannot be.
        #expect(Set(peakIncrementalBytes.values) == [AppleHealthImportService.maxCopyChunkBytes])
    }

    // MARK: - Temp lifecycle

    @Test("success, failure and cancellation each leave no owned temp behind")
    func cancelAndFailureRemoveOwnedTemps() async throws {
        let sources = try Phase09Scratch("09-02-lifecycle-src")
        let tempRoot = try Phase09Scratch("09-02-lifecycle-tmp")
        let temps = AppleHealthImportTempStore(directory: tempRoot.url)
        let source = try Phase09SparseFile(
            logicalBytes: 4 * 1024 * 1024,
            in: sources.url,
            name: "phase09-lifecycle.zip"
        )

        // 1 — success.
        let served = Phase09CountingAPIClient()
        served.stub(path: Self.uploadPath, json: #"{"jobId":"ij-ok","status":"queued"}"#)
        let kickoff = try await AppleHealthImportService(api: served, temps: temps).upload(fileURL: source.url)
        #expect(kickoff.jobId == "ij-ok")

        // 2 — failure. The counting client has no canned answer for this path,
        // so the call throws from inside the transport, after the body file
        // exists.
        let refusing = Phase09CountingAPIClient()
        await #expect(throws: (any Error).self) {
            _ = try await AppleHealthImportService(api: refusing, temps: temps).upload(fileURL: source.url)
        }

        // 3 — cancellation.
        let cancelled = Phase09CountingAPIClient()
        cancelled.stub(path: Self.uploadPath, json: #"{"jobId":"ij-cancel","status":"queued"}"#)
        let task = Task {
            try await AppleHealthImportService(api: cancelled, temps: temps).upload(fileURL: source.url)
        }
        task.cancel()
        _ = try? await task.value

        let created = await temps.createdCount
        let remaining = await temps.ownedFiles()
        // "None remain" is also true of a store that was never asked for a
        // file, which is exactly the state the old implementation leaves it in.
        // The pair is the lifecycle statement.
        #expect(remaining.isEmpty)
        #expect(
            created == 3,
            "EXPECTED_RED: Apple Health import temp lifecycle is incomplete"
        )
    }

    // MARK: - Byte-identical envelope, known length, protected file

    @Test("the streamed envelope is byte-identical to the buffered one, protected and backup-excluded")
    func streamedEnvelopeMatchesTheBufferedOneByteForByte() async throws {
        let sources = try Phase09Scratch("09-02-identity-src")
        let tempRoot = try Phase09Scratch("09-02-identity-tmp")
        let temps = AppleHealthImportTempStore(directory: tempRoot.url)

        // Deliberately small and deliberately read whole *in the test*: the
        // production path never does this, and comparing a few kilobytes is the
        // only way to make "byte-identical" an assertion rather than a claim.
        let archive = Data((0 ..< 8192).map { UInt8($0 % 251) })
        let source = sources.url.appendingPathComponent("phase09-identity.zip")
        try archive.write(to: source)

        let inspector = PreparedBodyInspector(kickoffJSON: #"{"jobId":"ij-identity","status":"queued"}"#)
        let scope = ScopeLedger()
        let service = AppleHealthImportService(
            api: inspector,
            temps: temps,
            scopedAccess: scope.access(alsoRecordingInto: inspector)
        )
        let kickoff = try await service.upload(fileURL: source)
        #expect(kickoff.jobId == "ij-identity")

        let observed = try #require(inspector.observed)
        let boundary = try #require(observed.boundary)
        let expected = AppleHealthImportService.multipartBody(
            fileData: archive,
            fileName: "export.zip",
            fieldName: "file",
            boundary: boundary
        )
        // Byte for byte, against the very builder the old in-memory path used.
        #expect(observed.bytes == expected)
        // And the length the request declares is that file's real length.
        #expect(observed.declaredByteCount == expected.count)
        #expect(observed.actualFileByteCount == expected.count)

        // Protection metadata, read while the file is still alive. The platform
        // may report no class at all — the simulator implements no data
        // protection — so the assertion is "never a weaker class", which is the
        // strongest statement a simulator run may honestly make. The literal
        // itself is pinned by `productionFilesNoLongerBufferTheArchive` below.
        #expect(observed.reportedProtection == .complete || observed.reportedProtection == nil)
        #expect(observed.isExcludedFromBackup == true)

        // The security scope was taken once, released once, and released before
        // the transport was ever handed the file.
        #expect(inspector.timeline == ["scope-start", "scope-stop", "upload"])
    }

    // MARK: - Cancellation

    @Test("cancellation is observed within one copy chunk, reaches no transport, and leaves nothing behind")
    func cancellationStopsWithinOneCopyChunk() async throws {
        let sources = try Phase09Scratch("09-02-cancel-src")
        let tempRoot = try Phase09Scratch("09-02-cancel-tmp")
        let temps = AppleHealthImportTempStore(directory: tempRoot.url)
        let source = try Phase09SparseFile(size: .small, in: sources.url)

        let cancelAfterChunks = 4
        let chunks = ChunkLedger()
        let api = Phase09CountingAPIClient()
        api.stub(path: Self.uploadPath, json: #"{"jobId":"ij-never","status":"queued"}"#)
        let scope = ScopeLedger()

        let service = AppleHealthImportService(
            api: api,
            temps: temps,
            scopedAccess: scope.access(),
            copyObserver: AppleHealthImportCopyObserver { bytes in
                chunks.record(chunkBytes: bytes)
                // Cancel the very task running the copy. No external handle, so
                // there is no race between storing the task and reaching the
                // chunk that cancels it — the latency below is a property of
                // the loop, not of the scheduler.
                //
                // The upload runs in its own unstructured `Task` for exactly
                // this reason. Called on the test's own task, this line cancels
                // *the test*, which Swift Testing then reports as a skip — a
                // green run with one fewer case in it, which is the quietest
                // possible way for a cancellation contract to stop being
                // checked.
                if chunks.chunkCount == cancelAfterChunks {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )

        let upload = Task { try await service.upload(fileURL: source.url) }
        var thrown: (any Error)?
        do {
            _ = try await upload.value
        } catch {
            thrown = error
        }
        #expect(!Task.isCancelled)

        #expect(thrown is CancellationError)
        // Zero further chunks after the cancel: the loop checks cancellation at
        // the top of every iteration, so the worst case is the chunk already in
        // flight. This is the count-form of the frozen one-second cancellation
        // budget — the seconds themselves stay a physical-device claim.
        #expect(chunks.chunkCount == cancelAfterChunks)
        #expect(chunks.maxChunkBytes <= AppleHealthImportService.maxCopyChunkBytes)
        // A cancelled import never reaches the network at all.
        #expect(api.calls.isEmpty)
        // Nothing owned survives, and the picked file's scope is released.
        let leftovers = await temps.ownedFiles()
        #expect(leftovers.isEmpty)
        #expect(scope.starts == 1)
        #expect(scope.stops == 1)
    }

    // MARK: - The production source itself

    @Test("the production import path reads no whole file and attaches no in-memory body")
    func productionFilesNoLongerBufferTheArchive() throws {
        let service = try Self.executableSource("HealthLog/Services/AppleHealthImportService.swift")
        // The exact call this plan removed. Counted, not probed.
        #expect(Self.occurrences(of: "Data(contentsOf:", in: service) == 0)
        #expect(Self.occurrences(of: "Data(contentsOf: fileURL)", in: service) == 0)
        // The multipart envelope is never attached as a request body.
        #expect(Self.occurrences(of: "httpBody", in: service) == 0)
        #expect(Self.occurrences(of: "multipartBody(", in: service) == 1) // its own definition

        let transport = try Self.executableSource("HealthLog/Services/APIClient+FileUpload.swift")
        #expect(Self.occurrences(of: "httpBody", in: transport) == 0)
        #expect(Self.occurrences(of: "Data(contentsOf:", in: transport) == 0)
        // The redirect refusal and the single-attempt shape, pinned in source
        // so a later edit that reintroduces a retry loop is visible here too.
        #expect(Self.occurrences(of: "while true", in: transport) == 0)

        // The protection literal lives next to the bytes it protects.
        let temps = try Self.executableSource("HealthLog/Services/AppleHealthImportTempStore.swift")
        #expect(Self.occurrences(of: "FileProtectionType.complete", in: temps) >= 1)
        #expect(Self.occurrences(of: "isExcludedFromBackup", in: temps) >= 1)

        // The store no longer holds the picked file's scope across the upload.
        let exportStore = try Self.executableSource("HealthLog/Stores/ExportStore.swift")
        #expect(Self.occurrences(of: "startAccessingSecurityScopedResource", in: exportStore) == 0)
        #expect(Self.occurrences(of: "stopAccessingSecurityScopedResource", in: exportStore) == 0)
    }

    // MARK: - Source helpers

    private static func repositoryRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The file with comment lines removed — this suite's own prose names the
    /// symbols the scan forbids.
    private static func executableSource(_ relativePath: String) throws -> String {
        let contents = try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
        return contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
            .joined(separator: "\n")
    }

    /// Counts, never a short-circuiting probe — the Swift shape of the
    /// `grep -q` defect this phase's tooling produced three separate times.
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}

// MARK: - Doubles

/// A counting client that inspects the prepared body **while it is still
/// alive**, then answers a canned kickoff.
///
/// Reading the file here is the one place in this suite where that is correct:
/// the fixture is 8 KiB, and "the streamed envelope equals the buffered one"
/// cannot be asserted without both. Everything that runs at 1.5 GiB uses the
/// counting client, which never opens the file at all.
private final class PreparedBodyInspector: APIClientProtocol, Sendable {
    struct Observation: Sendable {
        let bytes: Data
        let declaredByteCount: Int
        let actualFileByteCount: Int
        let contentType: String
        let reportedProtection: FileProtectionType?
        let isExcludedFromBackup: Bool?

        var boundary: String? {
            guard let range = contentType.range(of: "boundary=") else { return nil }
            return String(contentType[range.upperBound...])
        }
    }

    // `Mutex`, not an `NSLock` behind an unchecked-`Sendable` conformance: this
    // type is touched from an `async` witness, where `NSLock.lock()` is
    // unavailable outright, and 09-11's rule is checked concurrency rather than
    // a promise the compiler cannot verify.
    private let recorded = Mutex<Observation?>(nil)
    private let events = Mutex<[String]>([])
    private let kickoffJSON: String

    init(kickoffJSON: String) {
        self.kickoffJSON = kickoffJSON
    }

    var observed: Observation? {
        recorded.withLock { $0 }
    }

    /// Ordered ledger of scope acquisition, release and transport hand-off.
    var timeline: [String] {
        events.withLock { $0 }
    }

    func note(_ event: String) {
        events.withLock { $0.append(event) }
    }

    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw Phase09FixtureError.noCannedResponse(path: "send")
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw Phase09FixtureError.noCannedResponse(path: "download")
    }

    func uploadFile<T: Decodable & Sendable>(_ request: APIFileUploadRequest<T>) async throws -> T {
        note("upload")
        let bytes = try Data(contentsOf: request.bodyFileURL)
        let values = try? request.bodyFileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let observation = Observation(
            bytes: bytes,
            declaredByteCount: request.byteCount,
            actualFileByteCount: bytes.count,
            contentType: request.contentType,
            reportedProtection: AppleHealthImportTempStore.reportedProtection(of: request.bodyFileURL),
            isExcludedFromBackup: values?.isExcludedFromBackup
        )
        recorded.withLock { $0 = observation }
        return try JSONDecoder.hlDefault.decode(T.self, from: Data(kickoffJSON.utf8))
    }
}

/// Counts the balanced security-scope pair, and optionally records its ordering
/// against the transport hand-off.
private final class ScopeLedger: Sendable {
    private let started = Mutex(0)
    private let stopped = Mutex(0)

    var starts: Int {
        started.withLock { $0 }
    }

    var stops: Int {
        stopped.withLock { $0 }
    }

    func access(alsoRecordingInto inspector: PreparedBodyInspector? = nil) -> SecurityScopedAccess {
        SecurityScopedAccess(
            start: { [self] _ in
                started.withLock { $0 += 1 }
                inspector?.note("scope-start")
                // The fixtures are plain temp files, not provider-vended
                // documents, so the real call would answer `false`. Answering
                // `true` here keeps the *balanced release* under test — the
                // property that actually matters — instead of skipping it.
                return true
            },
            stop: { [self] _ in
                stopped.withLock { $0 += 1 }
                inspector?.note("scope-stop")
            }
        )
    }
}

/// Per-chunk ledger for the archive copy. `Mutex`-backed rather than an
/// `NSLock` behind an unchecked-`Sendable` conformance (Plan 09-11's rule):
/// checked concurrency instead of a promise the compiler cannot verify.
final class ChunkLedger: Sendable {
    private struct State {
        var maximum = 0
        var total = 0
        var count = 0
    }

    private let state = Mutex(State())

    func record(chunkBytes: Int) {
        state.withLock {
            $0.maximum = max($0.maximum, chunkBytes)
            $0.total += chunkBytes
            $0.count += 1
        }
    }

    /// The largest single buffer the copy ever held.
    var maxChunkBytes: Int {
        state.withLock { $0.maximum }
    }

    /// Everything the copy moved, so a short copy cannot pass for a bounded one.
    var totalBytes: Int {
        state.withLock { $0.total }
    }

    /// How many chunks were moved. Used to bound cancellation latency in
    /// chunks, which is the count-form of the frozen one-second budget.
    var chunkCount: Int {
        state.withLock { $0.count }
    }
}
