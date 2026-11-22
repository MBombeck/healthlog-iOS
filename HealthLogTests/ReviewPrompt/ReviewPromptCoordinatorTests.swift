import Foundation
@testable import HealthLog
import Testing

/// Pins the coordinator between the stores, the stored state, and the shell.
@MainActor
@Suite("Review prompt coordinator")
struct ReviewPromptCoordinatorTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private let calm = ReviewPromptMoment(isForegroundActive: true, isAtTabRoot: true)

    private func weight(_ kilograms: Double) -> HealthLog.Measurement {
        HealthLog.Measurement(id: "w", kind: .weight, recordedAt: Date(), value: .scalar(kilograms))
    }

    /// Lets the coordinator's own tasks run to their end.
    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    /// Ranges whose load the test releases by hand.
    @MainActor
    private final class FakeRanges: ReviewPromptRangeSource {
        private(set) var hasLoadedRanges: Bool
        private var release: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        private var loadStarted = false

        init(loaded: Bool) {
            hasLoadedRanges = loaded
        }

        func loadRanges() async {
            loadStarted = true
            started?.resume()
            started = nil
            await withCheckedContinuation { release = $0 }
            hasLoadedRanges = true
        }

        func waitUntilLoadStarted() async {
            guard !loadStarted else { return }
            await withCheckedContinuation { started = $0 }
        }

        func finishLoad() {
            release?.resume()
            release = nil
        }

        func band(for metric: ThresholdMetric) -> ThresholdRange? {
            hasLoadedRanges && metric == .weight ? ThresholdRange(min: 60, max: 90) : nil
        }
    }

    private func makeCoordinator(clock: Clock, version: String = "1.6") -> (ReviewPromptCoordinator, UserDefaults) {
        let suite = "review-prompt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let coordinator = ReviewPromptCoordinator(
            store: ReviewPromptStateStore(defaults: defaults),
            version: version,
            clock: { clock.now }
        )
        return (coordinator, defaults)
    }

    @Test("Creating the coordinator records the first launch once")
    func firstLaunch() {
        let clock = Clock()
        let (coordinator, defaults) = makeCoordinator(clock: clock)
        #expect(coordinator.state.firstSeenAt == clock.now)

        clock.now = clock.now.addingTimeInterval(86400)
        let again = ReviewPromptCoordinator(store: ReviewPromptStateStore(defaults: defaults), version: "1.6") {
            clock.now
        }
        #expect(again.state.firstSeenAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("Only a clean, server-confirmed tenth value asks the shell to look")
    func requestOnlyAfterCleanSave() {
        let (coordinator, _) = makeCoordinator(clock: Clock())
        for _ in 0 ..< 9 {
            coordinator.recordCapture(flagged: false, savedOnServer: true)
        }
        #expect(coordinator.promptRequest == 0)
        coordinator.recordCapture(flagged: false, savedOnServer: false)
        #expect(coordinator.promptRequest == 0)
        coordinator.recordCapture(flagged: true, savedOnServer: true)
        #expect(coordinator.promptRequest == 0)
        coordinator.recordCapture(flagged: false, savedOnServer: true)
        #expect(coordinator.promptRequest == 1)
        #expect(coordinator.state.capturedValues == 12)
    }

    @Test("Completing the seventh adherent day asks the shell to look")
    func adherenceRequest() {
        let (coordinator, _) = makeCoordinator(clock: Clock())
        for dayOfMonth in 1 ... 6 {
            coordinator.recordDay("2027-03-0\(dayOfMonth)", statuses: [.taken])
        }
        #expect(coordinator.promptRequest == 0)
        coordinator.recordDay("2027-03-07", statuses: [.taken, .pending])
        #expect(coordinator.promptRequest == 0)
        coordinator.recordDay("2027-03-07", statuses: [.taken, .taken])
        #expect(coordinator.promptRequest == 1)
        // The same list reported again changes nothing.
        coordinator.recordDay("2027-03-07", statuses: [.taken, .taken])
        #expect(coordinator.promptRequest == 1)
    }

    @Test("A measurement without known ranges counts but stays quiet, and so does a kind without a range")
    func measurementCheck() async {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(clock: clock)
        let weight = HealthLog.Measurement(id: "w", kind: .weight, recordedAt: clock.now, value: .scalar(80))
        await coordinator.recordMeasurement(weight, savedOnServer: true)
        #expect(coordinator.state.capturedValues == 1)
        #expect(coordinator.state.lastFlaggedCaptureAt == clock.now)

        clock.now = clock.now.addingTimeInterval(2 * 86400)
        let temperature = HealthLog.Measurement(id: "t", kind: .bodyTemperature, recordedAt: clock.now, value: .scalar(39.4))
        await coordinator.recordMeasurement(temperature, savedOnServer: true)
        #expect(coordinator.state.capturedValues == 2)
        #expect(coordinator.state.lastFlaggedCaptureAt == clock.now)
    }

    @Test("On the measure path a saved value can ask, a queued one counts quietly, a failed one not at all")
    func measurePathOutcomes() async {
        let (coordinator, _) = makeCoordinator(clock: Clock())
        let ranges = FakeRanges(loaded: true)
        coordinator.ranges = ranges
        for _ in 0 ..< 9 {
            await coordinator.recordMeasurement(weight(75), savedOnServer: true)
        }
        coordinator.noteMeasurement(kind: .weight, value: .scalar(75), glucoseContext: nil, outcome: .failed(.offline))
        await settle()
        #expect(coordinator.state.capturedValues == 9)

        coordinator.noteMeasurement(kind: .weight, value: .scalar(75), glucoseContext: nil, outcome: .queued)
        await settle()
        #expect(coordinator.state.capturedValues == 10)
        #expect(!coordinator.hasPendingRequest)

        coordinator.noteMeasurement(kind: .weight, value: .scalar(75), glucoseContext: nil, outcome: .success)
        await settle()
        #expect(coordinator.state.capturedValues == 11)
        #expect(coordinator.hasPendingRequest)
        #expect(coordinator.state.lastFlaggedCaptureAt == nil)
    }

    @Test("While the ranges load, the value is already flagged; a passed check takes the mark back")
    func provisionalMarkInRange() async {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(clock: clock)
        let ranges = FakeRanges(loaded: false)
        coordinator.ranges = ranges
        coordinator.noteMeasurement(kind: .weight, value: .scalar(75), glucoseContext: nil, outcome: .success)
        #expect(coordinator.state.lastFlaggedCaptureAt == clock.now, "marked before the load")
        await ranges.waitUntilLoadStarted()
        #expect(coordinator.state.lastFlaggedCaptureAt == clock.now, "still marked during the load")
        ranges.finishLoad()
        await settle()
        #expect(coordinator.state.lastFlaggedCaptureAt == nil)
        #expect(coordinator.state.capturedValues == 1)
    }

    @Test("A value out of range keeps the mark after the load")
    func provisionalMarkOutOfRange() async {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(clock: clock)
        let ranges = FakeRanges(loaded: false)
        coordinator.ranges = ranges
        coordinator.noteMeasurement(kind: .weight, value: .scalar(120), glucoseContext: nil, outcome: .success)
        await ranges.waitUntilLoadStarted()
        ranges.finishLoad()
        await settle()
        #expect(coordinator.state.lastFlaggedCaptureAt == clock.now)
    }

    @Test("A request stays pending until the dialog is shown or the wait gives it up")
    func pendingRequest() {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(clock: clock)
        for _ in 0 ..< 10 {
            coordinator.recordCapture(flagged: false, savedOnServer: true)
        }
        #expect(coordinator.hasPendingRequest)
        coordinator.dropRequest()
        #expect(!coordinator.hasPendingRequest)
        coordinator.recordCapture(flagged: false, savedOnServer: true)
        #expect(coordinator.hasPendingRequest)
        clock.now = clock.now.addingTimeInterval(8 * 86400)
        #expect(coordinator.promptNow(moment: calm) == .tenthValue)
        #expect(!coordinator.hasPendingRequest)
    }

    @Test("Signing out resets the counters, keeps the pacing, and drops a waiting request")
    func signOut() {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(clock: clock)
        for _ in 0 ..< 10 {
            coordinator.recordCapture(flagged: false, savedOnServer: true)
        }
        coordinator.recordDay("2027-03-01", statuses: [.taken])
        let requestBefore = coordinator.promptRequest
        #expect(coordinator.hasPendingRequest)

        coordinator.resetForSignOut()
        #expect(!coordinator.hasPendingRequest)
        #expect(coordinator.promptRequest == requestBefore, "a rebuilt shell sees no new request")
        #expect(coordinator.state.capturedValues == 0)
        #expect(coordinator.state.streakDays == 0)
        #expect(coordinator.state.firstSeenAt == Date(timeIntervalSince1970: 1_800_000_000))

        // The old request cannot fire for the next account.
        clock.now = clock.now.addingTimeInterval(8 * 86400)
        #expect(coordinator.promptNow(moment: calm) == nil)
    }

    @Test("A state stored by the first version resets on sign-out without losing its pacing")
    func signOutUpdatePath() throws {
        let suite = "review-prompt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        // The exact shape the first version wrote: dates as reference-date seconds.
        let stored = """
        {"firstSeenAt":800000000,"capturedValues":14,"tenthValueUsed":true,"streakDays":5,\
        "lastAdherentDay":"2027-02-28","lastFlaggedCaptureAt":800100000,\
        "lastPromptAt":800200000,"promptedVersion":"1.5.1"}
        """
        defaults.set(Data(stored.utf8), forKey: ReviewPromptStateStore.key)

        let coordinator = ReviewPromptCoordinator(
            store: ReviewPromptStateStore(defaults: defaults),
            version: "1.6",
            clock: { Date(timeIntervalSinceReferenceDate: 800_300_000) }
        )
        #expect(coordinator.state.capturedValues == 14, "the stored state is read, not replaced")
        coordinator.resetForSignOut()
        let state = coordinator.state
        #expect(state.capturedValues == 0)
        #expect(!state.tenthValueUsed)
        #expect(state.streakDays == 0)
        #expect(state.lastAdherentDay == nil)
        #expect(state.lastFlaggedCaptureAt == nil)
        #expect(state.firstSeenAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(state.lastPromptAt == Date(timeIntervalSinceReferenceDate: 800_200_000))
        #expect(state.promptedVersion == "1.5.1")
    }

    @Test("A granted prompt is recorded, so the next calm moment stays quiet")
    func promptRecorded() {
        let clock = Clock()
        let (coordinator, _) = makeCoordinator(clock: clock)
        for _ in 0 ..< 10 {
            coordinator.recordCapture(flagged: false, savedOnServer: true)
        }
        #expect(coordinator.promptNow(moment: calm) == nil, "still in the first week")

        clock.now = clock.now.addingTimeInterval(8 * 86400)
        var busy = calm
        busy.isSheetPresented = true
        #expect(coordinator.promptNow(moment: busy) == nil)
        #expect(coordinator.state.lastPromptAt == nil, "a refused moment records nothing")
        #expect(coordinator.promptNow(moment: calm) == .tenthValue)
        #expect(coordinator.state.promptedVersion == "1.6")
        #expect(coordinator.promptNow(moment: calm) == nil)
    }
}

/// Pins who never sees the prompt.
@Suite("Review prompt environment")
struct ReviewPromptEnvironmentTests {
    @Test("The public demo, UI tests, and unit tests count as demo")
    func demo() {
        let own = URL(string: "https://health.example.org")
        #expect(ReviewPromptEnvironment.isDemo(baseURL: URL(string: "https://demo.healthlog.dev"), arguments: [], environment: [:]))
        #expect(ReviewPromptEnvironment.isDemo(baseURL: own, arguments: ["-uitest-hermetic"], environment: [:]))
        #expect(ReviewPromptEnvironment.isDemo(baseURL: own, arguments: [], environment: ["XCTestConfigurationFilePath": "x"]))
        #expect(!ReviewPromptEnvironment.isDemo(baseURL: own, arguments: ["-AppleLanguages"], environment: [:]))
        #expect(!ReviewPromptEnvironment.isDemo(baseURL: nil, arguments: [], environment: [:]))
    }

    @Test("Tabs with a router path are at their root only with an empty path")
    @MainActor
    func routerRoot() {
        let router = AppRouter()
        #expect(ReviewPromptEnvironment.routerSaysRoot(tab: .home, router: router) == true)
        #expect(ReviewPromptEnvironment.routerSaysRoot(tab: .meds, router: router) == true)
        #expect(ReviewPromptEnvironment.routerSaysRoot(tab: .more, router: router) == true)
        router.homePath.append("detail")
        #expect(ReviewPromptEnvironment.routerSaysRoot(tab: .home, router: router) == false)
        #expect(ReviewPromptEnvironment.routerSaysRoot(tab: .measure, router: router) == false)
        #expect(ReviewPromptEnvironment.routerSaysRoot(tab: .insights, router: router) == nil)
    }
}

/// Pins that the mood store reports each recorded mood exactly once, and
/// nothing that was rolled back.
@MainActor
@Suite("Review prompt mood hook")
struct ReviewPromptMoodHookTests {
    @Test("A queued mood reports once with its score, a rejected one not at all")
    func moodHook() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let store = MoodStore(repo: MoodRepository(api: api, outbox: outbox))
        var reported: [(Int, MedicationsStore.WriteOutcome)] = []
        store.onLogged = { reported.append(($0, $1)) }

        await api.setHandler { _ in throw HLError.server(status: 422, code: "BAD_REQUEST", message: "no") }
        _ = await store.logReturningOutcome(score: 4, tags: [], note: nil)
        #expect(reported.isEmpty)

        await api.setHandler { _ in throw HLError.offline }
        _ = await store.logReturningOutcome(score: 2, tags: [], note: nil)
        #expect(reported.count == 1)
        #expect(reported.first?.0 == 2)
        #expect(reported.first?.1 == .queued)
    }
}
