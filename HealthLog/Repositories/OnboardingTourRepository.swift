import Foundation

/// Thin projection of the `GET /api/auth/me` payload — only the onboarding
/// tour-completion flag (`onboardingTourCompleted`, server v1.18.6). Decoupled
/// from `UserProfile` so an unrelated `/me` schema change can't break the read,
/// mirroring `AuthMeAvatar` / `AuthMeDisclaimer` / `AuthMeModules`.
///
/// **Decode-tolerant:** a server that omits the key (prod ≤ v1.18.5) yields
/// `nil` — treated downstream as "tour not yet completed", so the resume gate
/// degrades to the current local-flag behaviour without crashing.
public struct AuthMeOnboarding: Decodable, Sendable, Equatable {
    /// Server-owned coarse completion flag. `nil` when the server omits the
    /// field (older builds); `false`/`true` when present.
    public let onboardingTourCompleted: Bool?

    public init(onboardingTourCompleted: Bool?) {
        self.onboardingTourCompleted = onboardingTourCompleted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        onboardingTourCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingTourCompleted)
    }

    private enum CodingKeys: String, CodingKey {
        case onboardingTourCompleted
    }
}

/// Resumable module-tour progress point (OpenAPI `TourProgress`). `lastStopId`
/// seeds the resume index; `status` is the running / terminal state. iOS posts
/// this as a mid-tour checkpoint so a reinstall resumes at the right module
/// rather than restarting, and reads it back to suppress already-completed
/// stops. The string ids are opaque module identifiers shared with the web
/// tour — iOS never interprets them, it only round-trips them.
public struct TourProgress: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case inProgress = "in_progress"
        case completed
        case skipped
    }

    public let lastStopId: String?
    public let completedStopIds: [String]
    public let status: Status
    public let updatedAt: Date

    public init(
        lastStopId: String?,
        completedStopIds: [String] = [],
        status: Status,
        updatedAt: Date = .now
    ) {
        self.lastStopId = lastStopId
        self.completedStopIds = completedStopIds
        self.status = status
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastStopId = try c.decodeIfPresent(String.self, forKey: .lastStopId)
        completedStopIds = try c.decodeIfPresent([String].self, forKey: .completedStopIds) ?? []
        status = try c.decode(Status.self, forKey: .status)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case lastStopId, completedStopIds, status, updatedAt
    }
}

/// `POST /api/onboarding/tour` body (OpenAPI `TourUpdateRequest`). Provide
/// `completed` and/or `progress`:
/// - a mid-tour `progress` checkpoint (resume point),
/// - a terminal `completed: true` with `outcome` when the tour ends,
/// - a `completed: false` replay reset that also clears the stored resume point.
public struct TourUpdateBody: Encodable, Sendable, Equatable {
    public enum Outcome: String, Encodable, Sendable {
        case completed
        case skipped
    }

    public let completed: Bool?
    public let outcome: Outcome?
    public let progress: TourProgress?

    public init(completed: Bool? = nil, outcome: Outcome? = nil, progress: TourProgress? = nil) {
        self.completed = completed
        self.outcome = outcome
        self.progress = progress
    }

    private enum CodingKeys: String, CodingKey {
        case completed, outcome, progress
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(completed, forKey: .completed)
        try c.encodeIfPresent(outcome, forKey: .outcome)
        try c.encodeIfPresent(progress, forKey: .progress)
    }
}

/// `POST /api/onboarding/tour` response payload (OpenAPI `TourUpdateResponse`,
/// unwrapped from the `{ data, error, meta }` envelope by `APIClient.send`).
/// The persisted completion flag and resume point after the write.
public struct TourUpdateResponse: Decodable, Sendable, Equatable {
    public let onboardingTourCompleted: Bool
    public let progress: TourProgress?

    public init(onboardingTourCompleted: Bool, progress: TourProgress?) {
        self.onboardingTourCompleted = onboardingTourCompleted
        self.progress = progress
    }
}

/// Server-owned onboarding-tour progress (#32, server v1.18.6). Wraps the read +
/// the write:
///
/// - `GET  /api/auth/me`        — current `onboardingTourCompleted` (read).
/// - `POST /api/onboarding/tour` — `{ completed?, outcome?, progress? }` (write).
///
/// **Server-first / cross-device.** The completion flag + resume point live on
/// the user row, so progress survives reinstall, syncs across devices, and is
/// shared with the web onboarding tour. iOS keeps only a local *cache* of the
/// completion flag (`OnboardingTourStore`) for offline launches and reconciles
/// to the server when reachable; the server is authoritative.
///
/// **Disposition (#32).** iOS does NOT (yet) ship an in-app guided coachmark
/// tour — the b198 step flow (`OnboardingFlow`) is a one-shot permission/setup
/// wizard, not a replayable module tour. This repo is the durable seam: it
/// stamps `completed` when the iOS setup wizard finishes (so a reinstall / a
/// second device does not re-run it, and the web tour state is shared), and the
/// `setProgress` / `reset` calls are ready for a future replayable tour without
/// any further wiring.
///
/// **Privacy.** No health-related payloads cross this route (opaque stop ids +
/// a bool); nothing is logged here — failures surface to the caller, which
/// fails soft.
public actor OnboardingTourRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Read the current server-owned completion flag from `GET /api/auth/me`.
    ///
    /// Three outcomes, and **two of them are not answers**: `nil` means the
    /// deployment carries no such field (prod ≤ v1.18.5), and a thrown error
    /// means the lookup never resolved at all. Neither is a `false`, and
    /// collapsing them into one is how a timeout became "this user has not
    /// finished setup" and replayed a wizard they had finished on another
    /// device.
    ///
    /// The classification into the four-state Wave-1 vocabulary lives in
    /// ``OnboardingTourStore/resolveCompletion()`` rather than here, and that is
    /// a target boundary rather than a preference: this file also compiles into
    /// the `HealthLogWidgets` app extension, whose source allowlist deliberately
    /// carries `Repositories/` without `Stores/`. A repository that named a
    /// Stores-layer type would drag the whole app layer across that boundary —
    /// the failure the allowlist exists to make loud.
    public func fetchCompleted() async throws -> Bool? {
        let req: APIRequest<AuthMeOnboarding> = .get("/api/auth/me")
        return try await api.send(req).onboardingTourCompleted
    }

    /// Stamp the coarse completion flag. Idempotent server-side. `outcome`
    /// distinguishes reaching the end (`.completed`) from a skip (`.skipped`).
    @discardableResult
    public func markCompleted(outcome: TourUpdateBody.Outcome = .completed) async throws -> TourUpdateResponse {
        let body = TourUpdateBody(completed: true, outcome: outcome)
        let req: APIRequest<TourUpdateResponse> = try .post("/api/onboarding/tour", body: body)
        return try await api.send(req)
    }

    /// Post a mid-tour resume checkpoint (the per-stop progress write). Ready
    /// for a future replayable iOS tour; unused by the one-shot setup wizard.
    @discardableResult
    public func setProgress(_ progress: TourProgress) async throws -> TourUpdateResponse {
        let body = TourUpdateBody(progress: progress)
        let req: APIRequest<TourUpdateResponse> = try .post("/api/onboarding/tour", body: body)
        return try await api.send(req)
    }

    /// Replay reset — `completed: false` clears the stored resume point so the
    /// tour can run again. Ready for a future "replay the intro" affordance.
    @discardableResult
    public func reset() async throws -> TourUpdateResponse {
        let body = TourUpdateBody(completed: false)
        let req: APIRequest<TourUpdateResponse> = try .post("/api/onboarding/tour", body: body)
        return try await api.send(req)
    }
}
