import Foundation

/// **#146 (server v1.43.7) — what a sleep row's total is made of.**
///
/// `GET /api/measurements?type=SLEEP_DURATION` answers one row per wake day.
/// Since v1.43.7 its `value` is the day's whole time asleep, the main night
/// plus its daytime naps: the same total the chart, the sleep score and the
/// Today tile use. The parts ride beside it (`MeasurementResource` in
/// `docs/api/openapi.yaml` at v1.43.10):
///
/// - `mainAsleepMinutes`: the main night alone, `null` on a day of naps alone;
/// - `napCount` / `napAsleepMinutes`: the naps of the same wake day.
///
/// The app shows the total wherever it says "sleep" and these parts wherever
/// it says "night", exactly as sent. Nothing here is recomputed: a row from
/// an older server carries none of the fields and gets no split at all.
public struct SleepNightSplit: Codable, Sendable, Hashable {
    /// The main night's own time asleep in minutes; `nil` on a day of naps alone.
    public let mainAsleepMinutes: Double?
    /// Naps on the same wake day.
    public let napCount: Int
    /// Time asleep across those naps, in minutes.
    public let napAsleepMinutes: Double

    public init(mainAsleepMinutes: Double?, napCount: Int, napAsleepMinutes: Double) {
        self.mainAsleepMinutes = mainAsleepMinutes
        self.napCount = max(0, napCount)
        self.napAsleepMinutes = max(0, napAsleepMinutes)
    }

    /// `true` when the day had at least one nap, i.e. the row's total is more
    /// than its night.
    public var hasNaps: Bool {
        napCount > 0 || napAsleepMinutes > 0
    }

    /// `true` for a day whose only sleep was daytime naps.
    public var isNapsOnly: Bool {
        mainAsleepMinutes == nil && hasNaps
    }

    private enum WireKeys: String, CodingKey {
        case mainAsleepMinutes, napCount, napAsleepMinutes
    }

    /// Reads the three fields off a sleep list row, tolerantly: a malformed
    /// field is absent, never a lost row. `nil` when the row carries none of
    /// them (an older server), so the app shows the total alone as before.
    init?(sleepRowFrom decoder: Decoder) {
        guard let row = try? decoder.container(keyedBy: WireKeys.self) else { return nil }
        let main = try? row.decodeIfPresent(Double.self, forKey: .mainAsleepMinutes)
        let count = try? row.decodeIfPresent(Int.self, forKey: .napCount)
        let naps = try? row.decodeIfPresent(Double.self, forKey: .napAsleepMinutes)
        guard main != nil || count != nil || naps != nil else { return nil }
        self.init(mainAsleepMinutes: main, napCount: count ?? 0, napAsleepMinutes: naps ?? 0)
    }
}
