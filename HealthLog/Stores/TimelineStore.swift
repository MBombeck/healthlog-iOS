import Foundation
import Observation

/// What the timeline shows, remembered on this device like on the web
/// (`useDevicePreference`): the value lines and the hidden lanes.
struct TimelinePreferences {
    /// The web's first choice: blood pressure, weight, resting pulse.
    static let defaultValues = ["BLOOD_PRESSURE_SYS", "WEIGHT", "RESTING_HEART_RATE"]
    static let valuesKey = "timeline.values"
    static let hiddenLanesKey = "timeline.hiddenLanes"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var values: [String] {
        get { defaults.stringArray(forKey: Self.valuesKey) ?? Self.defaultValues }
        nonmutating set { defaults.set(newValue, forKey: Self.valuesKey) }
    }

    var hiddenLanes: Set<TimelineLaneKey> {
        get { Set((defaults.stringArray(forKey: Self.hiddenLanesKey) ?? []).compactMap(TimelineLaneKey.init(rawValue:))) }
        nonmutating set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.hiddenLanesKey) }
    }
}

/// The state behind the timeline page: the period, the answer, the chosen
/// lines and lanes, and the chosen day.
///
/// The opt-in `timeline` module decides whether anything is read: off, the
/// page offers to switch it on and sends nothing. A refusal (no right to the
/// whole record, a server without the route) ends the visit quietly.
@MainActor
@Observable
final class TimelineStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(TimelineRead)
        /// The module is off: nothing is read.
        case moduleOff
        /// The server refused the timeline (403, 404).
        case refused
        case failed
    }

    typealias Fetch = @Sendable (_ zoom: TimelineZoom, _ from: String?, _ to: String?, _ values: [String]) async throws -> TimelineRead

    private(set) var phase: Phase = .idle
    /// A newer answer is on its way while the last one stays on screen.
    private(set) var isRefreshing = false
    /// The quick choice on the bar; `.custom` once the axis was zoomed or moved.
    private(set) var period: TimelinePeriod = .standard
    /// The days on the axis. Zooming and moving change it continuously; the
    /// request follows it once the hand rests (``request``).
    private(set) var window: TimelineWindow

    private(set) var values: [String]
    private(set) var hiddenLanes: Set<TimelineLaneKey>
    /// The day the person picked; `nil` shows the newest day with data.
    var selectedDay: Int?

    @ObservationIgnored private let preferences: TimelinePreferences
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let todayProvider: @Sendable () -> Int
    /// Once the person picked a period, an empty quarter no longer widens itself.
    @ObservationIgnored private var userChosePeriod = false

    init(
        preferences: TimelinePreferences = TimelinePreferences(),
        today: @escaping @Sendable () -> Int = { TimelineStore.today(at: .now) },
        fetch: @escaping Fetch
    ) {
        self.preferences = preferences
        self.fetch = fetch
        todayProvider = today
        window = TimelinePeriod.standard.window(today: today(), dataFrom: nil)
        values = preferences.values
        hiddenLanes = preferences.hiddenLanes
    }

    convenience init(repository: TimelineRepository) {
        self.init { zoom, from, to, values in
            try await repository.fetchTimeline(zoom: zoom, from: from, to: to, values: values)
        }
    }

    var today: Int {
        todayProvider()
    }

    /// Today's day number in the account's zone (``ProfileDay``), the zone
    /// the server cuts the timeline's days in; not the device calendar, which
    /// abroad would put "today" a day before or after the server's.
    nonisolated static func today(at now: Date, timeZone: TimeZone = ProfileDay.timeZone) -> Int {
        TimelineDay.number(TimelineDay.key(of: now, calendar: ProfileDay.calendar(in: timeZone))) ?? 0
    }

    var read: TimelineRead? {
        if case let .loaded(read) = phase { return read }
        return nil
    }

    /// The record's first day, once an answer named it.
    @ObservationIgnored private var dataFrom: Int?

    /// What the axis shows now asks the server for.
    var request: TimelinePeriod.Request {
        TimelinePeriod.request(for: window, period: period, today: today)
    }

    /// A tap on the bar: the window of that choice.
    func choose(_ choice: TimelinePeriod) {
        guard choice != .custom else { return }
        userChosePeriod = true
        period = choice
        window = choice.window(today: today, dataFrom: dataFrom)
    }

    /// Two fingers apart (`scale` above 1) or together, around `anchor`
    /// (0 at the leading edge of the plot, 1 at the trailing one), from
    /// `start`, the window when the gesture began.
    func zoom(from start: TimelineWindow, scale: Double, anchor: Double) {
        let zoomed = start.zoomed(by: scale, anchor: anchor, maximumDays: maximumDays, latestEnd: latestEnd)
        guard zoomed != window else { return }
        userChosePeriod = true
        period = .custom
        window = zoomed
    }

    /// The axis moved sideways by `days` from `start`.
    func pan(from start: TimelineWindow, days: Int) {
        let moved = start.panned(by: days, latestEnd: latestEnd)
        guard moved != window else { return }
        userChosePeriod = true
        period = .custom
        window = moved
    }

    /// Never zoomed out past the record and a little room, or fifteen years.
    private var maximumDays: Int {
        let first = dataFrom ?? today - TimelineWindow.maximumSpan
        return min(TimelineWindow.maximumSpan, max(TimelineWindow.minimumSpan, today - first + 1 + 31))
    }

    /// The axis never runs further than a twelfth of its span past today.
    private var latestEnd: Int {
        today + max(1, window.span / 12)
    }

    /// Reads the timeline for the period and the chosen lines. `moduleOn`
    /// is the module map's `timeline` key. Only an explicit `false` keeps
    /// the page from reading: a map that has not loaded yet (a cold start, a
    /// fresh sign-in, whose map only comes with the next foreground) reads
    /// all the same, and a server with the module off answers
    /// `module.disabled`, which turns the page to the switch. Before, an
    /// unknown map showed the switch for a module that was on (device test
    /// of build 312).
    func load(moduleOn: Bool?) async {
        guard Self.reads(moduleOn: moduleOn) else {
            phase = .moduleOff
            return
        }
        if read != nil { isRefreshing = true } else { phase = .loading }
        let request = request
        do {
            let answer = try await fetch(request.zoom, request.from, request.to, values)
            guard request == self.request else { return }
            isRefreshing = false
            dataFrom = answer.range.dataFrom.flatMap(TimelineDay.number)
            if shouldOpenOnAll(answer) {
                // The page reads again for the new window (its load task
                // follows the request), still as the page's own choice.
                period = .all
                window = TimelinePeriod.all.window(today: today, dataFrom: dataFrom)
                return
            }
            if period == .all { window = TimelinePeriod.all.window(today: today, dataFrom: dataFrom) }
            phase = .loaded(answer)
            if let day = selectedDay, !window.contains(day) { selectedDay = nil }
        } catch {
            isRefreshing = false
            if Self.isCancellation(error) { return }
            phase = Self.phase(for: error)
        }
    }

    /// The page's switch: `enable` turns the module on on the server; once it
    /// says yes, the page reads at once. The page's load key cannot carry
    /// this step: a map that was `nil` (read, refused with
    /// `module.disabled`) and is `true` afterwards reads the same, so nothing
    /// else would load again. Returns whether the module is on.
    @discardableResult
    func switchOn(_ enable: () async -> Bool) async -> Bool {
        guard await enable() else { return false }
        await load(moduleOn: true)
        return true
    }

    /// Whether the page reads with this module answer: unless the map says off.
    nonisolated static func reads(moduleOn: Bool?) -> Bool {
        moduleOn != false
    }

    /// Opened on three months that hold nothing while the record has older
    /// entries: open on everything instead of a dead end (the web's
    /// `resolveDefaultWindow`). Only before the person picked a period.
    private func shouldOpenOnAll(_ answer: TimelineRead) -> Bool {
        guard !userChosePeriod, period == .quarter,
              let dataFrom = answer.range.dataFrom.flatMap(TimelineDay.number) else { return false }
        return dataFrom < window.from && Self.isEmpty(answer)
    }

    /// Nothing to draw: no lane item, no point in any line.
    nonisolated static func isEmpty(_ read: TimelineRead) -> Bool {
        read.lanes.allSatisfy(\.items.isEmpty)
            && read.series.allSatisfy(\.points.isEmpty)
            && read.labSeries.allSatisfy(\.points.isEmpty)
            && read.symptomSeries.allSatisfy(\.points.isEmpty)
    }

    nonisolated static func phase(for error: Error) -> Phase {
        switch error as? HLError {
        case .moduleDisabled:
            .moduleOff
        case let .server(status, _, _) where status == 403 || status == 404:
            .refused
        default:
            .failed
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .canceled? = error as? HLError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    // MARK: - Choices

    /// Shows or hides one value line and remembers the choice.
    func setValue(_ key: String, shown: Bool) {
        var next = values.filter { $0 != key }
        if shown { next.append(key) }
        guard next != values else { return }
        values = next
        preferences.values = next
    }

    func isShown(_ key: String) -> Bool {
        values.contains(key)
    }

    /// Shows or hides a lane and remembers the choice.
    func setLane(_ key: TimelineLaneKey, shown: Bool) {
        var next = hiddenLanes
        if shown { next.remove(key) } else { next.insert(key) }
        guard next != hiddenLanes else { return }
        hiddenLanes = next
        preferences.hiddenLanes = next
    }

    /// The day the summary shows: the picked one, else the newest day with data.
    var summaryDay: Int? {
        if let selectedDay { return selectedDay }
        guard let read else { return nil }
        return TimelineSummary.latestDataDay(read: read, window: window, today: today) ?? min(window.to, today)
    }
}

/// The timeline's place in the session, held by the router so it outlives
/// one screen: the store (window, zoom, chosen period) survives a fold or a
/// narrowed window that moves the page from its sidebar tab onto More, and
/// the person's own opening of the page is told apart from such a remount.
@MainActor
@Observable
final class TimelineSession {
    /// The page's state, made by the first screen that needs it.
    var store: TimelineStore?
    /// Openings by the person: a tap on a row, the Insights link, a deep link.
    private(set) var openRequests = 0
    /// The phone's turned full screen is up. Held here rather than in the
    /// screen, so a screen mounted again keeps showing it. Only an opening
    /// and the X change it; a cover that SwiftUI takes down and puts up
    /// again (its content rebuilt, its page remounted) leaves it as it is.
    private(set) var showsAcross = false
    /// Closings of the full screen with its X: the page under it leaves too.
    private(set) var closeRequests = 0
    /// How the session turns the phone. The screen hands in the scene's
    /// policy; tests hand in a recorder.
    @ObservationIgnored var turns = TimelineTurns.inert
    @ObservationIgnored private var takenRequests = 0

    /// The person opened the timeline.
    func noteOpened() {
        openRequests &+= 1
    }

    /// Whether an opening by the person is still to be answered, and marks it
    /// answered. A screen mounted again by a layout change finds none.
    func takeOpenRequest() -> Bool {
        guard takenRequests != openRequests else { return false }
        takenRequests = openRequests
        return true
    }

    /// Puts the full screen up and turns the phone across. The permission
    /// to turn lives as long as the full screen does, from here to its X.
    func openAcross() {
        guard !showsAcross else { return }
        HLLog.ui.notice("Zeitleiste: Vollbild quer angefordert")
        turns.allow(true)
        showsAcross = true
        turns.requestAcross()
    }

    /// What the cover's presentation binding reports. SwiftUI writes `false`
    /// when it takes the cover down on its own, also when it only rebuilds
    /// it; that is not a closing, so the state and the turn stay.
    func coverPresentationChanged(_ shown: Bool) {
        // Kept in the log: a cover taken down without its X is the trace of
        // a rebuild worth knowing about.
        if shown {
            HLLog.ui.notice("Zeitleiste: Cover von SwiftUI wieder gezeigt")
        } else {
            HLLog.ui.notice("Zeitleiste: Cover von SwiftUI abgebaut, Querfreigabe bleibt")
        }
    }

    /// The person closed the full screen with its X: upright first, then
    /// the permission taken back, then the page under it leaves too.
    func closeAcross() {
        guard showsAcross else { return }
        showsAcross = false
        turns.requestUpright()
        turns.allow(false)
        closeRequests &+= 1
    }

    /// A new sign-in starts without the last account's timeline.
    func reset() {
        store = nil
        if showsAcross {
            showsAcross = false
            turns.requestUpright()
            turns.allow(false)
        }
        takenRequests = openRequests
    }
}

/// The three moves of turning the phone for the timeline, as values, so the
/// session decides when and the scene policy (or a test) does it.
@MainActor
struct TimelineTurns {
    var allow: @MainActor (Bool) -> Void
    var requestAcross: @MainActor () -> Void
    var requestUpright: @MainActor () -> Void

    /// Turns nothing: before a screen hands in the scene's policy.
    static let inert = TimelineTurns(allow: { _ in }, requestAcross: {}, requestUpright: {})
}
