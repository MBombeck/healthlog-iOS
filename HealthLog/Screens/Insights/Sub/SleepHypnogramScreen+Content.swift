import Foundation

// #146 (server v1.43.7) — what the hypnogram screen shows for one answer of
// `GET /api/sleep/night`.
//
// With a `date` the server still answers a day of naps alone with `main: null`
// plus `naps`. The screen used to read that as "no sleep data for this night"
// and hid the naps. Pure, so the decision is testable without a view host.

extension SleepHypnogramScreen {
    enum Content: Equatable {
        /// First load, nothing cached yet.
        case loading
        /// A main night: summary, hypnogram, legend, then any naps.
        case night(SleepSession)
        /// No main night, but naps: the naps section on its own.
        case napsOnly
        /// No sleep at all (or the load failed with nothing cached).
        case empty
    }

    nonisolated static func content(for night: SleepNightDTO?, isLoading: Bool) -> Content {
        if isLoading, night == nil { return .loading }
        if let main = night?.main { return .night(main) }
        if let naps = night?.naps, !naps.isEmpty { return .napsOnly }
        return .empty
    }

    /// The wake-day key a no-date answer anchors the night navigation on. Since
    /// v1.43.7 that answer is the latest night with a main sleep; an account
    /// that has only ever napped gets its latest day of naps, which anchors the
    /// navigation just as well.
    nonisolated static func anchorDayKey(for night: SleepNightDTO) -> String? {
        (night.main ?? night.naps.first).map { SleepNightRepository.utcDayKey(for: $0.night) }
    }
}
