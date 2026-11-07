import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// #149 item 3 — a lab report read by the server (server v1.43.11).
///
///   * `GET  /api/labs/ocr/capability`: whether the server can read a report,
///     how (`vision` or `text`), and whether it takes a PDF. A server without
///     the route (404) or any other failure reads as "not offered", so the scan
///     stays on the device exactly as before.
///   * `POST /api/labs/ocr/extract`: the read. A photo goes as JPEG, a PDF
///     unchanged, in `text` mode only the text recognised on the device. Since
///     v1.40 the route queues the read (202, polled through
///     ``AIRunsRepository``); an older server that answers 200 hands the rows
///     back directly. Both are handled.
///   * `POST /api/labs/ocr/commit`: writes only the confirmed rows (1 to 400).
///
/// **Consent.** A lab report is a document: the read goes out under the same
/// account-bound consent lease as every document AI call
/// (``DocumentAIConsentLeaseProvider``), without automatic retries, and the
/// lease is checked again after every poll. No lease, no request.
actor LabsOCRRepository {
    /// What goes to the server for one read.
    enum Upload: Sendable, Equatable {
        /// A photographed page, JPEG-encoded.
        case jpeg(Data)
        /// A PDF, unchanged.
        case pdf(Data)
        /// Text recognised on the device (`mode: text`); the image stays here.
        case text(String)
    }

    /// The server's upload ceiling (`labs.ocr.fileTooLarge` above it).
    static let maxUploadBytes = 12 * 1024 * 1024

    private let api: APIClientProtocol
    private let consent: DocumentAIConsentLeaseProvider
    private let runs: AIRunsRepository
    private let uploadGrace: any LabUploadGraceProviding

    init(
        api: APIClientProtocol,
        consent: DocumentAIConsentLeaseProvider,
        runs: AIRunsRepository? = nil,
        uploadGrace: any LabUploadGraceProviding = NoLabUploadGrace()
    ) {
        self.api = api
        self.consent = consent
        self.runs = runs ?? AIRunsRepository(api: api)
        self.uploadGrace = uploadGrace
    }

    // MARK: - Capability

    /// `nil` when the server cannot say (older server, offline, refusal): the
    /// scan then offers only the on-device read.
    func capability() async -> LabsOCRCapability? {
        try? await api.send(APIRequest<LabsOCRCapability>.get("/api/labs/ocr/capability"))
    }

    // MARK: - Extract

    /// Reads one report and returns the proposed rows. Throws the server's
    /// typed refusal (`HLError.server` with `labs.ocr.*` / `aiRuns.*`),
    /// ``DocumentAIConsentError/consentRequired`` without a lease, or
    /// `CancellationError` when the caller cancelled.
    func extract(
        _ upload: Upload,
        onStatus: @Sendable (DocumentAIRunStatus) async -> Void = { _ in }
    ) async throws -> LabsOCRExtractResult {
        let request = try Self.extractRequest(for: upload)
        guard let lease = await consent.currentLease(), await consent.currentLease() == lease else {
            throw DocumentAIConsentError.consentRequired
        }
        var headers = request.extraHeaders
        headers["Authorization"] = lease.authorizationHeader
        let leased = APIRequest<Data>(
            method: request.method,
            path: request.path,
            body: request.body,
            extraHeaders: headers,
            maxRetries: 0,
            allowsAuthenticationRecovery: false
        )
        let check: @Sendable () async throws -> Void = { [consent] in
            guard await consent.currentLease() == lease else { throw DocumentAIConsentError.consentRequired }
        }
        let (data, response) = try await sendUnderGrace(leased)
        try await check()
        if response.statusCode == 202 {
            let accepted: DocumentAIRunAccepted = try DocumentsRepository.decodeEnvelope(data)
            return try await runs.wait(
                for: accepted.runId,
                firstDelay: .milliseconds(accepted.pollAfterMs ?? 1000),
                afterEachPoll: check,
                onStatus: onStatus
            )
        }
        return try DocumentsRepository.decodeEnvelope(data)
    }

    /// POLISH-A A4 — sends the trigger under a short background grace window.
    /// Switching apps right after "read" used to cut the upload, which then
    /// ended as "no connection". The window keeps the upload alive for the
    /// time iOS grants; when that runs out first, the upload is cancelled and
    /// ends with ``LabUploadInterrupted`` and a sentence that says so. The
    /// polling after a 202 resumes on its own (``AIRunsRepository``), so only
    /// the upload needs the window. Not a background transfer.
    private func sendUnderGrace(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        let api = api
        let expired = LabUploadOnce()
        let transfer = Task { try await api.download(request) }
        let end = await uploadGrace.begin(name: "HealthLog.labReportUpload") {
            _ = expired.take()
            transfer.cancel()
        }
        let outcome = await withTaskCancellationHandler {
            await transfer.result
        } onCancel: {
            transfer.cancel()
        }
        await end()
        if case .failure = outcome, !Task.isCancelled, expired.isTaken {
            throw LabUploadInterrupted.backgroundTimeEnded
        }
        return try outcome.get()
    }

    /// The trigger request for one upload, without credentials. VISION is
    /// multipart with a `file` part; TEXT is `{ mode: "text", text }`.
    nonisolated static func extractRequest(for upload: Upload) throws -> APIRequest<Data> {
        let path = "/api/labs/ocr/extract"
        let prefer = ["Prefer": "respond-async"]
        switch upload {
        case let .text(text):
            let body = try JSONEncoder.hlDefault.encode(["mode": "text", "text": text])
            return APIRequest(method: .post, path: path, body: body, extraHeaders: prefer)
        case let .jpeg(data), let .pdf(data):
            guard data.count <= maxUploadBytes else {
                throw HLError.server(status: 413, code: "labs.ocr.fileTooLarge", message: "file too large")
            }
            let isPDF = upload == .pdf(data)
            let boundary = "HLLabReport-\(UUID().uuidString)"
            let body = AvatarRepository.multipartBody(
                fieldName: "file",
                fileName: isPDF ? "report.pdf" : "report.jpg",
                mimeType: isPDF ? "application/pdf" : "image/jpeg",
                payload: data,
                boundary: boundary
            )
            var headers = prefer
            headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
            return APIRequest(method: .post, path: path, body: body, extraHeaders: headers)
        }
    }

    // MARK: - Commit

    /// Writes the confirmed rows. The key stays the same while the rows do,
    /// so a retry after a lost answer is answered from the first write.
    func commit(_ body: LabsOCRCommitRequest, idempotencyKey: IdempotencyKey) async throws -> LabsOCRCommitResult {
        let request: APIRequest<LabsOCRCommitResult> = try .post(
            "/api/labs/ocr/commit",
            body: body,
            idempotencyKey: idempotencyKey
        )
        return try await api.send(request)
    }
}

// MARK: - Upload grace (POLISH-A A4)

/// The upload of a lab report ran out of background time before it finished.
enum LabUploadInterrupted: Error, Equatable {
    case backgroundTimeEnded
}

/// A short background grace window around one upload. `begin` returns the
/// call that ends it; `onExpiry` runs when the system takes the time back
/// before the upload finished.
protocol LabUploadGraceProviding: Sendable {
    func begin(name: String, onExpiry: @escaping @Sendable () -> Void) async -> @Sendable () async -> Void
}

/// A one-shot latch: `take()` is `true` for the first caller only.
final class LabUploadOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }

    var isTaken: Bool {
        lock.withLock { taken }
    }
}

/// No window: tests, and builds without a UIKit application object.
struct NoLabUploadGrace: LabUploadGraceProviding {
    func begin(name _: String, onExpiry _: @escaping @Sendable () -> Void) async -> @Sendable () async -> Void {
        {}
    }
}

#if canImport(UIKit)
    /// `UIApplication.beginBackgroundTask` around the upload. The assertion
    /// ends exactly once: in the expiration handler (where iOS asks for it
    /// back) or after the upload, whichever comes first. Unavailable to app
    /// extensions like ``UIKitBackgroundExecutionLease``.
    @available(iOSApplicationExtension, unavailable)
    struct UIKitLabUploadGrace: LabUploadGraceProviding {
        func begin(name: String, onExpiry: @escaping @Sendable () -> Void) async -> @Sendable () async -> Void {
            let ended = LabUploadOnce()
            let identifier = await MainActor.run { () -> UIBackgroundTaskIdentifier in
                let box = Box()
                box.value = UIApplication.shared.beginBackgroundTask(withName: name) {
                    MainActor.assumeIsolated {
                        onExpiry()
                        guard box.value != .invalid, ended.take() else { return }
                        UIApplication.shared.endBackgroundTask(box.value)
                    }
                }
                return box.value
            }
            return {
                guard identifier != .invalid, ended.take() else { return }
                await MainActor.run { UIApplication.shared.endBackgroundTask(identifier) }
            }
        }

        @MainActor
        private final class Box {
            var value: UIBackgroundTaskIdentifier = .invalid
        }
    }
#endif
