import Foundation

/// Vault Phase 4 — document chat (server v1.27.33, iOS issue #43). Per-document
/// Q&A grounded ONLY in one stored document's indexed text.
///
/// **Transport reuse.** The streaming POST rides the SAME shared SSE transport the
/// Coach turn uses — `APIClientProtocol.streamLines(_:)` (the `URLSession.bytes`
/// idle-reset streaming session). The `token` / `done` / `error` wire frames are a
/// subset of the Coach's, so the frame reassembly + decode below mirrors
/// `CoachServerService`'s parser (kept local because that service lives in the
/// app target and this repository is `HealthLogCore` — the module boundary rules
/// out a direct symbol reuse; the load-bearing SSE plumbing IS shared via
/// `streamLines`).
///
/// **Gating (local + server; surfaced honestly).** Chat is offered only for a
/// content-indexed document (`hasContentIndex`); a `422 documents.inbound.notIndexed`
/// maps to ``DocumentChatError/notIndexed`` and a `403 consent.ai.required` to
/// ``DocumentChatError/consentRequired`` so the sheet can point at the index
/// action / a consent CTA rather than a dead chat. Before the POST opens, the
/// repository also captures and revalidates the current account-bound document-AI
/// lease; every awaited chunk is checked again before it can reach the consumer.
/// Budget exhaustion surfaces as a calm ``DocumentChatError/limitReached``.
public extension DocumentsRepository {
    // MARK: - Error discriminators

    /// True when chat was refused because the document has no content index yet
    /// (`422`, `documents.inbound.notIndexed`). The UI points at the index action.
    nonisolated static func isNotIndexed(_ error: Error) -> Bool {
        if case let HLError.server(status, code, message) = error {
            return status == 422 &&
                (code == "documents.inbound.notIndexed" || message.contains("notIndexed"))
        }
        return false
    }

    /// True when an external provider needs document-egress consent
    /// (`403`, `consent.ai.required`). The UI surfaces a consent CTA.
    nonisolated static func isConsentRequired(_ error: Error) -> Bool {
        if case let HLError.server(status, code, message) = error {
            return status == 403 &&
                (code == "consent.ai.required" || message.contains("consent.ai.required"))
        }
        return false
    }

    // MARK: - History (GET)

    /// `GET /api/documents/inbound/{id}/chat` — with `conversationId`, that thread's
    /// messages (oldest-first); without it, the document's thread list (newest
    /// first). A foreign / unknown id maps to 404 (never 403).
    func chatHistory(id: String, conversationId: String? = nil) async throws -> DocumentChatHistory {
        var query: [(String, String)] = []
        if let conversationId, !conversationId.isEmpty {
            query.append(("conversationId", conversationId))
        }
        let req: APIRequest<DocumentChatHistory> = .get("/api/documents/inbound/\(id)/chat", query: query)
        return try await api.send(req)
    }

    // MARK: - Stream (POST → SSE)

    /// `POST /api/documents/inbound/{id}/chat` — send one user turn and stream the
    /// grounded reply token-by-token. Yields ``DocumentChatStreamToken`` frames; an
    /// SSE `error` frame or a gate rejection throws a typed ``DocumentChatError``.
    nonisolated func chatStream(
        id: String,
        message: String,
        conversationId: String? = nil,
        locale: String? = nil
    ) -> AsyncThrowingStream<DocumentChatStreamToken, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = DocumentChatRequest(
                        message: message,
                        conversationId: conversationId,
                        locale: locale
                    )
                    let request = try APIRequest<Data>.documentChat(id: id, body: body)
                    let leased = try await requestWithExternalAIConsent(request)
                    let lines = try await api.streamLines(leased.request)
                    try await validateChatLeaseAfterAwait(leased.lease)

                    var reassembler = DocumentChatSSEReassembler()
                    var sawAnyFrame = false
                    var sawToken = false
                    var providerErrorCode: String?

                    func handle(_ payload: String) {
                        guard let frame = Self.decodeChatFrame(payload) else { return }
                        sawAnyFrame = true
                        switch frame.type {
                        case "token":
                            if let token = frame.token, !token.isEmpty {
                                sawToken = true
                                continuation.yield(.token(token))
                            }
                        case "done":
                            continuation.yield(.done(
                                conversationId: frame.conversationId,
                                messageId: frame.messageId
                            ))
                        case "error":
                            providerErrorCode = frame.code ?? frame.message ?? "documents.chat.failed"
                        default:
                            break // additive evolution — ignore unknown frame types
                        }
                    }

                    for try await line in lines {
                        try await validateChatLeaseAfterAwait(leased.lease)
                        if let payload = reassembler.feed(line) { handle(payload) }
                    }
                    try await validateChatLeaseAfterAwait(leased.lease)
                    if let payload = reassembler.flush() { handle(payload) }

                    if let providerErrorCode {
                        continuation.finish(throwing: Self.mapStreamErrorCode(providerErrorCode))
                    } else if !sawAnyFrame {
                        continuation.finish(throwing: DocumentChatError.decode("no SSE frames in body"))
                    } else if !sawToken {
                        continuation.finish(throwing: DocumentChatError.emptyReply)
                    } else {
                        continuation.finish()
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: Self.mapStreamOpenError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Error mapping

    /// Maps a pre-stream transport failure (the status line the server sent before
    /// any token) onto a typed ``DocumentChatError`` — keeping the gate outcomes
    /// (`notIndexed` / `consentRequired`) and the rate bucket honest.
    nonisolated static func mapStreamOpenError(_ error: Error) -> Error {
        if (error as? DocumentAIConsentError) == .consentRequired {
            return DocumentChatError.consentRequired
        }
        if isNotIndexed(error) { return DocumentChatError.notIndexed }
        if isConsentRequired(error) { return DocumentChatError.consentRequired }
        if case HLError.rateLimited = error { return DocumentChatError.limitReached }
        return error
    }

    /// Revalidates after each suspension point and before the resulting chunk can
    /// be observed. Cancelling this internal consumer task tears down
    /// `APIClient.streamLines` through its `onTermination` URLSession contract.
    private func validateChatLeaseAfterAwait(_ lease: DocumentAIConsentLease) async throws {
        do {
            try await validateExternalAIConsent(lease)
        } catch {
            withUnsafeCurrentTask { $0?.cancel() }
            throw error
        }
    }

    /// Maps an SSE `error`-frame code onto a typed ``DocumentChatError``. A
    /// budget / rate / limit code reads as ``DocumentChatError/limitReached`` (the
    /// calm "Limit erreicht" surface); anything else as `.provider`.
    nonisolated static func mapStreamErrorCode(_ code: String) -> DocumentChatError {
        let lowered = code.lowercased()
        if lowered.contains("budget") || lowered.contains("rate") || lowered.contains("limit") {
            return .limitReached
        }
        if code == "documents.inbound.notIndexed" { return .notIndexed }
        if code == "consent.ai.required" { return .consentRequired }
        return .provider(code)
    }

    /// Decode one reassembled SSE event payload into a frame. `nil` for an empty /
    /// undecodable body — the caller skips those (additive-tolerant).
    fileprivate nonisolated static func decodeChatFrame(_ payload: String) -> DocumentChatFrame? {
        let json = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DocumentChatFrame.self, from: data)
    }
}

/// One decoded SSE frame from the document-chat stream. `type` ∈
/// { `token`, `done`, `error` }; the other fields are per-type tails.
private struct DocumentChatFrame: Decodable {
    let type: String
    let token: String?
    let conversationId: String?
    let messageId: String?
    let code: String?
    let message: String?
}

/// Re-joins the SSE `data:` lines of one event before decode. Mirrors the Coach
/// transport's decode-driven reassembly: the app's streams (and the test stubs)
/// emit one COMPLETE `data:` JSON per line with no blank-line separator, so a new
/// `data:` line flushes the prior buffer the moment it already forms a decodable
/// event; a genuinely split frame keeps accumulating until whole. Blank lines
/// (the spec event terminator) and CRLF variants are tolerated.
private struct DocumentChatSSEReassembler {
    private var dataLines: [String] = []

    mutating func feed(_ rawLine: some StringProtocol) -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
        if line.isEmpty { return flush() }
        guard !line.hasPrefix(":") else { return nil } // SSE comment
        guard let colon = line.firstIndex(of: ":") else {
            if line == "data" { dataLines.append("") }
            return nil
        }
        guard line[line.startIndex ..< colon] == "data" else { return nil } // ignore event:/id:/retry:
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        var completed: String?
        if !dataLines.isEmpty, isDecodable(dataLines.joined(separator: "\n")) {
            completed = flush()
        }
        dataLines.append(value)
        return completed
    }

    mutating func flush() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return payload
    }

    private func isDecodable(_ candidate: String) -> Bool {
        DocumentsRepository.decodeChatFrame(candidate) != nil
    }
}

// MARK: - Request factory

extension APIRequest where Response == Data {
    /// Builds the `POST /api/documents/inbound/{id}/chat` SSE request. `Accept:
    /// text/event-stream` keeps a content-negotiating proxy on the frame format;
    /// `streaming: true` rides `APIClient`'s idle-reset streaming session (resets
    /// per received token). A first-turn create is idempotency-keyed; the stream is
    /// single-shot (`maxRetries: 0`) — a mid-stream hiccup surfaces for an explicit
    /// retry rather than a silent re-issue.
    static func documentChat(
        id: String,
        body: DocumentChatRequest,
        encoder: JSONEncoder = .hlDefault
    ) throws -> APIRequest<Data> {
        let data = try encoder.encode(body)
        return APIRequest(
            method: .post,
            path: "/api/documents/inbound/\(id)/chat",
            body: data,
            extraHeaders: ["Accept": "text/event-stream"],
            idempotencyKey: IdempotencyKey(),
            maxRetries: 0,
            streaming: true,
            allowsAuthenticationRecovery: false
        )
    }
}
