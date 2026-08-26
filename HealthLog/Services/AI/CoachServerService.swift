import Foundation

/// **v0.7.1 W-COACH-FALLBACK** — server-backed Coach path for iPhones
/// without Apple Intelligence / an on-device Foundation Model.
///
/// The on-device `LocalLLMService` only serves iOS-26 + Apple-Intelligence
/// eligible hardware. On every other device the AskCoach sheet used to
/// show a kill-card (A-FEATURE-3). This service replaces that dead-end
/// with the same server Coach the web client already uses: the
/// `POST /api/insights/chat` SSE endpoint that walks the user's
/// server-configured AI provider chain.
///
/// **Why an actor wrapping `APIClient`?** The endpoint is server-side,
/// so the work belongs off the MainActor; the actor keeps the
/// reply-buffering + SSE-frame parsing isolated and `Sendable`. We route
/// through the existing `APIClientProtocol.download(_:)` primitive — the
/// route streams `data: <json>\n\n` frames and closes the body, so the
/// buffered `Data` `download` returns contains the full frame sequence.
/// We never touch `APIClient.swift`; the request is built from the
/// public `APIRequest` factories.
///
/// **Idempotency:** a first-turn POST (no `conversationId`) carries an
/// `Idempotency-Key` so a retried create doesn't double-open a
/// conversation. The store hands the `conversationId` back on follow-up
/// turns so the server appends to the same thread.
///
/// **Privacy / consent:** this service does NOT decide consent — the
/// caller (`CoachConversationStore`) gates on `AIConsentStore` BEFORE
/// invoking `respond(...)`. The server enforces its own
/// `requireAssistantSurface("coach")` feature-flag + per-user budget.
public actor CoachServerService {
    private let api: APIClientProtocol
    private let encoder: JSONEncoder

    public init(api: APIClientProtocol, encoder: JSONEncoder = .hlDefault) {
        self.api = api
        self.encoder = encoder
    }

    /// One assistant turn against the server Coach.
    ///
    /// - Parameters:
    ///   - message: the user's prompt (raw text — the server composes
    ///     the snapshot + system prompt itself; we do NOT enrich it
    ///     client-side, the server already has the user's data).
    ///   - conversationId: `nil` for a new conversation, otherwise the
    ///     id the server returned on a previous turn so the thread
    ///     continues.
    ///   - locale: `"de"` / `"en"` so the server renders refusal copy in
    ///     the right language.
    /// - Returns: the assistant reply text + the (new-or-existing)
    ///   conversation id so the caller can continue the thread.
    /// - Throws: ``CoachServerError`` for transport, decode, or
    ///   server-signalled provider failures.
    public func respond(
        message: String,
        conversationId: String?,
        locale: String,
        scope: CoachScopeWire? = nil,
        prefill: String? = nil,
        onToken: (@MainActor @Sendable (String) async -> Void)? = nil
    ) async throws -> Reply {
        let body = ChatRequestBody(
            conversationId: conversationId,
            message: message,
            locale: locale,
            scope: scope,
            prefill: prefill
        )
        // A first-turn create gets an Idempotency-Key (the server caches
        // the conversation create under it); follow-up turns reuse the
        // conversationId for dedup, so the key is only load-bearing on
        // the create path. We always supply one — harmless on follow-ups.
        let request = try APIRequest<Data>.coachChat(
            body: body,
            encoder: encoder
        )
        // **A360 H3 (v0156)** — progressive streaming. Consume the SSE body
        // line-by-line as bytes arrive (instead of buffering the whole body),
        // parsing each `token` frame the instant it lands and surfacing it through
        // `onToken` so the visible reply grows token-by-token like the on-device
        // arm. The idle-reset timeout + cancellation + provenance/usage/suggestion
        // frame handling are all preserved (the stream rides the same streaming
        // session as the buffered path; the same `FrameAccumulator` finalises the
        // turn). The buffered ``download``/``parseSSE`` path is kept for tests.
        let lines = try await api.streamLines(request)
        var acc = FrameAccumulator()
        var reassembler = SSEEventReassembler(isComplete: { Self.frame(fromEventPayload: $0) != nil })
        for try await line in lines {
            // BH-final-diff H5 — reassemble multi-`data:`-line events. The
            // transport splits on newlines; a single SSE event may span several
            // `data:` lines that must be re-joined before decode. Feed each line
            // and only decode when the reassembler emits a completed event (on a
            // blank-line terminator). A cancellation propagates out of the
            // for-await.
            guard let payload = reassembler.feed(line) else { continue }
            await Self.ingestPayload(payload, into: &acc, onToken: onToken)
        }
        // Flush a final event that arrived without a trailing blank line.
        if let payload = reassembler.flush() {
            await Self.ingestPayload(payload, into: &acc, onToken: onToken)
        }
        return try acc.finalize()
    }

    public struct Reply: Sendable, Equatable {
        public let text: String
        public let conversationId: String?
        /// Server id of the persisted assistant message (the `done` frame's
        /// `messageId`). Carried so the feedback route
        /// (`POST /api/insights/chat/messages/{id}/feedback`) can reference
        /// the reply. `nil` on refusal turns (the server persists no
        /// assistant message there) and on older server builds.
        public let messageId: String?
        /// v1.18.1 (§3) — the optional cadence suggestion the coach SSE stream
        /// may emit (one `suggestion` frame before `done`). `nil` when the turn
        /// carried no suggestion or on older server builds. Render-only — the
        /// closed cadence catalog + module-gating live server-side.
        public let suggestion: CoachReminderSuggestion?
        /// CO4 (v0154) — the provenance envelope the server emits as a dedicated
        /// `provenance` SSE frame (`metricSource`). Labels + windows + counts +
        /// load-bearing keyValues the coach drew on for this turn; render-only,
        /// surfaced as a collapsed "what I'm looking at" disclosure under the
        /// assistant bubble. `nil` when the turn emitted no provenance frame
        /// (older servers, refusal turns).
        public let provenance: CoachProvenance?
        /// CO5 (v0154) — per-turn token usage carried on the `done` frame
        /// (`done.usage`, server v1.18.9+). `nil` on older servers / refusal
        /// turns. Render-only — the quiet token footer paints `totalTokens` +
        /// `model`, never a client recompute.
        public let usage: CoachUsage?

        public init(
            text: String,
            conversationId: String?,
            messageId: String? = nil,
            suggestion: CoachReminderSuggestion? = nil,
            provenance: CoachProvenance? = nil,
            usage: CoachUsage? = nil
        ) {
            self.text = text
            self.conversationId = conversationId
            self.messageId = messageId
            self.suggestion = suggestion
            self.provenance = provenance
            self.usage = usage
        }
    }

    /// CO4 (v0154) — the provenance envelope the server attaches to an assistant
    /// turn (web `CoachProvenance`, `src/lib/ai/coach/types.ts`). Labels only —
    /// metric topics + time windows + per-metric sample counts. The optional
    /// `keyValues` carry the load-bearing numbers the coach surfaced (already
    /// grounded in the user's snapshot), rendered inside the collapsed disclosure.
    /// We decode ONLY what the disclosure renders; `suggestion` / `toolCalls`
    /// on the web type are handled / ignored elsewhere.
    ///
    /// Privacy: `keyValues` may reference the user's own data — they are
    /// render-only and MUST NOT be logged (the disclosure stays collapsed by
    /// default; never auto-expand raw values).
    public struct CoachProvenance: Sendable, Equatable, Decodable {
        /// Time windows the assistant drew on (`last7days` … `allTime`). Stable
        /// contract tokens translated client-side via `insights.coach.window.*`.
        public let windows: [String]
        /// Metric topics referenced (`bp`, `sleep`, …). Stable contract tokens
        /// translated client-side via `insights.coach.metric.*` (raw-token
        /// fallback when a key is missing, matching web).
        public let metrics: [String]
        /// Per-metric sample-count summary — opaque labels, no raw values. Absent
        /// when the snapshot was empty.
        public let counts: [String: Int]?
        /// Load-bearing numbers the coach drew on this turn. Absent on a
        /// qualitative turn or an empty snapshot.
        public let keyValues: [CoachKeyValue]?

        public init(
            windows: [String],
            metrics: [String],
            counts: [String: Int]? = nil,
            keyValues: [CoachKeyValue]? = nil
        ) {
            self.windows = windows
            self.metrics = metrics
            self.counts = counts
            self.keyValues = keyValues
        }

        /// Defensive decode — a missing `windows`/`metrics` reads as empty rather
        /// than throwing, so a partial provenance payload still renders the chips
        /// it does carry (never drops the whole turn over one absent key).
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            windows = try container.decodeIfPresent([String].self, forKey: .windows) ?? []
            metrics = try container.decodeIfPresent([String].self, forKey: .metrics) ?? []
            counts = try container.decodeIfPresent([String: Int].self, forKey: .counts)
            keyValues = try container.decodeIfPresent([CoachKeyValue].self, forKey: .keyValues)
        }

        private enum CodingKeys: String, CodingKey {
            case windows
            case metrics
            case counts
            case keyValues
        }

        /// `true` when there is nothing to disclose (no metrics AND no windows AND
        /// no keyValues) — the view skips the disclosure entirely, matching web.
        public var isEmpty: Bool {
            metrics.isEmpty && windows.isEmpty && (keyValues?.isEmpty ?? true)
        }
    }

    /// CO4 (v0154) — one entry inside the provenance evidence block (web
    /// `CoachKeyValue`). `label` + `value` are required; `unit` / `window` are
    /// optional tails. Render-only; never logged.
    public struct CoachKeyValue: Sendable, Equatable, Decodable, Identifiable {
        public let label: String
        public let value: String
        public let unit: String?
        public let window: String?

        /// Stable id for `ForEach` — the label+value pair is unique enough for a
        /// turn's 8-entry-capped block (the server hard-caps it).
        public var id: String {
            label + "|" + value
        }

        public init(label: String, value: String, unit: String? = nil, window: String? = nil) {
            self.label = label
            self.value = value
            self.unit = unit
            self.window = window
        }
    }

    /// CO5 (v0154) — per-turn token usage (web `CoachUsage`, server v1.18.9+).
    /// `totalTokens` is the headline count the quiet footer paints; `model` names
    /// the provider model. The prompt/completion split the server may also send
    /// is intentionally not decoded — the footer only shows the total.
    public struct CoachUsage: Sendable, Equatable, Decodable {
        public let totalTokens: Int?
        public let model: String?

        public init(totalTokens: Int?, model: String? = nil) {
            self.totalTokens = totalTokens
            self.model = model
        }

        private enum CodingKeys: String, CodingKey {
            case totalTokens
            case model
        }
    }

    /// v1.18.1 (§3) — a coach-proposed measurement cadence (e.g. the ESH/AHA
    /// 7-2-2 home-BP protocol). The client renders an actionable card and sends
    /// back ONLY the `cadenceId` + an action — it cannot widen a cadence.
    /// `label` is an i18n key the client resolves (with a generic fallback for an
    /// unknown key, so a future cadence the app has no string for still renders).
    public struct CoachReminderSuggestion: Sendable, Equatable, Decodable, Identifiable {
        public let cadenceId: String
        public let measurementType: String
        public let label: String

        public var id: String {
            cadenceId
        }

        public init(cadenceId: String, measurementType: String, label: String) {
            self.cadenceId = cadenceId
            self.measurementType = measurementType
            self.label = label
        }
    }

    /// The one-tap action on a cadence suggestion. `accept` creates a
    /// `MeasurementReminder` (origin COACH) server-side; `dismiss` hides this one;
    /// `stop` tells the coach to stop proposing this cadence.
    public enum SuggestionAction: String, Sendable, Equatable {
        case accept
        case dismiss
        case stop
    }

    /// v1.18.1 (§3) — act on a coach cadence suggestion.
    /// `POST /api/coach/reminder-suggestions { cadenceId, action }`. The client
    /// sends only the id + action (never cadence parameters). On `accept` the
    /// server creates the reminder; it then surfaces in the native reminders list
    /// (Settings → Notifications → Manage reminders).
    public func actOnSuggestion(cadenceId: String, action: SuggestionAction) async throws {
        let request: APIRequest<CoachSuggestionActionAck> = try .post(
            "/api/coach/reminder-suggestions",
            body: CoachSuggestionActionBody(cadenceId: cadenceId, action: action.rawValue),
            encoder: encoder
        )
        _ = try await api.send(request)
    }

    // MARK: - Proactive nudge (server v1.18.6 CCH-03)

    /// Server-authoritative unread signal for the Coach surfaces.
    /// `GET /api/insights/coach/nudge-status`. `unread` is `true` when the
    /// caller's newest Coach assistant message (a proactive nudge or any reply)
    /// is newer than the last `seen` stamp; `nudgedAt` carries that newest
    /// assistant-message timestamp (`nil` when none exists) so a client can key a
    /// local seen-mirror on a stable value. Coach-gated server-side
    /// (`requireAssistantSurface("coach")` → 403 maps to
    /// ``HLError/assistantDisabled(_:)``); the caller never invokes this when the
    /// `coach` module is off / offline.
    public func nudgeStatus() async throws -> CoachNudgeStatus {
        let request: APIRequest<CoachNudgeStatus> = .get("/api/insights/coach/nudge-status")
        return try await api.send(request)
    }

    /// Mark the Coach as opened — `POST /api/insights/coach/seen`. Stamps
    /// `coachLastSeenAt = now()` server-side so a subsequent ``nudgeStatus()``
    /// reports no assistant message newer than the stamp and the unread dot
    /// drops. Server-minted timestamp (no request body — a client can never
    /// backdate the stamp), so the cleared state follows the caller across web +
    /// iOS. The echoed `seenAt` is not read (the next refresh reconciles the
    /// dot); a tolerant empty body keeps any ack shape valid.
    public func markCoachSeen() async throws {
        let request: APIRequest<CoachSeenAck> = try .post(
            "/api/insights/coach/seen",
            // No payload — the server mints the timestamp. An empty object keeps
            // the POST body well-formed for the envelope decode path.
            body: CoachSeenBody(),
            maxRetries: 0
        )
        _ = try await api.send(request)
    }

    // MARK: - Message feedback (server v1.4.23 H7)

    /// One-shot helpful/unhelpful rating for a server-persisted assistant
    /// message. `POST /api/insights/chat/messages/{id}/feedback`, body
    /// `{ rating: "helpful" | "unhelpful" }`. The server dedupes per
    /// `(user, message)` — a second submission returns **409**
    /// (`already_rated`); there is no un-rate, so the UI locks the row
    /// after a successful submit. Coach-gated like the chat route
    /// (`requireAssistantSurface("coach")` → 403 maps to
    /// ``HLError/assistantDisabled(_:)`` in `APIClient`).
    public func submitFeedback(messageID: String, rating: CoachFeedbackRating) async throws {
        let request: APIRequest<CoachFeedbackAck> = try .post(
            "/api/insights/chat/messages/\(messageID)/feedback",
            body: CoachFeedbackBody(rating: rating.rawValue),
            encoder: encoder
        )
        _ = try await api.send(request)
    }

    // MARK: - SSE parsing

    /// Parses the buffered SSE body the Coach endpoint returns.
    ///
    /// Frames are `data: <json>\n\n`. We accumulate `token` frames into
    /// the reply, capture the `done` frame's `conversationId`, and treat
    /// an `error` frame as a thrown ``CoachServerError/provider(_:)`` so
    /// the UI can surface a retry instead of a half-empty bubble.
    ///
    /// `nonisolated static` — pure function of its `Data` input, so the
    /// store's test can exercise it without standing up the actor.
    nonisolated static func parseSSE(_ data: Data) throws -> Reply {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw CoachServerError.decode("non-UTF8 SSE body")
        }
        var acc = FrameAccumulator()
        var reassembler = SSEEventReassembler(isComplete: { Self.frame(fromEventPayload: $0) != nil })
        // BH-final-diff H5 — events are separated by a blank line; each event's
        // payload may span MULTIPLE `data:` lines that must be re-joined with
        // `\n` before decode. Split on newlines (keeping empties so the blank-line
        // terminators reach the reassembler) and let the reassembler emit one
        // joined payload per event. Robust against single vs double newline
        // framing from intermediary proxies.
        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let payload = reassembler.feed(line) else { continue }
            if let frame = Self.frame(fromEventPayload: payload) { acc.ingest(frame) }
        }
        // Flush a trailing event with no terminating blank line.
        if let payload = reassembler.flush(), let frame = Self.frame(fromEventPayload: payload) {
            acc.ingest(frame)
        }
        return try acc.finalize()
    }

    /// Accumulates decoded SSE frames into the final ``Reply``. Pulling the
    /// per-frame dispatch + the terminal validation out of ``parseSSE`` keeps
    /// that function's cyclomatic complexity low as the frame taxonomy grows
    /// (token / done / error / suggestion / provenance + the validation arms).
    private struct FrameAccumulator {
        private var reply = ""
        private var conversationId: String?
        private var messageId: String?
        private var suggestion: CoachReminderSuggestion?
        private var provenance: CoachProvenance?
        private var usage: CoachUsage?
        private var sawAnyFrame = false
        private var providerErrorCode: String?

        mutating func ingest(_ frame: StreamFrame) {
            sawAnyFrame = true
            switch frame.type {
            case "token":
                if let token = frame.token { reply += token }
            case "done":
                conversationId = frame.conversationId
                messageId = frame.messageId
                // CO5 (v0154) — the `done` frame carries the per-turn token usage
                // (server v1.18.9+). Keep any decoded value; older servers omit it.
                usage = frame.usage ?? usage
            case "error":
                providerErrorCode = frame.code ?? frame.message ?? "coach.provider.unavailable"
            case "suggestion":
                // v1.18.1 (§3) — additive cadence suggestion frame. Keep the last
                // valid one; a malformed payload decodes to nil and is ignored
                // (the `?? suggestion` keeps any earlier valid value).
                suggestion = frame.suggestion ?? suggestion
            case "provenance":
                // CO4 (v0154) — the dedicated provenance frame (`metricSource`).
                // Keep the last valid one; a malformed payload decodes to nil and
                // is ignored (the `?? provenance` keeps any earlier valid value).
                provenance = frame.metricSource ?? provenance
            default:
                break // additive evolution — ignore unknown frame types
            }
        }

        func finalize() throws -> Reply {
            if let providerErrorCode {
                throw CoachServerError.provider(providerErrorCode)
            }
            guard sawAnyFrame else {
                throw CoachServerError.decode("no SSE frames in body")
            }
            let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                throw CoachServerError.emptyReply
            }
            return Reply(
                text: cleaned,
                conversationId: conversationId,
                messageId: messageId,
                suggestion: suggestion,
                provenance: provenance,
                usage: usage
            )
        }
    }

    /// Decode a reassembled event payload, surface a live token through
    /// `onToken`, and fold it into the accumulator. Shared by the streamed path
    /// (mid-stream events + the end-of-stream flush) so both go through the same
    /// token/ingest logic.
    private nonisolated static func ingestPayload(
        _ payload: String,
        into acc: inout FrameAccumulator,
        onToken: (@MainActor @Sendable (String) async -> Void)?
    ) async {
        guard let frame = frame(fromEventPayload: payload) else { return }
        if frame.type == "token", let token = frame.token, !token.isEmpty {
            await onToken?(token)
        }
        acc.ingest(frame)
    }

    /// Decode one already-reassembled SSE event payload (the joined `data:`
    /// values for a single event) into a ``StreamFrame``. Returns `nil` for an
    /// empty payload or an undecodable body — the caller skips those.
    private nonisolated static func frame(fromEventPayload payload: String) -> StreamFrame? {
        let json = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !json.isEmpty, let frameData = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StreamFrame.self, from: frameData)
    }

    /// **BH-final-diff H5 — SSE multi-`data:`-line reassembly.** A single SSE
    /// event may legitimately span MULTIPLE `data:` lines that must be re-joined
    /// with `\n` before decoding; the previous per-line decoder `try?`-decoded
    /// each physical line, so a split frame silently dropped its tokens.
    ///
    /// But the app's own streams (and the test stubs) emit one COMPLETE `data:`
    /// JSON object per line with NO blank-line separator between events. A naive
    /// "accumulate until blank line" reassembler would merge those back-to-back
    /// frames into one undecodable blob. So the dispatch is **decode-driven**:
    ///
    ///   - Buffered `data:` lines are joined with `\n` and emitted when (a) a
    ///     blank line (the spec event terminator) is seen, or (b) a NEW `data:`
    ///     line arrives while the already-buffered payload ALONE forms a complete
    ///     (decodable) event — proving the previous event ended without a blank
    ///     line. A genuinely split frame's partial buffer does NOT decode, so it
    ///     keeps accumulating until the joined payload is whole.
    ///
    /// Tolerant of proxy newline variants: a line is fed already split on
    /// `\n`/`\r\n` boundaries; a lone `\r` left on a line is stripped. Non-`data:`
    /// SSE fields (`event:`, `id:`, `retry:`, comments `:`) are ignored.
    struct SSEEventReassembler {
        private var dataLines: [String] = []
        /// Predicate that returns `true` when the joined buffer already forms a
        /// complete (decodable) event — drives the no-blank-line dispatch.
        private let isComplete: (String) -> Bool

        /// - Parameter isComplete: returns `true` when the candidate joined
        ///   payload decodes to a full event. Defaults to "non-empty" for callers
        ///   that only need blank-line framing.
        init(isComplete: @escaping (String) -> Bool = { !$0.isEmpty }) {
            self.isComplete = isComplete
        }

        /// Feed one physical SSE line. Returns a completed event payload when the
        /// line terminates one (a blank line, OR a new `data:` line that follows
        /// an already-complete buffer); otherwise `nil`.
        mutating func feed(_ rawLine: some StringProtocol) -> String? {
            // Strip a trailing lone CR (CRLF transports where only `\n` split).
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty {
                return flush()
            }
            // SSE comment line (starts with ':') — ignore.
            guard !line.hasPrefix(":") else { return nil }
            guard let colon = line.firstIndex(of: ":") else {
                // A field name with no value (e.g. a bare "data") — per spec the
                // value is empty; only meaningful for `data`.
                if line == "data" { dataLines.append("") }
                return nil
            }
            let field = line[line.startIndex ..< colon]
            guard field == "data" else { return nil } // ignore event:/id:/retry:
            var value = String(line[line.index(after: colon)...])
            // Per spec, a single leading space after the colon is stripped.
            if value.hasPrefix(" ") { value.removeFirst() }
            // Decode-driven dispatch: if the buffer ALREADY forms a complete
            // event, this new `data:` line begins the NEXT event — emit the prior
            // one first (no blank-line separator), then start fresh.
            var completed: String?
            if !dataLines.isEmpty, isComplete(dataLines.joined(separator: "\n")) {
                completed = flush()
            }
            dataLines.append(value)
            return completed
        }

        /// Emit any buffered event payload (joined with `\n`) and reset. Returns
        /// `nil` when nothing is buffered. Call at end-of-stream to flush a final
        /// event that was not newline-terminated.
        mutating func flush() -> String? {
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            return payload
        }
    }

    private struct StreamFrame: Decodable {
        let type: String
        let token: String?
        let conversationId: String?
        let messageId: String?
        let code: String?
        let message: String?
        /// v1.18.1 (§3) — present only on a `suggestion` frame.
        let suggestion: CoachReminderSuggestion?
        /// CO4 (v0154) — present only on a `provenance` frame (the server's
        /// `metricSource` key).
        let metricSource: CoachProvenance?
        /// CO5 (v0154) — present only on the `done` frame (server v1.18.9+).
        let usage: CoachUsage?
    }
}

/// Request body for `POST /api/coach/reminder-suggestions` (v1.18.1 §3).
struct CoachSuggestionActionBody: Encodable {
    let cadenceId: String
    let action: String
}

/// `2xx { data: ... }` acknowledgement for a suggestion action. The body is not
/// read (accept creates the reminder server-side; the reminders list reflects
/// it) — a tolerant empty decodable so any ack shape succeeds.
struct CoachSuggestionActionAck: Decodable {
    init() {}
    init(from _: Decoder) throws {}
}

/// **v1.18.6 (CCH-03)** — server-authoritative unread signal for the Coach
/// surfaces. Decoded from the unwrapped `data` of
/// `GET /api/insights/coach/nudge-status` (the `APIClient` strips the
/// `{ data, error }` envelope). `unread` drives the discreet dot on the Coach
/// FAB + More row; `nudgedAt` is the newest Coach assistant-message timestamp
/// (`nil` when none exists). Defensive decode: a missing `nudgedAt` reads as
/// `nil`, a missing `unread` reads as `false` (fail-quiet — never fabricate an
/// unread state from a partial payload).
public struct CoachNudgeStatus: Decodable, Sendable, Equatable {
    /// Timestamp of the newest Coach assistant message; `nil` when none exists.
    public let nudgedAt: Date?
    /// `true` when that message is newer than the last time the caller opened the
    /// Coach.
    public let unread: Bool

    public init(nudgedAt: Date?, unread: Bool) {
        self.nudgedAt = nudgedAt
        self.unread = unread
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nudgedAt = try container.decodeIfPresent(Date.self, forKey: .nudgedAt)
        // Fail-quiet: a server that omits `unread` (shouldn't per contract) reads
        // as "nothing waiting" rather than throwing or inventing an unread dot.
        unread = try container.decodeIfPresent(Bool.self, forKey: .unread) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case nudgedAt
        case unread
    }
}

/// Empty request body for `POST /api/insights/coach/seen` — the server mints the
/// timestamp, so the client sends `{}`.
private struct CoachSeenBody: Encodable {}

/// `200 { data: { seenAt } }` acknowledgement for the seen stamp. `seenAt` is
/// not read (the next ``CoachServerService/nudgeStatus()`` reconciles the dot) —
/// a tolerant empty decodable so any ack shape succeeds.
struct CoachSeenAck: Decodable {
    init() {}
    init(from _: Decoder) throws {}
}

/// User rating for one assistant reply. Raw values are the server's
/// `coachMessageFeedbackSchema` enum (`"helpful" | "unhelpful"`).
public enum CoachFeedbackRating: String, Sendable, Equatable {
    case helpful
    case unhelpful
}

/// Request body for the feedback route. The optional `reason` field the
/// server accepts is deliberately not surfaced — the iOS affordance is a
/// one-tap thumb, not a form.
struct CoachFeedbackBody: Encodable {
    let rating: String
}

/// `201 { data: { id, createdAt } }` acknowledgement. Only `id` is read;
/// `createdAt` is ignored (tolerant decode).
struct CoachFeedbackAck: Decodable {
    let id: String
}

/// Error surface for ``CoachServerService``.
public enum CoachServerError: Error, Sendable, Equatable {
    /// SSE body could not be parsed (non-UTF8, no frames, malformed).
    case decode(String)
    /// The server emitted an `error` frame — provider chain failed,
    /// rate-limited, or empty. Associated value is the server error code
    /// (e.g. `coach.provider.none`, `coach.provider.rate_limited`).
    case provider(String)
    /// The stream closed with no usable assistant text.
    case emptyReply
}

extension APIRequest where Response == Data {
    /// Builds the `POST /api/insights/chat` SSE request. `Accept:
    /// text/event-stream` so any content-negotiating proxy keeps the
    /// frame format; the `download(_:)` primitive buffers the streamed
    /// body and hands back the full `Data`.
    static func coachChat(
        body: ChatRequestBody,
        encoder: JSONEncoder
    ) throws -> APIRequest<Data> {
        let data = try encoder.encode(body)
        return APIRequest(
            method: .post,
            path: "/api/insights/chat",
            body: data,
            extraHeaders: ["Accept": "text/event-stream"],
            // A failed first-turn create is safe to retry under the same
            // key (server caches the conversation create). The SSE route
            // skips idempotency caching server-side, but the key still
            // travels so a future server change can dedup the create.
            idempotencyKey: IdempotencyKey(),
            // SSE is a single long response — don't hammer it with the
            // default 3-retry backoff loop on a transient mid-stream
            // hiccup; one shot, surface the error to the UI for an
            // explicit retry.
            maxRetries: 0,
            // W-COACH-SSE — ride `APIClient`'s dedicated streaming session
            // (idle-reset request timeout that resets on every received SSE
            // token + generous overall ceiling) instead of the patient
            // session's 20 s/60 s wall, which prematurely cut off a slow LLM
            // turn. A genuine stall still ends cleanly via the inactivity
            // timeout; reconnect/cancel behaviour is unchanged (one shot,
            // surfaced to the UI for an explicit retry).
            streaming: true
        )
    }
}
