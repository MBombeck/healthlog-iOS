import Foundation

/// #151 (server v1.46.0) — document reads that may run in the background.
///
/// Since 1.46.0 `POST …/extract` and `POST …/index` read at most three parts
/// inside the request and report the rest through `extractionIncomplete`. With
/// `Prefer: respond-async` the server reads the whole document in the
/// background instead: it answers 202 with a run id, and `GET /api/ai-runs/{id}`
/// serves the result. Both routes therefore always send the preference and
/// handle either answer:
///
///   * **200** (an older server, or a preference the route could not apply):
///     the synchronous body, exactly as before;
///   * **202**: poll the run until it SUCCEEDED (its result) or FAILED (the
///     same typed error the synchronous route would have thrown, so
///     `aiRuns.readerBusy`, `documents.inbound.outputLimit`, rate limits and
///     refusals read the same either way).
///
/// The trigger goes through the account-bound consent lease like every other
/// document-AI call. The polls are plain reads of the caller's own run (the
/// server calls no model for them); the lease is re-checked after each one, so
/// a sign-out or account switch ends the wait.
extension DocumentsRepository {
    /// RFC 7240 preference both read routes honour.
    static let respondAsyncHeaders = ["Prefer": "respond-async"]

    /// Bounds for one wait between polls. The server says when to poll again;
    /// these only stop a zero (a busy loop) or an absurdly long answer.
    static let minimumPollDelay: Duration = .milliseconds(100)
    static let maximumPollDelay: Duration = .seconds(10)
    /// The longest the app waits for one run. The server ends a run itself
    /// well before this (no worker within 15 minutes, or the read's deadline).
    static let runWaitLimit: Duration = .seconds(20 * 60)

    /// What one read route answered.
    enum ReadOutcome<Sync: Sendable, RunResult: Sendable>: Sendable {
        /// 200, the synchronous body.
        case sync(Sync)
        /// 202, then the run's result.
        case run(RunResult)
    }

    // MARK: - Error discriminators

    /// `503 aiRuns.readerBusy` (or a run that failed with it): the server's
    /// document reader is busy; nothing was read or charged, try again later.
    nonisolated static func isReaderBusy(_ error: Error) -> Bool {
        serverCode(of: error) == "aiRuns.readerBusy"
    }

    /// `422 documents.inbound.outputLimit`: the reads stopped at the reader's
    /// output limit before a single complete value came back.
    nonisolated static func isOutputLimit(_ error: Error) -> Bool {
        serverCode(of: error) == "documents.inbound.outputLimit"
    }

    private nonisolated static func serverCode(of error: Error) -> String? {
        if case let HLError.server(_, code, _) = error { return code }
        return nil
    }

    // MARK: - Send preferring a background run

    /// Sends one read trigger with `Prefer: respond-async` under the consent
    /// lease and resolves either answer. `body` is `nil` for VISION mode (the
    /// server routes on `Content-Type`, so VISION must carry no body).
    func sendPreferringRun<Sync: Decodable & Sendable, RunResult: Decodable & Sendable>(
        path: String,
        query: [(String, String)] = [],
        body: Data?,
        sync _: Sync.Type,
        run _: RunResult.Type
    ) async throws -> ReadOutcome<Sync, RunResult> {
        let trigger = APIRequest<Data>(
            method: .post,
            path: path,
            query: query,
            body: body,
            extraHeaders: Self.respondAsyncHeaders
        )
        let leased = try await requestWithExternalAIConsent(trigger)
        do {
            let (data, response) = try await api.download(leased.request)
            try await validateExternalAIConsent(leased.lease)
            if response.statusCode == 202 {
                let accepted: DocumentAIRunAccepted = try Self.decodeEnvelope(data)
                let result: RunResult = try await waitForRun(
                    accepted.runId,
                    firstDelay: .milliseconds(accepted.pollAfterMs ?? 1000),
                    lease: leased.lease
                )
                return .run(result)
            }
            return try .sync(Self.decodeEnvelope(data))
        } catch {
            do {
                try await validateExternalAIConsent(leased.lease)
            } catch {
                throw DocumentAIConsentError.consentRequired
            }
            throw error
        }
    }

    /// Polls `GET /api/ai-runs/{id}` until the run ends.
    func waitForRun<RunResult: Decodable & Sendable>(
        _ runId: String,
        firstDelay: Duration,
        lease: DocumentAIConsentLease
    ) async throws -> RunResult {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.runWaitLimit
        var delay = firstDelay
        while true {
            try await Task.sleep(for: Self.clampedPollDelay(delay))
            let request: APIRequest<DocumentAIRun<RunResult>> = .get("/api/ai-runs/\(runId)")
            let run = try await api.send(request)
            try await validateExternalAIConsent(lease)
            switch run.status {
            case .succeeded:
                guard let result = run.result else {
                    throw HLError.decoding("ai run \(runId) succeeded without a readable result")
                }
                return result
            case .failed:
                throw (run.failure ?? DocumentAIRunFailure(code: "aiRuns.failed", message: "", status: 500)).asError
            case .queued, .running, .unknown:
                delay = .milliseconds(run.retryAfterMs ?? 1000)
            }
            guard clock.now < deadline else {
                throw HLError.server(status: 504, code: "aiRuns.timedOut", message: "ai run \(runId) did not end")
            }
        }
    }

    nonisolated static func clampedPollDelay(_ delay: Duration) -> Duration {
        min(max(delay, minimumPollDelay), maximumPollDelay)
    }

    /// Decodes the `data` of a `{ data, error }` envelope, falling back to the
    /// bare body like `APIClient.send` does.
    nonisolated static func decodeEnvelope<T: Decodable & Sendable>(_ data: Data) throws -> T {
        if let envelope = try? JSONDecoder.hlDefault.decode(APIEnvelope<T>.self, from: data),
           let payload = envelope.data
        {
            return payload
        }
        return try JSONDecoder.hlDefault.decode(T.self, from: data)
    }

    // MARK: - The two read routes

    /// `POST /api/documents/inbound/{id}/extract`, preferring a background run.
    /// A run answers with a summary, not the document, so the document and its
    /// staged facts are read afterwards; the run's `incomplete` carries over
    /// onto ``InboundDocumentDetail/extractionIncomplete``.
    func extractPreferringRun(id: String, body: Data?) async throws -> InboundDocumentDetail {
        let outcome = try await sendPreferringRun(
            path: "/api/documents/inbound/\(id)/extract",
            body: body,
            sync: InboundDocumentDetail.self,
            run: DocumentExtractRunResult.self
        )
        switch outcome {
        case let .sync(detail):
            return detail
        case let .run(summary):
            var refreshed = try await detail(id: id)
            if summary.incomplete { refreshed.extractionIncomplete = true }
            return refreshed
        }
    }

    /// `POST /api/documents/inbound/{id}/index`, preferring a background run.
    /// The run's result is the same body the synchronous route answers with.
    func indexPreferringRun(id: String, body: Data?) async throws -> DocumentIndexResult {
        let outcome = try await sendPreferringRun(
            path: "/api/documents/inbound/\(id)/index",
            body: body,
            sync: DocumentIndexResult.self,
            run: DocumentIndexResult.self
        )
        switch outcome {
        case let .sync(result), let .run(result):
            return result
        }
    }
}
