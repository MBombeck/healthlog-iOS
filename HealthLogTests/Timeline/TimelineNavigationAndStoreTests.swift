import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// Where the timeline stands in the app (the head of "Tagebuch" in the
/// sidebar, a row in More, `healthlog://timeline`) and how its page state
/// behaves: the opt-in module, refusals, the empty quarter that opens on
/// everything, the remembered lines and lanes.
@Suite("Timeline — navigation and page state", .serialized)
@MainActor
struct TimelineNavigationAndStoreTests {
    // MARK: - Router

    @Test("the timeline heads the diary section and follows the server version, not a module")
    func sidebarPlace() {
        #expect(SidebarSection.diary.destinations.first == .timeline)
        #expect(SidebarDestination.timeline.section == .diary)
        let on = SidebarDestination.enabled(isModuleEnabled: { _ in false }, isCycleTrackingAvailable: false, isTimelineAvailable: true)
        #expect(on.contains(.timeline))
        let off = SidebarDestination.enabled(isModuleEnabled: { _ in true }, isCycleTrackingAvailable: true, isTimelineAvailable: false)
        #expect(!off.contains(.timeline))
    }

    @Test("compact opens it on More, regular selects its own tab; a closed gate opens on More")
    func resolve() {
        let all = Set(SidebarDestination.allCases)
        #expect(AppRouter.resolve(.section(.timeline), sizeClass: .compact, enabledSections: all) == .more(pushing: .timeline))
        #expect(AppRouter.resolve(.section(.timeline), sizeClass: .regular, enabledSections: all) == .select(.section(.timeline)))
        #expect(AppRouter.resolve(.section(.timeline), sizeClass: .regular, enabledSections: []) == .more(pushing: .timeline))
        // On a wide window More does not list the row its sidebar tab carries.
        let regular = ShellLayout(sizeClass: .regular, enabledSections: all)
        #expect(!MoreScreen.listsRow(for: .timeline, in: regular))
        #expect(MoreScreen.listsRow(for: .timeline, in: ShellLayout(sizeClass: .compact, enabledSections: all)))
    }

    @Test("today is the account's day, not the device's")
    func todayInTheProfileZone() throws {
        // 23:30 UTC on 21 November: already the 22nd in Tokyo, still the 21st in Los Angeles.
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-11-21T23:30:00Z"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(TimelineStore.today(at: instant, timeZone: tokyo) == TimelineDay.number("2026-11-22"))
        #expect(TimelineStore.today(at: instant, timeZone: losAngeles) == TimelineDay.number("2026-11-21"))
        #expect(TimelineStore.today(at: instant) == TimelineDay.number(ProfileDay.key(for: instant)), "the default is ProfileDay's zone")
        #expect(TimelineDay.key(of: instant) == ProfileDay.key(for: instant))
    }

    @Test("healthlog://timeline and the push path /timeline open the timeline")
    func deepLinks() throws {
        #expect(try DeepLinkRoute(url: #require(URL(string: "healthlog://timeline"))) == .timeline)
        #expect(try DeepLinkRoute(url: #require(URL(string: "healthlog://TIMELINE"))) == .timeline)
        #expect(DeepLinkRoute.fromPushPath("/timeline") == .timeline)
        #expect(DeepLinkRoute.fromPushPath("/timeline/x") == .dashboard)
    }

    @Test("the link lands on the More stack when compact and on the sidebar tab when wide")
    func linkLanding() {
        let compact = AppRouter()
        compact.apply(.timeline, isAuthenticated: true)
        #expect(compact.selectedTab == .more)
        #expect(compact.morePath.count == 1)

        let wide = AppRouter()
        wide.applyShellLayout(ShellLayout(sizeClass: .regular, enabledSections: Set(SidebarDestination.allCases)))
        wide.apply(.timeline, isAuthenticated: true)
        #expect(wide.selectedTab == .section(.timeline))
        #expect(wide.morePath.isEmpty)
    }

    @Test("one tap on the Insights row puts the timeline on the Insights path, once, as the person's own opening")
    func insightsRowPushesOnce() {
        let router = AppRouter()
        router.selectedTab = .insights
        router.openTimelineFromInsights()
        #expect(router.insightsPath.count == 1)
        #expect(router.timeline.takeOpenRequest())
        // A second tap while the page is on its way pushes nothing more and
        // asks for no second turn.
        router.openTimelineFromInsights()
        #expect(router.insightsPath.count == 1)
        #expect(!router.timeline.takeOpenRequest())
        // A tap on the active Insights tab brings the stack back to its root,
        // and the row opens it again with one tap.
        router.requestInsightsRoot()
        #expect(router.insightsPath.isEmpty)
        router.openTimelineFromInsights()
        #expect(router.insightsPath.count == 1)
        #expect(router.timeline.takeOpenRequest())
    }

    @Test("the push hangs on the Insights stack itself, not on a destination of the pager page")
    func insightsPushLivesOnTheStack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let container = try source("HealthLog/Screens/Insights/InsightsContainerScreen.swift")
        #expect(container.contains("NavigationStack(path: $router.insightsPath)"))
        #expect(container.contains(".navigationDestination(for: InsightsRoute.self)"))
        let overview = try source("HealthLog/Screens/Insights/InsightsScreen.swift")
        #expect(overview.contains("router.openTimelineFromInsights()"))
        #expect(!overview.contains("TimelineScreen()"))
    }

    @Test("the More row's push is the person's opening, without a second tap gesture on the row")
    func moreRowPushNotesTheOpening() throws {
        let router = AppRouter()
        router.morePath.append(MoreRoute.timeline)
        #expect(router.timeline.takeOpenRequest())
        // Another page first, or the timeline deeper in the stack: no opening.
        router.morePath = .init()
        router.morePath.append(MoreRoute.personalRecords)
        #expect(!router.timeline.takeOpenRequest())
        router.morePath.append(MoreRoute.timeline)
        #expect(!router.timeline.takeOpenRequest())

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let more = try String(contentsOf: root.appendingPathComponent("HealthLog/Screens/Settings/MoreScreen.swift"), encoding: .utf8)
        #expect(!more.contains("simultaneousGesture(TapGesture().onEnded { router.timeline"))
    }

    @Test("More and the sidebar name it alike")
    func rowAndTab() {
        let item = AuthenticatedShell.sidebarItem(for: .timeline)
        #expect(item.titleKey == MoreScreen.Layout.timelineRow.title)
        #expect(item.systemImage == "calendar.day.timeline.left")
        #expect(MoreScreen.Layout.recordsRows.first?.id == "timeline")
    }

    @Test("the value lines on offer: the web's order first, none of a module that is off")
    func valueOptions() {
        let available = ["WEIGHT", "SLEEP_DURATION", "VO2_MAX", "BLOOD_PRESSURE_SYS", "RESTING_HEART_RATE", "MOOD"]
        let all = TimelineChoicesMenu.measurementOptions(available: available) { _ in true }
        #expect(all == ["BLOOD_PRESSURE_SYS", "WEIGHT", "RESTING_HEART_RATE", "SLEEP_DURATION", "MOOD", "VO2_MAX"])
        let noSleepNoMood = TimelineChoicesMenu.measurementOptions(available: available) { $0 != .sleep && $0 != .mood }
        #expect(noSleepNoMood == ["BLOOD_PRESSURE_SYS", "WEIGHT", "RESTING_HEART_RATE", "VO2_MAX"])
    }

    @Test("a server measurement name finds the app's metric; diastolic reads as blood pressure")
    func kinds() {
        #expect(TimelineWording.kind(forServerName: "WEIGHT") == .weight)
        #expect(TimelineWording.kind(forServerName: "BLOOD_PRESSURE_DIA") == .bloodPressure)
        #expect(TimelineWording.kind(forServerName: "RESTING_HEART_RATE") == .restingHeartRate)
        #expect(TimelineWording.kind(forServerName: "NOT_A_TYPE") == nil)
    }

    // MARK: - Store

    nonisolated static let today = TimelineDay.number("2026-11-17") ?? 0

    nonisolated static func read(dataFrom: String = "2023-11-18", lanes: [TimelineLane] = [], weight: Bool = true) -> TimelineRead {
        TimelineRead(
            zoom: .quarter,
            range: TimelineRange(from: "2026-08-19", to: "2026-11-17", dataFrom: dataFrom),
            lanes: lanes,
            bucket: .week,
            series: weight ? [TimelineValueSeries(
                key: "WEIGHT",
                unit: "kg",
                points: [TimelineValuePoint(t: "2026-11-09", mean: 88, count: 4)]
            )] : []
        )
    }

    private func store(
        defaults: UserDefaults,
        answer: @escaping @Sendable (TimelineZoom) throws -> TimelineRead
    ) -> (TimelineStore, TimelineCalls) {
        let calls = TimelineCalls()
        let store = TimelineStore(
            preferences: TimelinePreferences(defaults: defaults),
            today: { Self.today },
            fetch: { zoom, from, to, values in
                calls.record(zoom: zoom, from: from, to: to, values: values)
                return try answer(zoom)
            }
        )
        return (store, calls)
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "timeline-\(UUID().uuidString)"))
    }

    @Test("with the module off nothing is read; on, the chosen lines are asked for")
    func moduleGate() async throws {
        let (store, calls) = try store(defaults: defaults()) { _ in Self.read() }
        await store.load(moduleOn: false)
        #expect(store.phase == .moduleOff)
        #expect(calls.all.isEmpty)
        await store.load(moduleOn: true)
        #expect(store.read == Self.read())
        #expect(calls.last?.values == TimelinePreferences.defaultValues)
        #expect(calls.last?.zoom == .range)
    }

    /// Build 312: the module was on on the server, but the app's module map
    /// had not loaded yet (a fresh sign-in loads it on the next foreground),
    /// and the page asked to switch it on. The server is the answer: an
    /// unknown map reads, and shows the board without any switch.
    @Test("server on, map not loaded yet: the page reads and asks for no switch")
    func serverOnMapUnknown() async throws {
        let (store, calls) = try store(defaults: defaults()) { _ in Self.read() }
        await store.load(moduleOn: nil)
        #expect(calls.all.count == 1)
        #expect(store.read == Self.read())
        #expect(store.phase != .moduleOff)
        #expect(TimelineStore.reads(moduleOn: nil))
        #expect(TimelineStore.reads(moduleOn: true))
        #expect(!TimelineStore.reads(moduleOn: false))
    }

    @Test("server off, map not loaded yet: the server's refusal shows the switch")
    func serverOffMapUnknown() async throws {
        let (store, _) = try store(defaults: defaults()) { _ in throw HLError.moduleDisabled("timeline") }
        await store.load(moduleOn: nil)
        #expect(store.phase == .moduleOff)
    }

    /// Review P2: map `nil`, server off, the switch flips it on. The load key
    /// reads the same before and after, so the switch itself must read.
    @Test("map unknown, server off, switched on: the page reads at once")
    func switchOnReads() async throws {
        let serverOn = TimelineFlag()
        let (store, calls) = try store(defaults: defaults()) { _ in
            guard serverOn.value else { throw HLError.moduleDisabled("timeline") }
            return Self.read()
        }
        await store.load(moduleOn: nil)
        #expect(store.phase == .moduleOff)
        let switched = await store.switchOn {
            serverOn.value = true
            return true
        }
        #expect(switched)
        #expect(store.phase != .moduleOff)
        #expect(store.read == Self.read())
        #expect(calls.all.count == 2)
        // A refused switch reads nothing.
        let (other, otherCalls) = try self.store(defaults: defaults()) { _ in throw HLError.moduleDisabled("timeline") }
        await other.load(moduleOn: nil)
        let refused = await other.switchOn { false }
        #expect(!refused)
        #expect(otherCalls.all.count == 1)
    }

    /// A pick moves only the band and the summary; the rows stay as they
    /// are (`.equatable()` on the board, device test of 312: not snappy).
    @Test("a pick keeps the board: the same content draws the same board, whatever is chosen")
    func boardIgnoresTheChoice() async throws {
        let (store, _) = try store(defaults: defaults()) { _ in Self.read() }
        await store.load(moduleOn: true)
        let read = try #require(store.read)
        let wording = TimelineWording(read: read, units: .standard)
        let content = TimelineBoardContent.make(
            read: read, window: store.window, today: store.today,
            chosenValues: store.values, hiddenLanes: store.hiddenLanes, wording: wording
        )
        let before = TimelineBoardView(content: content, store: store, wording: wording)
        store.selectedDay = Self.today - 3
        let after = TimelineBoardView(content: content, store: store, wording: wording)
        #expect(before == after)
        #expect(before != TimelineBoardView(content: content, store: store, wording: wording, density: .short))
    }

    @Test("scrubbing waits for a short hold and gives way to any earlier move")
    func holdScrubThresholds() {
        #expect(TimelineHoldScrub.holdDuration == 0.25)
        #expect(TimelineHoldScrub.allowableMovement == 10)
        #expect(!TimelineSidewaysPan.isSideways(CGPoint(x: 10, y: 200)))
        #expect(TimelineSidewaysPan.isSideways(CGPoint(x: 300, y: 20)))
    }

    @Test("a refusal ends the visit quietly, the module switched off elsewhere shows the switch, anything else a retry")
    func failures() async throws {
        let (refused, _) = try store(defaults: defaults()) { _ in throw HLError.server(status: 403, code: nil, message: "no") }
        await refused.load(moduleOn: true)
        #expect(refused.phase == .refused)
        let (off, _) = try store(defaults: defaults()) { _ in throw HLError.moduleDisabled("timeline") }
        await off.load(moduleOn: true)
        #expect(off.phase == .moduleOff)
        let (failed, _) = try store(defaults: defaults()) { _ in throw HLError.offline }
        await failed.load(moduleOn: true)
        #expect(failed.phase == .failed)
    }

    @Test("three empty months over an older record open on everything, until the person picks a period")
    func emptyQuarterOpensOnAll() async throws {
        let (store, calls) = try store(defaults: defaults()) { zoom in
            zoom == .range ? Self.read(weight: false) : Self.read()
        }
        await store.load(moduleOn: true)
        #expect(store.period == .all)
        await store.load(moduleOn: true)
        #expect(calls.all.map(\.zoom) == [.range, .all])
        #expect(store.read != nil)
        #expect(store.window.from == TimelineDay.number("2023-11-18"))

        let (picked, _) = try self.store(defaults: defaults()) { _ in Self.read(weight: false) }
        picked.choose(.year)
        picked.choose(.quarter)
        await picked.load(moduleOn: true)
        #expect(picked.period == .quarter)
    }

    @Test("six months ask for a range, a zoom leaves the quick choices; lines and lanes are remembered on the device")
    func choicesPersist() async throws {
        let suite = try defaults()
        let (store, calls) = store(defaults: suite) { _ in Self.read() }
        store.choose(.halfYear)
        await store.load(moduleOn: true)
        #expect(calls.last?.zoom == .range && calls.last?.from == "2026-06-04" && calls.last?.to == "2026-11-17")
        // Two fingers move the window off the quick choice: the bar marks none.
        store.zoom(from: store.window, scale: 3, anchor: 1)
        #expect(store.period == .custom && store.window.span < 182)
        store.choose(.week)
        #expect(store.period == .week && store.window.span == 7)
        store.setValue("lab:bm_ggt", shown: true)
        store.setValue("WEIGHT", shown: false)
        store.setLane(.visits, shown: false)
        let again = TimelinePreferences(defaults: suite)
        #expect(again.values == ["BLOOD_PRESSURE_SYS", "RESTING_HEART_RATE", "lab:bm_ggt"])
        #expect(again.hiddenLanes == [.visits])
        store.setLane(.visits, shown: true)
        #expect(TimelinePreferences(defaults: suite).hiddenLanes.isEmpty)
    }

    @Test("before a pick the summary shows the newest day with data; a pick wins")
    func summaryDay() async throws {
        let (store, _) = try store(defaults: defaults()) { _ in Self.read() }
        await store.load(moduleOn: true)
        #expect(store.summaryDay == TimelineDay.number("2026-11-09"))
        store.selectedDay = TimelineDay.number("2026-10-01")
        #expect(store.summaryDay == TimelineDay.number("2026-10-01"))
    }
}

/// The requests a store sent.
private final class TimelineCalls: @unchecked Sendable {
    struct Call {
        let zoom: TimelineZoom
        let from: String?
        let to: String?
        let values: [String]
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func record(zoom: TimelineZoom, from: String?, to: String?, values: [String]) {
        lock.withLock { calls.append(Call(zoom: zoom, from: from, to: to, values: values)) }
    }

    var all: [Call] {
        lock.withLock { calls }
    }

    var count: Int {
        all.count
    }

    var last: Call? {
        all.last
    }
}

/// A flag the fetch closure reads and the test flips.
private final class TimelineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
