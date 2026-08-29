import Foundation

/// Thin projection of the `GET /api/auth/me` payload — the setup-completion
/// evidence and nothing else. Decoupled from `UserProfile` so an unrelated
/// `/me` schema change can't break the read, mirroring `AuthMeAvatar` /
/// `AuthMeDisclaimer` / `AuthMeModules`.
///
/// **25-03 (GH #1) — three evidence classes, not one flag.** The tour marker
/// (`onboardingTourCompleted`) is stamped by `POST /api/onboarding/tour`:
/// this app's setup wizard on finish, and the web's coachmark tour — but
/// **not** the web setup wizard, whose own completion is a different column
/// (`onboardingCompletedAt`, set on its step 4). A profile created in the
/// web UI therefore carries a `false` tour marker over a fully-set-up
/// account, which is exactly the first community report. The same `/me` row
/// already serves the wizard's record and the account substance itself
/// (`heightCm`, `dateOfBirth`, `gender`), so this projection reads all
/// three; the classification into the four-state routing vocabulary stays in
/// `OnboardingTourStore` (target boundary — see the repository docblock).
///
/// **Decode-tolerant in every direction:** a server that omits the marker
/// (prod ≤ v1.18.5) yields `nil`; absent or `null` evidence keys read
/// `false` — evidence can only ever be *found*, never invented from a hole
/// in the payload.
public struct AuthMeOnboarding: Decodable, Sendable, Equatable {
    /// Server-owned coarse tour-completion flag. `nil` when the server omits
    /// the field (older builds); `false`/`true` when present.
    public let onboardingTourCompleted: Bool?

    /// The web setup wizard's own completion record — `onboardingCompletedAt`
    /// non-null. Presence only: the timestamp's value carries no routing
    /// meaning, so none is decoded.
    public let hasSetupCompletionRecord: Bool

    /// Account substance the setup flow's baseline-profile step would create:
    /// any of `dateOfBirth` / `heightCm` non-null, or a non-empty `gender`.
    /// The server folds `""` to `null` for `gender` on write; the decode
    /// refuses the empty string anyway rather than relying on that.
    public let hasProfileSubstance: Bool

    public init(
        onboardingTourCompleted: Bool?,
        hasSetupCompletionRecord: Bool = false,
        hasProfileSubstance: Bool = false
    ) {
        self.onboardingTourCompleted = onboardingTourCompleted
        self.hasSetupCompletionRecord = hasSetupCompletionRecord
        self.hasProfileSubstance = hasProfileSubstance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        onboardingTourCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingTourCompleted)
        hasSetupCompletionRecord = Self.presentAndNotNull(container, .onboardingCompletedAt)
        // `decode` (not `decodeIfPresent`) so an absent key, a `null`, and a
        // non-string representation all collapse to `nil` through one `try?`.
        let gender = try? container.decode(String.self, forKey: .gender)
        hasProfileSubstance = Self.presentAndNotNull(container, .dateOfBirth)
            || Self.presentAndNotNull(container, .heightCm)
            || gender?.isEmpty == false
    }

    /// Presence without a type commitment: the key exists and its value is
    /// not `null`. Deliberately does not decode the value — `dateOfBirth` is
    /// a date string and `heightCm` a number on today's wire, and a future
    /// representation change must degrade to "no evidence", never to a throw.
    private static func presentAndNotNull(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Bool {
        guard container.contains(key) else { return false }
        return (try? container.decodeNil(forKey: key)) == false
    }

    private enum CodingKeys: String, CodingKey {
        case onboardingTourCompleted
        case onboardingCompletedAt
        case dateOfBirth
        case gender
        case heightCm
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

    /// Read the current server-owned setup-completion evidence from
    /// `GET /api/auth/me` — the tour marker, the web wizard's own completion
    /// record, and whether the account carries profile substance
    /// (25-03, GH #1).
    ///
    /// A thrown error means the lookup never resolved at all — not a `false`,
    /// and collapsing the two is how a timeout became "this user has not
    /// finished setup" and replayed a wizard they had finished on another
    /// device (or on the web).
    ///
    /// The classification into the four-state Wave-1 vocabulary lives in
    /// ``OnboardingTourStore/classifySetupCompletion(_:)`` rather than here,
    /// and that is a target boundary rather than a preference: this file also
    /// compiles into the `HealthLogWidgets` app extension, whose source
    /// allowlist deliberately carries `Repositories/` without `Stores/`. A
    /// repository that named a Stores-layer type would drag the whole app
    /// layer across that boundary — the failure the allowlist exists to make
    /// loud.
    public func fetchSetupState() async throws -> AuthMeOnboarding {
        let req: APIRequest<AuthMeOnboarding> = .get("/api/auth/me")
        return try await api.send(req)
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
