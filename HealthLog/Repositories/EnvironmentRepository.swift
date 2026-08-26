import Foundation

/// Actor repository for the environmental-context module overview (Build 7 Item
/// 7.7; server `GET /api/environment`, module `environment`).
///
/// **Read-only, network-direct (no SWR cache).** Same posture as
/// ``NutrientReadRepository`` / ``IllnessRepository``: the overview is a small,
/// freshness-sensitive snapshot (home + travel + observation-coverage +
/// attribution) and the store holds it in memory. There is no write path here —
/// setting the home / travel overrides is a settings concern the app does not yet
/// surface; this half is purely the display read.
///
/// **Module gate (default-ON).** The `environment` module is default-on, but a
/// user can switch it off; a disabled account 403s `module.disabled`, which
/// ``APIClient`` types into ``HLError/moduleDisabled(_:)``. The store maps that to
/// a "sinnvoll leer" disabled hint instead of an error.
public actor EnvironmentRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// True when an `HLError` is the `environment` module-disabled gate — the
    /// store maps this to the disabled surface (no retry). Tolerates both the
    /// typed `.moduleDisabled("environment")` (the shape ``APIClient`` produces
    /// for `errorCode == "module.disabled"` + `meta.module == "environment"`) and
    /// a bare `403`, whose only documented cause on this route is the gate.
    public nonisolated static func isEnvironmentDisabled(_ error: Error) -> Bool {
        if case let HLError.moduleDisabled(module) = error {
            return module == "environment"
        }
        if case let HLError.server(status, code, _) = error {
            return status == 403 && (code == nil || code == "module.disabled")
        }
        return false
    }

    /// `GET /api/environment` — the module overview: coarse home, travel
    /// overrides, observation-coverage summary, and the Open-Meteo attribution.
    /// Propagates `403 module.disabled` (typed) so the store can flip to the
    /// disabled hint.
    public func overview() async throws -> EnvironmentOverviewDTO {
        let req: APIRequest<EnvironmentOverviewDTO> = .get("/api/environment")
        return try await api.send(req)
    }
}
