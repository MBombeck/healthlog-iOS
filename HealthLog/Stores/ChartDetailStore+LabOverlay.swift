import Foundation
import Observation

/// **1.5 LAB-LINES (#158, server #1299)** — the state behind the lab
/// marker under a metric chart.
///
/// Owned by the metric page's extras block, so it lives as long as the page
/// and never outlives an account switch. It reads `GET /api/timeline` only
/// when there is something to show: once a marker is chosen (its readings over
/// the chart's window) or when the person opens the choice (the markers the
/// record has). A page without a chosen marker sends nothing.
///
/// A refusal (the `timeline` module off, a grant that does not reach the
/// timeline, a server without the route) hides the choice and the marker
/// for the rest of the visit; any other failure keeps them and offers a retry.
@MainActor
@Observable
final class ChartLabOverlayModel {
    enum Phase: Equatable {
        /// No marker chosen: nothing under the chart.
        case idle
        case loading
        case loaded(TimelineLabSeries)
        /// The chosen marker is not in the record (deleted, another record's):
        /// nothing under the chart, no message.
        case missing
        case failed
    }

    enum Choices: Equatable {
        case notLoaded
        case loading
        case loaded([TimelineLabMarker])
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var choices: Choices = .notLoaded
    /// `true` once the server refused the timeline for this visit.
    private(set) var isRefused = false
    /// `true` while a loaded marker is on screen and a newer window is on its way.
    private(set) var isRefreshing = false
    private(set) var selectedKey: String?

    typealias Fetch = @Sendable (_ from: String, _ to: String, _ markerKey: String?) async throws -> TimelineLabRead

    @ObservationIgnored private let kind: MetricKind
    @ObservationIgnored private let preference: ChartLabOverlayPreference
    @ObservationIgnored private let fetch: Fetch

    init(kind: MetricKind, preference: ChartLabOverlayPreference = ChartLabOverlayPreference(), fetch: @escaping Fetch) {
        self.kind = kind
        self.preference = preference
        self.fetch = fetch
        selectedKey = preference.markerKey(for: kind)
    }

    convenience init(kind: MetricKind, repository: TimelineRepository) {
        self.init(kind: kind) { from, to, key in
            try await repository.fetchLabs(from: from, to: to, markerKey: key)
        }
    }

    /// Reads the chosen marker over the chart's window (`days` ending `now`).
    /// The same read brings the record's markers, so the choice is ready too.
    func load(days: Int, now: Date = .now, calendar: Calendar = .current) async {
        guard !isRefused, let key = selectedKey else {
            phase = .idle
            return
        }
        if case .loaded = phase { isRefreshing = true } else { phase = .loading }
        let window = ChartDetailStore.labWindow(days: days, now: now, calendar: calendar)
        do {
            let read = try await fetch(window.from, window.to, key)
            guard key == selectedKey else { return }
            choices = .loaded(read.availableLabs)
            phase = read.series(for: key).map(Phase.loaded) ?? .missing
            isRefreshing = false
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { return }
            isRefreshing = false
            if Self.isRefusal(error) {
                isRefused = true
                phase = .idle
            } else {
                phase = .failed
            }
        }
    }

    /// Reads the markers the record has, for the choice. A one-day window
    /// keeps the answer small: `availableLabs` does not depend on it.
    func loadChoices(now: Date = .now, calendar: Calendar = .current) async {
        guard !isRefused else { return }
        if case .loaded = choices { return }
        choices = .loading
        let today = TimelineRepository.dayKey(now, calendar: calendar)
        do {
            let read = try await fetch(today, today, nil)
            choices = .loaded(read.availableLabs)
        } catch {
            if Self.isCancellation(error) || Task.isCancelled {
                choices = .notLoaded
                return
            }
            if Self.isRefusal(error) {
                isRefused = true
                choices = .notLoaded
                phase = .idle
            } else {
                choices = .failed
            }
        }
    }

    /// Lets the choice be read again after a failure.
    func retryChoices() {
        if choices == .failed { choices = .notLoaded }
    }

    /// Chooses a marker (or none) for this metric and remembers it. At most
    /// one marker is shown, so the chart stays calm.
    func select(_ key: String?) {
        guard key != selectedKey else { return }
        selectedKey = key
        preference.setMarkerKey(key, for: kind)
        isRefreshing = false
        phase = key == nil ? .idle : .loading
    }

    /// A refusal is the record being closed here: module off (`module.disabled`),
    /// no right (403, also the local sharing denial), no route (404).
    nonisolated static func isRefusal(_ error: Error) -> Bool {
        switch error as? HLError {
        case .moduleDisabled:
            true
        case let .server(status, _, _) where status == 403 || status == 404:
            true
        default:
            false
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .canceled? = error as? HLError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    /// The record's markers grouped for the choice: by `panel`, panels in
    /// alphabetical order and the markers without one ("Other") last, the
    /// markers of a group alphabetical.
    nonisolated static func groups(_ markers: [TimelineLabMarker]) -> [MarkerGroup] {
        var byPanel: [String: [TimelineLabMarker]] = [:]
        var other: [TimelineLabMarker] = []
        for marker in markers {
            let panel = marker.panel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if panel.isEmpty { other.append(marker) } else { byPanel[panel, default: []].append(marker) }
        }
        let byName: (TimelineLabMarker, TimelineLabMarker) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        var groups = byPanel.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { MarkerGroup(panel: $0, markers: byPanel[$0, default: []].sorted(by: byName)) }
        if !other.isEmpty { groups.append(MarkerGroup(panel: nil, markers: other.sorted(by: byName))) }
        return groups
    }

    struct MarkerGroup: Equatable, Identifiable {
        /// `nil` is the "Other" group.
        let panel: String?
        let markers: [TimelineLabMarker]

        var id: String {
            panel ?? "\u{0}other"
        }
    }
}

/// Where the chosen marker of each metric is remembered (on this device, like
/// the other chart choices). Only the marker's key is kept, never a value.
struct ChartLabOverlayPreference: @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func defaultsKey(for kind: MetricKind) -> String {
        "insights.labOverlay.\(kind.rawValue)"
    }

    func markerKey(for kind: MetricKind) -> String? {
        let stored = defaults.string(forKey: Self.defaultsKey(for: kind))
        return stored.flatMap { TimelineRepository.isMarkerKey($0) ? $0 : nil }
    }

    func setMarkerKey(_ key: String?, for kind: MetricKind) {
        if let key, TimelineRepository.isMarkerKey(key) {
            defaults.set(key, forKey: Self.defaultsKey(for: kind))
        } else {
            defaults.removeObject(forKey: Self.defaultsKey(for: kind))
        }
    }
}

extension ChartDetailStore {
    /// The chart's window as the timeline reads it: `days` local days ending
    /// today (both inclusive), at most the 15 years the server allows.
    nonisolated static func labWindow(days: Int, now: Date, calendar: Calendar) -> (from: String, to: String) {
        let span = min(max(days, 1), TimelineRepository.maximumWindowDays)
        let start = calendar.date(byAdding: .day, value: -(span - 1), to: now) ?? now
        return (TimelineRepository.dayKey(start, calendar: calendar), TimelineRepository.dayKey(now, calendar: calendar))
    }
}
