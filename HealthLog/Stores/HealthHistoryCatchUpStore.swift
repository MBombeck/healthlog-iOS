import Foundation
import Observation
#if canImport(UIKit)
    import UIKit
#endif

/// **"Sync everything now".**
///
/// The history walk runs on its own in leftover time and never holds new
/// readings back. Someone who wants the whole history on the server today can
/// ask for it here: the catch-up runs round after round while the app is open,
/// keeps the screen awake, and publishes progress after every round. Stopping
/// it (or iOS suspending the app) loses nothing: every accepted page stays
/// accepted and the next run, or the ordinary background walk, continues from
/// the persisted cursor.
///
/// Process-wide, so leaving the settings screen does not stop a run.
@MainActor
@Observable
final class HealthHistoryCatchUpStore {
    enum Phase: Equatable {
        case idle
        case running
        case finished
        case cancelled
        case stalled
        case unavailable
    }

    static let shared = HealthHistoryCatchUpStore()

    private(set) var phase: Phase = .idle
    private(set) var overview: HealthHistoryOverview?

    private let overviewSource: @Sendable () async -> HealthHistoryOverview?
    private let catchUp: @Sendable (@escaping @Sendable (HealthHistoryOverview) async -> Void) async
        -> HealthHistoryCatchUpOutcome
    private let keepAwake: @MainActor (Bool) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        overviewSource: @escaping @Sendable () async -> HealthHistoryOverview? = HealthHistoryCatchUpStore.liveOverview,
        catchUp: @escaping @Sendable (@escaping @Sendable (HealthHistoryOverview) async -> Void) async
            -> HealthHistoryCatchUpOutcome = HealthHistoryCatchUpStore.liveCatchUp,
        keepAwake: @escaping @MainActor (Bool) -> Void = HealthHistoryCatchUpStore.setIdleTimerDisabled
    ) {
        self.overviewSource = overviewSource
        self.catchUp = catchUp
        self.keepAwake = keepAwake
    }

    var isRunning: Bool {
        phase == .running
    }

    func refresh() async {
        guard !isRunning else { return }
        overview = await overviewSource()
    }

    /// Starts a run unless one is already going. Returns the task, so a test
    /// can await the end.
    @discardableResult
    func start() -> Task<Void, Never>? {
        guard task == nil else { return task }
        phase = .running
        keepAwake(true)
        let catchUp = catchUp
        // The store is main-actor bound (and process-wide), so holding it for
        // the length of one run is safe.
        let run = Task { [self] in
            let outcome = await catchUp { overview in
                await self.publish(overview)
            }
            finish(outcome)
        }
        task = run
        return run
    }

    func stop() {
        task?.cancel()
    }

    private func publish(_ overview: HealthHistoryOverview) {
        self.overview = overview
    }

    private func finish(_ outcome: HealthHistoryCatchUpOutcome) {
        task = nil
        keepAwake(false)
        phase = switch outcome {
        case .finished: .finished
        case .cancelled: .cancelled
        case .stalled: .stalled
        case .notAdmitted: .unavailable
        }
    }

    // MARK: - Live seams

    #if canImport(HealthKit) && canImport(SpeziHealthKit)
        nonisolated static let liveOverview: @Sendable () async -> HealthHistoryOverview? = {
            await AppOwnedHealthCollection.historyOverview()
        }

        nonisolated static let liveCatchUp: @Sendable (
            @escaping @Sendable (HealthHistoryOverview) async -> Void
        ) async -> HealthHistoryCatchUpOutcome = { progress in
            await AppOwnedHealthCollection.runFullCatchUp(progress: progress)
        }
    #else
        nonisolated static let liveOverview: @Sendable () async -> HealthHistoryOverview? = { nil }
        nonisolated static let liveCatchUp: @Sendable (
            @escaping @Sendable (HealthHistoryOverview) async -> Void
        ) async -> HealthHistoryCatchUpOutcome = { _ in .notAdmitted }
    #endif

    static func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}
