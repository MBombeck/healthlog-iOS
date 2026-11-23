import Foundation

/// `GET /api/nutrients/energy-balance?days=N` (server 1.49.0), the daily
/// energy balance under Ernährung.
///
/// Network-direct like the other nutrient reads: the store keeps nothing, the
/// page reads on appear and on pull. The route is behind the `nutrients`
/// module (`403 module.disabled`, typed by ``APIClient``); a server before
/// 1.49 answers `404`. Both mean "no card", not an error.
public actor EnergyBalanceRepository {
    private let api: APIClientProtocol

    /// The window the page reads: the web card's thirty days.
    public static let windowDays = 30
    /// The server's bounds for `days`.
    public static let allowedDays: ClosedRange<Int> = 7 ... 90

    public init(api: APIClientProtocol) {
        self.api = api
    }

    public func read(days: Int = EnergyBalanceRepository.windowDays) async throws -> EnergyBalanceDTO {
        let clamped = min(max(days, Self.allowedDays.lowerBound), Self.allowedDays.upperBound)
        let req: APIRequest<EnergyBalanceDTO> = .get(
            "/api/nutrients/energy-balance",
            query: [("days", String(clamped))]
        )
        return try await api.send(req)
    }

    /// The answers that mean "this account or server has no balance to
    /// show": the module is off (403) or the route does not exist yet (404).
    public nonisolated static func hidesCard(_ error: Error) -> Bool {
        if NutrientReadRepository.isNutrientsDisabled(error) { return true }
        if case let HLError.server(status, _, _) = error { return status == 404 }
        return false
    }
}
