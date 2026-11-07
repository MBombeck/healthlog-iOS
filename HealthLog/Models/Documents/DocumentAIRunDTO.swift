import Foundation

// #151 (server v1.40 / v1.46.0) — background document reads.
//
// `POST /api/documents/inbound/{id}/extract` and `/index` take
// `Prefer: respond-async` (RFC 7240). A server that honours it answers 202 with
// `AiRunAccepted` and the read runs in the background, polled through
// `GET /api/ai-runs/{id}` (`AiRun`). A server that does not (older, or a route
// that cannot apply it) answers 200 with the synchronous body as before. Both
// shapes decode tolerantly: every field the client does not strictly need is
// optional, so a forward-compatible field never fails the read.

/// The 202 body: `{ runId, status: "QUEUED", pollAfterMs }`.
struct DocumentAIRunAccepted: Decodable, Sendable, Equatable {
    let runId: String
    /// How long to wait before the first poll, in milliseconds.
    let pollAfterMs: Int?

    init(runId: String, pollAfterMs: Int?) {
        self.runId = runId
        self.pollAfterMs = pollAfterMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(String.self, forKey: .runId)
        pollAfterMs = try? c.decodeIfPresent(Int.self, forKey: .pollAfterMs)
    }

    private enum CodingKeys: String, CodingKey {
        case runId, pollAfterMs
    }
}

/// Where a background read stands.
enum DocumentAIRunStatus: String, Sendable, Equatable {
    case queued = "QUEUED"
    case running = "RUNNING"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    /// A status this build does not know; polled like a running one.
    case unknown
}

/// The failure a run ended with: the code, message and HTTP status the
/// queuing route would have answered with, or one of the run's own codes
/// (`aiRuns.readerBusy`, `aiRuns.timedOut`, `aiRuns.workerUnavailable`,
/// `aiRuns.failed`).
struct DocumentAIRunFailure: Decodable, Sendable, Equatable {
    let code: String
    let message: String
    let status: Int

    init(code: String, message: String, status: Int) {
        self.code = code
        self.message = message
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? c.decodeIfPresent(String.self, forKey: .code)) ?? "aiRuns.failed"
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? ""
        status = (try? c.decodeIfPresent(Int.self, forKey: .status)) ?? 500
    }

    /// The same typed error the synchronous route would have thrown, so every
    /// existing discriminator (rate limit, provider, already confirmed, …)
    /// reads a failed run exactly like a failed request.
    var asError: HLError {
        if status == 429 { return .rateLimited(retryAfter: nil) }
        return .server(status: status, code: code, message: message)
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, status
    }
}

/// One background run, `GET /api/ai-runs/{id}` (`data`). `Result` is the body
/// the queuing route answers synchronously (`DOCUMENT_INDEX`) or the run's own
/// summary (`DOCUMENT_EXTRACT` carries ``DocumentExtractRunResult``).
struct DocumentAIRun<Result: Decodable & Sendable>: Decodable, Sendable {
    let id: String
    let status: DocumentAIRunStatus
    /// Present once the run SUCCEEDED; `nil` when it failed to decode too.
    let result: Result?
    let failure: DocumentAIRunFailure?
    /// While not terminal, when to poll again (milliseconds).
    let retryAfterMs: Int?

    init(
        id: String,
        status: DocumentAIRunStatus,
        result: Result?,
        failure: DocumentAIRunFailure?,
        retryAfterMs: Int?
    ) {
        self.id = id
        self.status = status
        self.result = result
        self.failure = failure
        self.retryAfterMs = retryAfterMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        let rawStatus = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        status = DocumentAIRunStatus(rawValue: rawStatus) ?? .unknown
        result = try? c.decodeIfPresent(Result.self, forKey: .result)
        failure = try? c.decodeIfPresent(DocumentAIRunFailure.self, forKey: .error)
        retryAfterMs = try? c.decodeIfPresent(Int.self, forKey: .retryAfterMs)
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, result, error, retryAfterMs
    }
}

/// `DOCUMENT_EXTRACT` run result: `{ documentId, factsStaged, status,
/// incomplete? }`. The staged facts themselves are read from the document.
struct DocumentExtractRunResult: Decodable, Sendable, Equatable {
    let documentId: String
    let factsStaged: Int
    /// Part of the document's facts may be missing from the staged ones.
    let incomplete: Bool

    init(documentId: String, factsStaged: Int, incomplete: Bool) {
        self.documentId = documentId
        self.factsStaged = factsStaged
        self.incomplete = incomplete
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentId = (try? c.decodeIfPresent(String.self, forKey: .documentId)) ?? ""
        if let count = try? c.decodeIfPresent(Int.self, forKey: .factsStaged) {
            factsStaged = count
        } else if let count = try? c.decodeIfPresent(Double.self, forKey: .factsStaged) {
            factsStaged = Int(count)
        } else {
            factsStaged = 0
        }
        incomplete = (try? c.decodeIfPresent(Bool.self, forKey: .incomplete)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case documentId, factsStaged, incomplete
    }
}
