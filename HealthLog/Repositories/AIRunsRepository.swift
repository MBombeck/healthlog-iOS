import Foundation

/// `GET /api/ai-runs/{id}`: waits for one background AI run (server v1.40) and
/// returns its result. Shared by the lab-report read (LAB-OCR) and the
/// supplement label read (SUPP-EDIT); the wire types are the ones the document
/// reads introduced (``DocumentAIRun``, ``DocumentAIRunFailure``).
///
/// A poll is a plain read of the caller's own run (the server calls no model
/// for it), so it goes out with the normal session. Three things end a wait:
///   * the run ends (SUCCEEDED returns the result, FAILED throws the error the
///     queuing route would have thrown);
///   * the caller cancels the task (the person tapped Cancel);
///   * ``waitLimit`` passes (the server ends a run itself well before that).
///
/// **Resume after an app switch.** A poll cut off while the app was in the
/// background (a lost connection, a timeout, offline) is not the end of the
/// run: the run lives on the server for an hour after it ends. Such a failure
/// waits one poll interval and asks again, until the limit.
actor AIRunsRepository {
    private let api: APIClientProtocol
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Bounds for one wait between polls. The server says when to poll again;
    /// these only stop a zero (a busy loop) or an absurdly long answer.
    static let minimumPollDelay: Duration = .milliseconds(100)
    static let maximumPollDelay: Duration = .seconds(10)
    /// After a transport failure the next poll waits at least this long.
    static let transportRetryDelay: Duration = .seconds(2)
    /// The longest the app waits for one run. A run with no worker ends after
    /// fifteen minutes on the server (`aiRuns.workerUnavailable`).
    static let waitLimit: Duration = .seconds(16 * 60)

    init(
        api: APIClientProtocol,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.api = api
        self.sleep = sleep
    }

    /// Polls until the run ends. `afterEachPoll` runs after every answered
    /// poll (a consent lease check, for instance) and may throw to end the
    /// wait. `onStatus` reports where the run stands, for a calm progress line.
    func wait<RunResult: Decodable & Sendable>(
        for runId: String,
        firstDelay: Duration,
        limit: Duration = AIRunsRepository.waitLimit,
        afterEachPoll: @Sendable () async throws -> Void = {},
        onStatus: @Sendable (DocumentAIRunStatus) async -> Void = { _ in }
    ) async throws -> RunResult {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        var delay = firstDelay
        while true {
            try await sleep(Self.clamped(delay))
            try Task.checkCancellation()
            guard clock.now < deadline else { throw Self.timedOut(runId) }
            let run: DocumentAIRun<RunResult>
            do {
                run = try await api.send(APIRequest<DocumentAIRun<RunResult>>.get("/api/ai-runs/\(runId)"))
            } catch let error where Self.isResumable(error) {
                try Task.checkCancellation()
                delay = max(Self.transportRetryDelay, delay)
                continue
            }
            try await afterEachPoll()
            await onStatus(run.status)
            switch run.status {
            case .succeeded:
                guard let result = run.result else {
                    throw HLError.decoding("ai run \(runId) succeeded without a readable result")
                }
                return result
            case .failed:
                throw Self.error(for: run.failure)
            case .queued, .running, .unknown:
                delay = .milliseconds(run.retryAfterMs ?? 1000)
            }
        }
    }

    nonisolated static func clamped(_ delay: Duration) -> Duration {
        min(max(delay, minimumPollDelay), maximumPollDelay)
    }

    /// A poll that never reached the server, or was cut off on the way back.
    nonisolated static func isResumable(_ error: Error) -> Bool {
        switch error as? HLError {
        case .network(.timeout), .network(.connectionLost), .network(.writeCancelled), .offline:
            true
        default:
            (error as? URLError) != nil
        }
    }

    /// The error a FAILED run ends with. Unlike ``DocumentAIRunFailure/asError``
    /// a 429 keeps its code, so a day's budget (`…budgetExceeded`) reads apart
    /// from a short rate limit.
    nonisolated static func error(for failure: DocumentAIRunFailure?) -> HLError {
        let failure = failure ?? DocumentAIRunFailure(code: "aiRuns.failed", message: "", status: 500)
        if failure.status == 429, !failure.code.hasSuffix("budgetExceeded") {
            return .rateLimited(retryAfter: nil)
        }
        return .server(status: failure.status, code: failure.code, message: failure.message)
    }

    nonisolated static func timedOut(_ runId: String) -> HLError {
        .server(status: 504, code: "aiRuns.timedOut", message: "ai run \(runId) did not end")
    }
}
