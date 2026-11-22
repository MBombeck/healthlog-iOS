import Foundation

/// One forecast period start of `GET /api/cycle/calendar` `projection`
/// (server v1.47.1, `ProjectedCycleDTO`). `k == 1` is the next period (the
/// engine's own forecast, the prediction card already shows it), `2` the one
/// after it, and so on. `bandStart` / `bandEnd` are the earliest and latest
/// likely first day; the band widens with `k` and the server ends the list
/// where a date would be a guess. Rendered as sent: the app never adds a
/// cycle or widens a band on the device.
public struct CycleProjectedCycle: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let k: Int
    /// The most likely first day, `YYYY-MM-DD`.
    public let start: String
    public let periodLength: Int?
    public let bandStart: String
    public let bandEnd: String

    public var id: Int {
        k
    }

    public init(k: Int, start: String, periodLength: Int? = nil, bandStart: String, bandEnd: String) {
        self.k = k
        self.start = start
        self.periodLength = periodLength
        self.bandStart = bandStart
        self.bandEnd = bandEnd
    }
}

/// Why `projection` holds what it holds (`CycleProjectionState`).
public enum CycleProjectionState: String, Codable, Sendable, Equatable, TolerantServerEnum {
    /// The projected cycles.
    case ok = "OK"
    /// Fewer than three observed cycles: the next period only, or nothing.
    case learning = "LEARNING"
    /// The next period's band has passed with nothing logged; no forecast
    /// until one is.
    case late = "LATE"
    /// Prediction is off or the raw chart mode is on.
    case off = "OFF"
    case unknown = "__UNKNOWN__"

    public static let unknownFallback = CycleProjectionState.unknown
    public static let wireVocabulary: StaticString = "cycle projection state"
}

/// What the "upcoming cycles" card shows. Pure, so the rules are tested
/// without a view.
public enum CycleUpcomingContent: Equatable, Sendable {
    /// Nothing: an older server, `OFF`, `LEARNING` with nothing beyond the
    /// next period, or an empty list.
    case none
    /// The next period is later than its band; stated in the muted tone.
    case late
    /// The cycles to list, in the server's order.
    case cycles([CycleProjectedCycle])

    /// - Parameter showsNextPeriod: the prediction card above already names
    ///   the next period (`k == 1`), so the list starts after it; without
    ///   that card the next period is listed too.
    public static func resolve(
        projection: [CycleProjectedCycle]?,
        state: CycleProjectionState?,
        showsNextPeriod: Bool
    ) -> CycleUpcomingContent {
        guard let projection, let state else { return .none }
        switch state {
        case .late:
            return .late
        case .off, .unknown:
            return .none
        case .ok, .learning:
            let listed = projection.filter { !showsNextPeriod || $0.k >= 2 }
            return listed.isEmpty ? .none : .cycles(listed)
        }
    }
}
