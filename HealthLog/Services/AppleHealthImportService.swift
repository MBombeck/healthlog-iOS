import Foundation

/// Actor that drives the one-shot Apple-Health `export.zip` import against the
/// live server endpoints:
///
/// - `POST /api/import/apple-health-export` — multipart upload (field `file`),
///   responds `202` + ``AppleHealthImportKickoffDTO``.
/// - `GET /api/import/apple-health-export/[jobId]/status` — poll, responds
///   ``AppleHealthImportStatusDTO``.
///
/// The upload carries an `Idempotency-Key` per PROJECT_GUIDE.md (POST). The server
/// additionally dedups on the file's SHA-256 (content-hash idempotency), so a
/// retried upload of the same export resolves to the same job either way.
///
/// No PII in logs: only byte counts + job ids are logged; the picked file's
/// name/path is never logged (it may carry the user's display name).
public actor AppleHealthImportService {
    private let api: APIClientProtocol
    /// Owner of the app-private multipart body file. Injectable so a test can
    /// point the whole lifecycle at a scratch directory and count it.
    let temps: AppleHealthImportTempStore
    /// Security-scoped access to the *picked* file. Owned here rather than by
    /// the calling store, because the scope is needed for exactly as long as
    /// the copy runs — see ``upload(fileURL:)``.
    private let scopedAccess: SecurityScopedAccess
    /// Per-chunk ledger for the copy. Default is a no-op; a test uses it to
    /// bound the largest buffer the copy ever holds without reading a
    /// resident-memory figure, which no simulator may honestly report.
    private let copyObserver: AppleHealthImportCopyObserver

    /// Largest buffer the archive copy may ever hold, and therefore the
    /// dominant term in the import's peak incremental allocation. One mebibyte
    /// is large enough that the syscall overhead is irrelevant next to the I/O
    /// and small enough that cancellation is observed promptly: the copy checks
    /// for cancellation once per chunk, so the worst-case latency is the time
    /// to move this much data.
    public static let maxCopyChunkBytes = 1 << 20

    /// Upper bound on polls so a stuck server job never spins forever. At a 2 s
    /// cadence this caps the foreground watch at ~20 min, well past a typical
    /// multi-hundred-MB parse; a job still running then is surfaced as a
    /// "still running" timeout, not an error.
    private let maxPolls: Int
    private let pollIntervalNanos: UInt64

    public init(
        api: APIClientProtocol,
        temps: AppleHealthImportTempStore = .live,
        scopedAccess: SecurityScopedAccess = .live,
        copyObserver: AppleHealthImportCopyObserver = .none,
        maxPolls: Int = 600,
        pollIntervalNanos: UInt64 = 2_000_000_000
    ) {
        self.api = api
        self.temps = temps
        self.scopedAccess = scopedAccess
        self.copyObserver = copyObserver
        self.maxPolls = maxPolls
        self.pollIntervalNanos = pollIntervalNanos
    }

    // MARK: - Upload

    /// The route the kickoff is posted to. Named once so the request, the
    /// idempotency contract and every test agree on one spelling.
    public static let uploadPath = "/api/import/apple-health-export"

    /// Streams the picked `export.zip` to the kickoff endpoint as multipart and
    /// returns the kickoff payload (`jobId` + initial `status`).
    ///
    /// The archive is **never** loaded into memory, and the multipart envelope
    /// **never** coexists with it: the envelope is assembled into an app-owned,
    /// complete-protected temp file by copying the picked archive through a
    /// bounded buffer, and the transport streams that file. The whole flow
    /// holds one chunk at a time.
    ///
    /// - Parameters:
    ///   - fileURL: a `file://` URL the document picker handed back. This
    ///     method owns the security-scoped access for exactly the copy, and
    ///     releases it before the upload begins — see ``prepareBody(source:boundary:)``.
    public func upload(fileURL: URL) async throws -> AppleHealthImportKickoffDTO {
        // Phase 09 Wave 0 — preparation and transport are measured separately,
        // because this plan replaces the first and must not be able to hide its
        // cost in the second.
        let magnitude = Self.magnitude(ofFileAt: fileURL)
        let boundary = "HLImport-\(UUID().uuidString)"
        let prepared: PreparedBody
        do {
            let prepare = HLPerfSignpost.open(.appleImportPrepare, magnitude: magnitude)
            var completed = false
            defer { HLPerfSignpost.close(prepare, completed: completed) }
            prepared = try await prepareBody(source: fileURL, boundary: boundary)
            completed = true
        }
        // The owned body dies here on every exit below — return, throw and
        // cancellation alike. A `defer` rather than a cleanup call per branch:
        // the branch somebody forgets is the branch that leaks 1.5 GiB of PHI.
        defer { AppleHealthImportTempStore.removeOwned(prepared.url) }

        HLLog.api.info("apple-health-import upload start (\(prepared.sourceByteCount) bytes)")

        let request = APIFileUploadRequest<AppleHealthImportKickoffDTO>(
            method: .post,
            path: Self.uploadPath,
            bodyFileURL: prepared.url,
            byteCount: prepared.byteCount,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )

        let upload = HLPerfSignpost.open(.appleImportUpload, magnitude: magnitude)
        var uploaded = false
        defer { HLPerfSignpost.close(upload, completed: uploaded) }
        do {
            // One authenticated request. No transport retry, no refresh replay,
            // no redirect follow — see ``APIClientProtocol/uploadFile(_:)``. A
            // 1.5 GiB body must not be re-sent by anything except a person who
            // asked for it again; the server's content-hash dedup makes that
            // explicit retry resolve to the same job.
            let kickoff = try await api.uploadFile(request)
            uploaded = true
            HLLog.api.info(
                "apple-health-import queued job=\(kickoff.jobId) idempotent=\(kickoff.idempotent ?? false)"
            )
            return kickoff
        } catch {
            // A cancelled upload surfaces from `URLSession` as a mapped
            // `URLError(.cancelled)`. The caller's `catch is CancellationError`
            // branch is the one that must run — otherwise a user who navigated
            // away is shown an error for something they chose.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// The assembled, app-owned multipart body.
    struct PreparedBody: Sendable {
        /// The app-owned file. Complete-protected, backup-excluded, and the
        /// caller's responsibility to delete.
        let url: URL
        /// Total length of the file — header + archive + trailer. This is the
        /// `Content-Length` the request states.
        let byteCount: Int
        /// Archive bytes only, for the log line. Never the file name or path:
        /// a picked document's name routinely carries the user's own name.
        let sourceByteCount: Int
    }

    /// Copy the picked archive into an app-owned multipart file, one bounded
    /// chunk at a time.
    ///
    /// Three orderings in here are contracts rather than style:
    ///
    /// * **The security scope is owned by this function**, not by the calling
    ///   store, and is released in a `defer` that runs before the upload
    ///   starts. Holding a provider's scope open for the duration of a
    ///   multi-minute upload is how a Files-app extension gets wedged, and the
    ///   scope is not needed once the bytes are ours.
    /// * **Cancellation is checked once per chunk, before the read.** The
    ///   worst-case latency is therefore the time to move one chunk, which is
    ///   what makes the cancellation budget a property of the code rather than
    ///   a hope about the runtime.
    /// * **Every handle is closed before the metadata is verified**, and the
    ///   verification happens before the file reaches the transport. A body
    ///   that lost its protection class is refused, not uploaded.
    private func prepareBody(source: URL, boundary: String) async throws -> PreparedBody {
        let scoped = scopedAccess.start(source)
        defer { if scoped { scopedAccess.stop(source) } }

        let destination = try await temps.makeOwnedFile()
        var completed = false
        defer { if !completed { AppleHealthImportTempStore.removeOwned(destination) } }

        let header = Self.multipartHeader(fileName: "export.zip", fieldName: "file", boundary: boundary)
        let trailer = Self.multipartTrailer(boundary: boundary)

        guard let reader = try? FileHandle(forReadingFrom: source) else {
            throw AppleHealthImportError.sourceUnreadable
        }
        let writer = try FileHandle(forWritingTo: destination)
        var sourceBytes = 0
        do {
            try writer.write(contentsOf: header)
            while true {
                try Task.checkCancellation()
                guard let chunk = try reader.read(upToCount: Self.maxCopyChunkBytes),
                      !chunk.isEmpty else { break }
                try writer.write(contentsOf: chunk)
                sourceBytes += chunk.count
                copyObserver.observe(chunkBytes: chunk.count)
            }
            try writer.write(contentsOf: trailer)
            try writer.synchronize()
        } catch {
            try? reader.close()
            try? writer.close()
            throw error
        }
        try? reader.close()
        try writer.close()
        try AppleHealthImportTempStore.verifyOwnedFile(at: destination)
        completed = true
        return PreparedBody(
            url: destination,
            byteCount: header.count + sourceBytes + trailer.count,
            sourceByteCount: sourceBytes
        )
    }

    /// The categorical size class of the picked archive, read with one `stat`.
    ///
    /// A byte count of somebody's health export is a weak fingerprint of that
    /// person, so the signpost carries the bucket and the bucket only. The
    /// probe is a metadata read: it does not open, map or materialise the file,
    /// which is the whole point of asking before the archive is loaded.
    nonisolated static func magnitude(ofFileAt url: URL) -> HLPerfSignpost.Magnitude {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return .unspecified }
        return .of(byteCount: size)
    }

    // MARK: - Poll

    /// Polls the status endpoint until the job reaches a terminal phase
    /// (`done` / `failed`), the poll budget is exhausted, or the task is
    /// cancelled. Each snapshot is handed to `onUpdate` on the way through so
    /// the UI can render live progress.
    ///
    /// - Returns: the terminal ``AppleHealthImportStatusDTO``.
    /// - Throws: ``AppleHealthImportError/timedOut`` if the budget is exhausted
    ///   before a terminal phase; `CancellationError` if cancelled.
    public func poll(
        jobId: String,
        onUpdate: @Sendable (AppleHealthImportStatusDTO) -> Void
    ) async throws -> AppleHealthImportStatusDTO {
        for attempt in 0 ..< maxPolls {
            try Task.checkCancellation()

            let request = APIRequest<AppleHealthImportStatusDTO>.get(
                "/api/import/apple-health-export/\(jobId)/status"
            )
            let status = try await api.send(request)
            onUpdate(status)

            if status.status.isTerminal {
                HLLog.api.info(
                    "apple-health-import terminal job=\(jobId) phase=\(status.status.rawValue)"
                )
                return status
            }

            // Don't sleep after the last attempt — we're about to time out.
            if attempt < maxPolls - 1 {
                try await Task.sleep(nanoseconds: pollIntervalNanos)
            }
        }
        HLLog.api.error("apple-health-import poll budget exhausted job=\(jobId)")
        throw AppleHealthImportError.timedOut
    }

    // MARK: - Multipart

    /// Builds an RFC-7578 multipart body with a single `file` part. `nonisolated`
    /// + `static` so it's trivially testable and crosses no actor boundary.
    nonisolated static func multipartBody(
        fileData: Data,
        fileName: String,
        fieldName: String,
        boundary: String
    ) -> Data {
        // Composed from the same two halves the file-backed path writes, so
        // "the streamed envelope is byte-identical to the buffered one" is a
        // structural property here and an asserted one in the tests.
        var body = multipartHeader(fileName: fileName, fieldName: fieldName, boundary: boundary)
        body.append(fileData)
        body.append(multipartTrailer(boundary: boundary))
        return body
    }

    /// Everything that precedes the archive bytes.
    nonisolated static func multipartHeader(
        fileName: String,
        fieldName: String,
        boundary: String
    ) -> Data {
        let crlf = "\r\n"
        var header = Data("--\(boundary)\(crlf)".utf8)
        header.append(Data(
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\(crlf)".utf8
        ))
        header.append(Data("Content-Type: application/zip\(crlf)\(crlf)".utf8))
        return header
    }

    /// Everything that follows the archive bytes, closing delimiter included.
    nonisolated static func multipartTrailer(boundary: String) -> Data {
        Data("\r\n--\(boundary)--\r\n".utf8)
    }
}

/// **Phase 09 / plan 09-02 — the security-scope seam.**
///
/// The document picker hands back a URL the app may read only between a
/// balanced `startAccessingSecurityScopedResource()` /
/// `stopAccessingSecurityScopedResource()` pair. Those two calls are invisible
/// to a unit test, and "the scope was released before the upload started" is
/// precisely the property that matters here — an unbalanced or long-held scope
/// on somebody's Files-app document is a real defect that produces no symptom
/// until it produces a stuck provider.
public struct SecurityScopedAccess: Sendable {
    private let startHandler: @Sendable (URL) -> Bool
    private let stopHandler: @Sendable (URL) -> Void

    public init(
        start: @escaping @Sendable (URL) -> Bool,
        stop: @escaping @Sendable (URL) -> Void
    ) {
        startHandler = start
        stopHandler = stop
    }

    public func start(_ url: URL) -> Bool {
        startHandler(url)
    }

    public func stop(_ url: URL) {
        stopHandler(url)
    }

    /// Production default — the two Foundation calls, unchanged.
    public static let live = SecurityScopedAccess(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// **Phase 09 / plan 09-02 — the copy ledger seam.**
///
/// Records the byte count of every chunk the archive copy moves. This is the
/// only honest way a simulator test can bound the import's peak incremental
/// allocation: the largest chunk plus the in-memory request body *is* the peak,
/// and both are counts rather than readings. A resident-memory figure would be
/// a number no simulator may claim; a count of bytes handed to a buffer is a
/// measurement of the code.
public struct AppleHealthImportCopyObserver: Sendable {
    private let handler: @Sendable (Int) -> Void

    public init(_ handler: @escaping @Sendable (Int) -> Void) {
        self.handler = handler
    }

    public func observe(chunkBytes: Int) {
        handler(chunkBytes)
    }

    /// Production default — records nothing, costs one retained closure.
    public static let none = AppleHealthImportCopyObserver { _ in }
}

/// Errors surfaced by ``AppleHealthImportService``.
public enum AppleHealthImportError: Error, Equatable, Sendable {
    /// The poll budget was exhausted before the job reached a terminal phase.
    case timedOut
    /// The app-owned multipart body file could not be created.
    case temporaryFileUnavailable
    /// The closed body file does not carry the protection / backup metadata it
    /// was created with. Refused rather than uploaded: the alternative is
    /// streaming PHI out of a file that is readable after first unlock.
    case temporaryFileNotProtected
    /// The picked archive could not be opened for reading — most often a
    /// security-scoped URL whose provider went away between pick and import.
    case sourceUnreadable
}
