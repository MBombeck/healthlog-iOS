import Foundation

/// **W-COACH-SSE** (audit AUDIT-RELIABILITY-robustness.md H6) — the timeout
/// policy for the server-Coach SSE stream (`POST /api/insights/chat`), kept as an
/// inspectable value so the streaming session's contract is testable without
/// standing up a live socket, and so the coach SSE turn no longer rides the
/// generic patient timeouts (20 s request / 60 s resource) that prematurely cut
/// off a slow LLM turn.
///
/// URLSession exposes two timeout knobs and they mean very different things for a
/// streaming connection:
///
/// - **`timeoutIntervalForRequest`** is an *inactivity* timeout: it fires only
///   when the request makes no progress for the whole interval, and URLSession
///   **resets it every time it receives a chunk of the response body**. For an
///   SSE stream that keeps emitting `data:` frames, the timer keeps resetting, so
///   a long, actively-streaming reply never trips it. We set it generously
///   (``inactivityTimeout``) so even a slow LLM turn with a long pause *between*
///   tokens survives — only a genuine stall (no token for the full window) ends
///   the request, and it ends cleanly as `.timedOut`
///   (→ ``HLError/network(_:)`` `.timeout`), not an infinite hang.
/// - **`timeoutIntervalForResource`** is the overall *wall-clock* ceiling for the
///   whole transfer and does **not** reset on activity. The generic patient
///   session pins this at 60 s — which silently truncates any valid coach turn
///   that runs longer. We raise it to ``overallCeiling`` so a long-but-valid
///   stream completes, while a truly runaway stream still has a hard backstop.
public struct CoachStreamTimeoutPolicy: Sendable, Equatable {
    /// `timeoutIntervalForRequest` — the per-chunk *inactivity* window. Resets on
    /// every received SSE frame; only a full-window gap with no token ends the
    /// request. Generous so a slow generation pause between tokens survives.
    public let inactivityTimeout: TimeInterval
    /// `timeoutIntervalForResource` — the overall wall-clock ceiling. Does not
    /// reset on activity; the hard backstop for a runaway stream.
    public let overallCeiling: TimeInterval

    public init(inactivityTimeout: TimeInterval, overallCeiling: TimeInterval) {
        self.inactivityTimeout = inactivityTimeout
        self.overallCeiling = overallCeiling
    }

    /// The coach SSE policy. 120 s inactivity (resets per token — survives a slow
    /// LLM turn, ends a true stall cleanly) + 600 s (10 min) overall ceiling
    /// (a long valid stream isn't capped at 60 s; a runaway stream still ends).
    /// Both are far above the generic 20 s/60 s patient policy — that's the whole
    /// point: the patient policy kills a still-streaming reply.
    public static let coachStream = CoachStreamTimeoutPolicy(
        inactivityTimeout: 120,
        overallCeiling: 600
    )

    /// The generic patient policy (20 s request / 60 s resource) the non-streaming
    /// API paths use. Exposed so a test can assert the coach policy is strictly
    /// more generous than the wall the patient session would impose on a stream.
    public static let patient = CoachStreamTimeoutPolicy(
        inactivityTimeout: 20,
        overallCeiling: 60
    )
}
