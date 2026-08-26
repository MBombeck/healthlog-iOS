import Foundation

/// Unified data-state for a single metric kind + range window. The single
/// source of truth every tile, chart-detail section, drill-down row and
/// summary line must read from to avoid the PA4 "Tile leer, Detail voll"
/// class of bug (v0.4.2 user-reported BP/Pulse regression).
///
/// **Rule (PA4 §"Recommended unified data-source pattern"):** when a
/// surface has both a placeholder branch ("Noch keine Daten") and a tap
/// target that opens a detail, both surfaces MUST derive from the same
/// `MetricDataState` instance for the same (kind, range) pair. The state
/// is computed against `MeasurementsRepository.recent(kind:)` so the tile
/// agrees with the list/detail screens that already read from there.
///
/// The dashboard `/api/dashboard/summary` endpoint remains useful as a
/// cold-launch seed (first-paint sub-100ms) but is no longer the
/// authority: once a per-metric `MetricDataState` resolves, every
/// surface re-derives from it.
public enum MetricDataState: Sendable, Equatable {
    /// Pre-fetch placeholder — no resolution attempted yet. Distinct
    /// from `.loading` so callers can show a different shimmer style
    /// (e.g. cold-launch tile vs in-flight reload).
    case unknown
    /// A fetch is in flight and no warm cache is available to render
    /// optimistically. UI shows skeleton / spinner.
    case loading
    /// Confirmed empty after a successful fetch. Carries an explicit
    /// reason so the UI can choose between "no data ever" vs "outside
    /// the queried window" vs "hidden by a user source-filter".
    case empty(reason: EmptyReason)
    /// Populated state. `latest` is the most recent measurement in the
    /// queried window. `samples` is the full filtered set used to
    /// render chart points / list rows.
    case ready(latest: Measurement, samples: [Measurement])
}

/// Disambiguates why a `MetricDataState.empty` was emitted. The UI uses
/// this to pick copy + CTA: an "Erste Messung erfassen" pitch for
/// `.noData` is wrong for `.outsideRange` (the user has data, just not
/// in the chosen 30-day window).
public enum EmptyReason: Sendable, Equatable {
    /// The user has never recorded a measurement of this kind. The
    /// canonical first-time-experience empty state — surface a CTA to
    /// log the first reading.
    case noData
    /// The user has measurements of this kind, but none inside the
    /// queried range. Carries the timestamp of the most recent reading
    /// so the UI can render "Letzte Messung vor X Tagen" instead of
    /// pretending there is nothing.
    case outsideRange(latestAt: Date)
    /// All measurements in the range exist but are hidden by a
    /// user-applied source-filter (e.g. "Manual only", "Apple Health
    /// only"). Surface a copy nudge to clear the filter.
    case sourceFiltered
}

// MARK: - Convenience derivations

public extension MetricDataState {
    /// `true` when `.ready` with at least one sample. Drives "show value"
    /// branches at call sites that don't care about the surrounding
    /// metadata.
    var hasValue: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The latest reading if any — convenience for tile value-row
    /// rendering. Returns `nil` for every non-ready state including
    /// `.empty(.outsideRange)` (where there IS a latest, but the tile
    /// should render the secondary "last seen" copy instead of the
    /// value to avoid implying the value is current).
    var latestMeasurement: Measurement? {
        if case let .ready(latest, _) = self { return latest }
        return nil
    }

    /// Sample count in the loaded window. Drives drill-down subtitles
    /// like "12 Einträge im Zeitraum".
    var sampleCount: Int {
        if case let .ready(_, samples) = self { return samples.count }
        return 0
    }

    /// v0.14.4 D2 — `true` when the metric HAS recorded data but every row
    /// falls outside the currently-queried range. The drill-down row uses this
    /// to say "outside the period" instead of "no entries" (the all-time list
    /// still has rows the operator can tap into).
    var isOutsideRange: Bool {
        if case .empty(.outsideRange) = self { return true }
        return false
    }

    /// `true` while a fetch is pending (`.unknown` or `.loading`). UI
    /// suppresses empty-state copy while pending.
    var isPending: Bool {
        switch self {
        case .unknown, .loading: true
        case .empty, .ready: false
        }
    }
}

// MARK: - Builder

public extension MetricDataState {
    /// Derives a `MetricDataState` from a fetched slice of measurements
    /// for one kind. Pure, `nonisolated` — callable from any context
    /// + unit tests. Returns:
    ///
    /// - `.empty(.sourceFiltered)` if the caller applied a filter that
    ///   removed every otherwise-eligible row.
    /// - `.empty(.outsideRange(latestAt:))` if `allSamples` has at
    ///   least one row but every row falls before `since`.
    /// - `.empty(.noData)` if `allSamples` is empty entirely.
    /// - `.ready(latest: , samples: )` if the in-range, post-filter
    ///   set is non-empty.
    ///
    /// `allSamples` and `inRange` are both expected to be filtered to
    /// `kind` already (the caller is the repository which knows the
    /// kind in scope). `latest` is computed as `max(by recordedAt)` of
    /// the in-range set — most recent wins.
    ///
    /// **#33 — displayable-latest guard.** `latest` (the single value the tile
    /// renders) is picked only from rows that pass ``Measurement/isDisplayableLatest``,
    /// so a malformed 0-systolic / 0-diastolic blood-pressure row can never
    /// surface as "0/77 mmHg". When every in-range row is invalid the state
    /// collapses to the honest empty/outside-range/no-data path instead of a
    /// `0` value. Non-BP kinds are always displayable, so their behaviour is
    /// unchanged. `samples` deliberately keeps the full in-range set — the
    /// sparkline projection already drops systolic-0 artefacts, and the
    /// drill-down list still shows the raw rows.
    static func derive(
        allSamples: [Measurement],
        inRange: [Measurement],
        sourceFilterApplied: Bool
    ) -> MetricDataState {
        if let latest = inRange
            .filter(\.isDisplayableLatest)
            .max(by: { $0.recordedAt < $1.recordedAt })
        {
            return .ready(latest: latest, samples: inRange)
        }
        // No displayable in-range reading — disambiguate the reason.
        if sourceFilterApplied, !allSamples.isEmpty {
            return .empty(reason: .sourceFiltered)
        }
        if let latestOutside = allSamples
            .filter(\.isDisplayableLatest)
            .max(by: { $0.recordedAt < $1.recordedAt })
        {
            return .empty(reason: .outsideRange(latestAt: latestOutside.recordedAt))
        }
        return .empty(reason: .noData)
    }
}
