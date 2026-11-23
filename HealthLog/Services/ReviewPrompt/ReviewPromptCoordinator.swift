import Foundation
import Observation

/// Persists ``ReviewPromptState`` in `UserDefaults`.
struct ReviewPromptStateStore {
    static let key = "dev.healthlog.reviewPrompt.state"

    let defaults: UserDefaults

    func read() -> ReviewPromptState {
        guard let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(ReviewPromptState.self, from: data) else { return ReviewPromptState() }
        return state
    }

    func write(_ state: ReviewPromptState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The user's ranges, as the review prompt needs them.
@MainActor
protocol ReviewPromptRangeSource: AnyObject {
    var hasLoadedRanges: Bool { get }
    func loadRanges() async
    func band(for metric: ThresholdMetric) -> ThresholdRange?
}

extension UserThresholdsStore: ReviewPromptRangeSource {
    var hasLoadedRanges: Bool {
        lastLoadedAt != nil
    }

    func loadRanges() async {
        await load()
    }
}

/// **Feeds the review-prompt policy and tells the shell when to look.**
///
/// The stores report recorded values and the day's doses; the coordinator
/// keeps the counters and raises ``hasPendingRequest`` (and bumps
/// ``promptRequest``) when a trigger is armed after a clean save. The shell
/// then waits until the user is back on a tab root of the active app and asks
/// ``promptNow(moment:)`` before showing the system dialog.
@MainActor
@Observable
final class ReviewPromptCoordinator {
    static let live = ReviewPromptCoordinator(
        store: ReviewPromptStateStore(defaults: .standard),
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    )

    /// Bumped with every new request, so the shell's wait restarts.
    private(set) var promptRequest = 0
    /// A request is waiting for a calm moment. It survives the app going to
    /// the background and ends when the dialog is shown, when the user stays
    /// busy in the active app for the whole wait, or on sign-out.
    private(set) var hasPendingRequest = false

    @ObservationIgnored private let store: ReviewPromptStateStore
    @ObservationIgnored private let version: String
    @ObservationIgnored private let clock: () -> Date
    /// The container whose stores report here, so a rebuilt container is
    /// wired once more and the same one never twice.
    @ObservationIgnored var wiredContainer: ObjectIdentifier?
    /// The user's ranges, which a recorded measurement is checked against.
    @ObservationIgnored weak var ranges: (any ReviewPromptRangeSource)?

    init(store: ReviewPromptStateStore, version: String, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.version = version
        self.clock = clock
        store.write(ReviewPromptPolicy.seen(store.read(), now: clock()))
    }

    var state: ReviewPromptState {
        store.read()
    }

    /// The coordinator's clock, so the account day is cut on the same time
    /// the counters use.
    var now: Date {
        clock()
    }

    /// A measurement or mood was recorded. Only a save the server confirmed
    /// asks for a prompt; a queued or failed one is not a calm moment.
    func recordCapture(flagged: Bool, savedOnServer: Bool) {
        let next = ReviewPromptPolicy.recordingCapture(store.read(), flagged: flagged, now: clock())
        store.write(next)
        if savedOnServer, !flagged { requestIfArmed(next) }
    }

    /// A measurement left the measure sheet or the watch. A failed write counts
    /// for nothing; a queued one counts but never asks for a prompt. When the
    /// ranges still have to load, the value is marked flagged at once and the
    /// mark is taken back only once the check passed, so a wait that is
    /// already running never sees an unchecked value as calm.
    func noteMeasurement(
        kind: MetricKind,
        value: MeasurementValue,
        glucoseContext: GlucoseContext?,
        outcome: MedicationsStore.WriteOutcome
    ) {
        guard outcome.didLand else { return }
        let measurement = Measurement(
            id: "review-check",
            kind: kind,
            recordedAt: clock(),
            value: value,
            glucoseContext: glucoseContext
        )
        let provisional = markProvisionally(measurement)
        Task { await finishMeasurement(measurement, savedOnServer: outcome == .success, provisional: provisional) }
    }

    func recordMeasurement(_ measurement: Measurement, savedOnServer: Bool) async {
        let provisional = markProvisionally(measurement)
        await finishMeasurement(measurement, savedOnServer: savedOnServer, provisional: provisional)
    }

    /// The day's dose list changed.
    func recordDay(_ day: String, statuses: [IntakeStatus]) {
        let before = store.read()
        let next = ReviewPromptPolicy.recordingDay(before, day: day, statuses: statuses)
        guard next != before else { return }
        store.write(next)
        requestIfArmed(next)
    }

    /// The trigger to show the dialog for now, recorded as shown; `nil` when
    /// this is not the moment.
    func promptNow(moment: ReviewPromptMoment) -> ReviewPromptTrigger? {
        let now = clock()
        let current = store.read()
        guard let trigger = ReviewPromptPolicy.promptNow(current, moment: moment, version: version, now: now) else {
            return nil
        }
        store.write(ReviewPromptPolicy.prompted(current, version: version, now: now))
        hasPendingRequest = false
        return trigger
    }

    /// The user stayed busy in the active app for the whole wait; the next
    /// recorded value asks again.
    func dropRequest() {
        hasPendingRequest = false
    }

    /// Sign-out: the counters describe the account that left, the pacing
    /// stays, and a request still waiting must not fire for the next account.
    func resetForSignOut() {
        store.write(ReviewPromptPolicy.signedOut(store.read()))
        hasPendingRequest = false
    }

    private func requestIfArmed(_ state: ReviewPromptState) {
        guard ReviewPromptPolicy.trigger(for: state) != nil else { return }
        hasPendingRequest = true
        promptRequest += 1
    }

    private struct ProvisionalMark {
        let mark: Date
        let previous: Date?
    }

    private func markProvisionally(_ measurement: Measurement) -> ProvisionalMark? {
        guard let ranges, !ranges.hasLoadedRanges,
              ReviewPromptCaptureCheck.rangeChecks(for: measurement) != nil else { return nil }
        var current = store.read()
        let mark = ProvisionalMark(mark: clock(), previous: current.lastFlaggedCaptureAt)
        current.lastFlaggedCaptureAt = mark.mark
        store.write(current)
        return mark
    }

    private func finishMeasurement(_ measurement: Measurement, savedOnServer: Bool, provisional: ProvisionalMark?) async {
        if provisional != nil { await ranges?.loadRanges() }
        let flagged = ReviewPromptCaptureCheck.isFlagged(measurement) { [ranges] in ranges?.band(for: $0) }
        if let provisional, !flagged {
            var current = store.read()
            if current.lastFlaggedCaptureAt == provisional.mark {
                current.lastFlaggedCaptureAt = provisional.previous
                store.write(current)
            }
        }
        recordCapture(flagged: flagged, savedOnServer: savedOnServer)
    }
}
