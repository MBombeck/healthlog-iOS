import Foundation

/// `{ storeWorkoutRoutes }`, the body and the answer of
/// `/api/auth/me/workout-routes` (server v1.44.0, `WorkoutRoutesResponse`).
public struct WorkoutRoutesSettingDTO: Codable, Sendable, Equatable {
    public let storeWorkoutRoutes: Bool

    public init(storeWorkoutRoutes: Bool) {
        self.storeWorkoutRoutes = storeWorkoutRoutes
    }
}

protocol WorkoutRoutesSettingServing: Sendable {
    func fetch() async throws -> WorkoutRoutesSettingDTO
    func update(storeWorkoutRoutes: Bool) async throws -> WorkoutRoutesSettingDTO
}

/// **1.5 ROUTES (#149) — the account's workout-route opt-in.**
///
/// - `GET` reads whether the server keeps GPS tracks (off by default).
/// - `PATCH` hard-sets it; idempotent and audit-logged server-side. Turning it
///   off stops new tracks; tracks already stored stay until their workout is
///   deleted (OpenAPI v1.47.0).
///
/// An actor route: `APIClient` never attaches an account selector to
/// `/api/auth`, so this is always the signed-in person's own setting.
public actor WorkoutRoutesSettingRepository: WorkoutRoutesSettingServing {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    static let path = "/api/auth/me/workout-routes"

    public func fetch() async throws -> WorkoutRoutesSettingDTO {
        let req: APIRequest<WorkoutRoutesSettingDTO> = .get(Self.path)
        return try await api.send(req)
    }

    public func update(storeWorkoutRoutes: Bool) async throws -> WorkoutRoutesSettingDTO {
        let req: APIRequest<WorkoutRoutesSettingDTO> = try .patch(
            Self.path,
            body: WorkoutRoutesSettingDTO(storeWorkoutRoutes: storeWorkoutRoutes)
        )
        return try await api.send(req)
    }
}

/// **The device side of the route opt-in, and the one gate every route read
/// and every route on the wire passes.**
///
/// Routes are location data. They leave the phone only when all of this holds:
/// the server is known to be v1.44.0 or newer (unknown means no), and this
/// person switched "Send routes" on in this app, which is also when the app
/// asked Apple Health for the route permission. The mark is per account and
/// set only after the server confirmed the switch; it goes the moment the
/// switch goes off here, and when a read of the server says off (turned off on
/// the web, or never on). Turning it on in the web alone never starts route
/// reads on this phone: the permission question belongs to a tap here.
enum WorkoutRouteOptIn {
    static let minimumServerVersion = "1.44.0"

    static func key(ownerUserID: String?) -> String {
        "hl.workoutRoutes.optIn." + HealthKitBackfillWindowStore.partitionToken(for: ownerUserID)
    }

    static func isOn(ownerUserID: String?, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(ownerUserID: ownerUserID))
    }

    static func set(_ on: Bool, ownerUserID: String?, defaults: UserDefaults = .standard) {
        if on {
            defaults.set(true, forKey: key(ownerUserID: ownerUserID))
        } else {
            defaults.removeObject(forKey: key(ownerUserID: ownerUserID))
        }
    }

    static func serverSupportsRoutes(defaults: UserDefaults = .standard) -> Bool {
        KnownServerVersion.isAtLeast(minimumServerVersion, defaults: defaults)
    }

    /// Whether a route of `ownerUserID` may be read and sent right now. An
    /// empty owner never may.
    static func allowsUpload(ownerUserID: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let owner = ownerUserID?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty else {
            return false
        }
        return serverSupportsRoutes(defaults: defaults) && isOn(ownerUserID: owner, defaults: defaults)
    }

    /// The wire boundary. Returns the batch unchanged when routes may go out
    /// (or none is in it), else the batch with every route removed and `true`.
    static func enforce(
        _ workouts: [WorkoutIngestDTO],
        allowed: Bool
    ) -> (workouts: [WorkoutIngestDTO], stripped: Bool) {
        guard !allowed, workouts.contains(where: { $0.route != nil }) else {
            return (workouts, false)
        }
        return (workouts.map { $0.route == nil ? $0 : $0.withRoute(nil) }, true)
    }
}
