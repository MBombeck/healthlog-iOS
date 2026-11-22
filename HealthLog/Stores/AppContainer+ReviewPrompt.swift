import Foundation

extension AppContainer {
    /// Feeds recorded moods and the day's doses into the review prompt, and
    /// hands it the ranges measurements are checked against. Measurements are
    /// reported by the measure sheet and the watch capture. Chains onto the
    /// existing hooks; safe to call more than once.
    func wireReviewPrompt(_ coordinator: ReviewPromptCoordinator) {
        guard coordinator.wiredContainer != ObjectIdentifier(self) else { return }
        coordinator.wiredContainer = ObjectIdentifier(self)

        coordinator.ranges = serverStatsStores.userThresholds

        let previousMood = moodStore.onLogged
        moodStore.onLogged = { [weak coordinator] score, outcome in
            previousMood?(score, outcome)
            coordinator?.recordCapture(
                flagged: ReviewPromptCaptureCheck.isFlagged(moodScore: score),
                savedOnServer: outcome == .success
            )
        }

        let previousIntakes = medicationsStore.onIntakesDidChange
        medicationsStore.onIntakesDidChange = { [weak coordinator, weak medicationsStore] in
            previousIntakes?()
            guard let coordinator, let medicationsStore else { return }
            let today = ReviewPromptPolicy.today(
                medicationsStore.todayIntakes,
                now: coordinator.now,
                timeZone: medicationsStore.profileTimeZone
            )
            coordinator.recordDay(today.day, statuses: today.statuses)
        }
    }
}
