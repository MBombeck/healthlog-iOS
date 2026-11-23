import Foundation

/// What the review prompt remembers between launches. Counters and dates only,
/// never a health value.
struct ReviewPromptState: Codable, Equatable {
    /// First launch that knew about the prompt; the waiting period starts here.
    var firstSeenAt: Date?
    /// Measurements and moods recorded since then.
    var capturedValues = 0
    /// Whether the tenth value already led to a prompt.
    var tenthValueUsed = false
    /// Consecutive account days on which every scheduled dose was taken.
    var streakDays = 0
    /// The last such day, `yyyy-MM-dd` in the account zone.
    var lastAdherentDay: String?
    /// When a just-recorded value was out of range or could not be checked.
    var lastFlaggedCaptureAt: Date?
    var lastPromptAt: Date?
    var promptedVersion: String?
}

/// Why a prompt may be shown.
enum ReviewPromptTrigger: Equatable {
    case adherenceWeek
    case tenthValue
}

/// Where the user is when a prompt could appear. The defaults describe a
/// moment that is not calm, so a caller that forgets a field never opens one.
struct ReviewPromptMoment: Equatable {
    /// The app's scene is in the foreground and active; a dialog requested
    /// from the background or an inactive app is dropped by the system.
    var isForegroundActive = false
    var isDemo = false
    var isOffline = false
    var hasError = false
    var isInOnboarding = false
    var isInCoach = false
    var isSheetPresented = false
    /// A banner or toast sits over the tab, such as the undo pill.
    var hasOverlay = false
    var isAtTabRoot = false

    /// Nothing on screen that a system dialog would interrupt.
    var isCalm: Bool {
        isForegroundActive && isAtTabRoot && !isDemo && !isOffline && !hasError && !isInOnboarding && !isInCoach
            && !isSheetPresented && !hasOverlay
    }
}

/// What the shell can observe about the screen right now, before it is read
/// as a ``ReviewPromptMoment``. Plain values, so the reading is testable
/// without a window.
struct ReviewPromptObservation: Equatable {
    /// An active foreground scene with a key window exists.
    var hasActiveScene = false
    /// SwiftUI reports the scene phase as active.
    var scenePhaseIsActive = false
    /// Something is presented over the root controller.
    var hasPresentation = false
    /// The router's answer for the selected tab, `nil` when it keeps no path.
    var routerSaysRoot: Bool?
    /// The selected tab's navigation stack depth, `nil` when none was found.
    var stackIsAtRoot: Bool?
    var interfaceUp = false
    var serverAnswers = false
    var isDemo = false
    var hasOverlay = false

    var moment: ReviewPromptMoment {
        ReviewPromptMoment(
            isForegroundActive: hasActiveScene && scenePhaseIsActive,
            isDemo: isDemo,
            isOffline: !interfaceUp,
            hasError: interfaceUp && !serverAnswers,
            // The shell only exists after onboarding, and the coach is a sheet,
            // which the presentation check rules out.
            isInOnboarding: false,
            isInCoach: false,
            isSheetPresented: hasPresentation,
            hasOverlay: hasOverlay,
            isAtTabRoot: routerSaysRoot ?? stackIsAtRoot ?? false
        )
    }
}

/// One step of the shell's wait for a calm moment.
enum ReviewPromptWaitStep: Equatable {
    /// Calm now and at the previous look: show the dialog.
    case prompt
    /// The app is not active: stop and keep the request for the next activation.
    case suspend
    /// Look again; `calm` is what this look saw.
    case wait(calm: Bool)
}

/// **When the App Store review prompt may appear.**
///
/// Two moments of quiet success: a week in which every scheduled dose was
/// taken, and the tenth value recorded. Never right after a value that is out
/// of range, never mid-task, never in the demo, and rarely: once per version,
/// 120 days apart, not in the first week.
enum ReviewPromptPolicy {
    static let streakDaysNeeded = 7
    static let valuesNeeded = 10
    static let daysAfterFirstLaunch = 7
    static let daysBetweenPrompts = 120
    static let quietAfterFlaggedValue: TimeInterval = 24 * 60 * 60

    private static let day: TimeInterval = 24 * 60 * 60

    static func seen(_ state: ReviewPromptState, now: Date) -> ReviewPromptState {
        guard state.firstSeenAt == nil else { return state }
        var next = state
        next.firstSeenAt = now
        return next
    }

    /// A value was recorded. `flagged` when it is out of the user's range, a
    /// worrying mood, or could not be checked.
    static func recordingCapture(_ state: ReviewPromptState, flagged: Bool, now: Date) -> ReviewPromptState {
        var next = seen(state, now: now)
        next.capturedValues += 1
        if flagged { next.lastFlaggedCaptureAt = now }
        return next
    }

    /// The day's doses as the server lists them. Only a day with doses, all of
    /// them taken, extends the streak; a gap starts it over.
    ///
    /// Deliberately strict: a counted day is not taken back when a dose is later
    /// undone, and a day without any dose breaks the streak (a weekly-only
    /// medication never reaches seven). Both only mean fewer prompts.
    static func recordingDay(_ state: ReviewPromptState, day: String, statuses: [IntakeStatus]) -> ReviewPromptState {
        guard !statuses.isEmpty, statuses.allSatisfy({ $0 == .taken }) else { return state }
        guard state.lastAdherentDay != day else { return state }
        var next = state
        next.streakDays = state.lastAdherentDay == previousDay(of: day) ? state.streakDays + 1 : 1
        next.lastAdherentDay = day
        return next
    }

    /// The account day of `now` and the statuses of that day's doses. Rows the
    /// list still carries from another day are left out.
    static func today(
        _ intakes: [MedicationIntake],
        now: Date,
        timeZone: TimeZone
    ) -> (day: String, statuses: [IntakeStatus]) {
        let day = MedicationDayKey.string(for: now, timeZone: timeZone)
        let statuses = intakes
            .filter { MedicationDayKey.string(for: $0.scheduledAt, timeZone: timeZone) == day }
            .map(\.status)
        return (day, statuses)
    }

    /// Signing out ends what the counters describe; the pacing stays, since
    /// the system limits prompts per Apple ID and device anyway.
    static func signedOut(_ state: ReviewPromptState) -> ReviewPromptState {
        var next = ReviewPromptState()
        next.firstSeenAt = state.firstSeenAt
        next.lastPromptAt = state.lastPromptAt
        next.promptedVersion = state.promptedVersion
        return next
    }

    /// The shell's next step for a moment it just looked at.
    static func waitStep(_ moment: ReviewPromptMoment, wasCalm: Bool) -> ReviewPromptWaitStep {
        guard moment.isForegroundActive else { return .suspend }
        return moment.isCalm && wasCalm ? .prompt : .wait(calm: moment.isCalm)
    }

    static func trigger(for state: ReviewPromptState) -> ReviewPromptTrigger? {
        if state.streakDays >= streakDaysNeeded { return .adherenceWeek }
        if state.capturedValues >= valuesNeeded, !state.tenthValueUsed { return .tenthValue }
        return nil
    }

    /// The trigger to prompt for now, or `nil` when the moment or the pacing
    /// rules say no.
    static func promptNow(
        _ state: ReviewPromptState,
        moment: ReviewPromptMoment,
        version: String,
        now: Date
    ) -> ReviewPromptTrigger? {
        guard let trigger = trigger(for: state), moment.isCalm else { return nil }
        guard let firstSeenAt = state.firstSeenAt,
              now.timeIntervalSince(firstSeenAt) >= Double(daysAfterFirstLaunch) * day else { return nil }
        guard state.promptedVersion != version else { return nil }
        if let last = state.lastPromptAt, now.timeIntervalSince(last) < Double(daysBetweenPrompts) * day {
            return nil
        }
        if let flagged = state.lastFlaggedCaptureAt, now.timeIntervalSince(flagged) < quietAfterFlaggedValue {
            return nil
        }
        return trigger
    }

    /// The prompt went up: pace the next one and spend what led to it. A new
    /// streak has to be a full week again.
    static func prompted(_ state: ReviewPromptState, version: String, now: Date) -> ReviewPromptState {
        var next = state
        next.lastPromptAt = now
        next.promptedVersion = version
        next.streakDays = 0
        if state.capturedValues >= valuesNeeded { next.tenthValueUsed = true }
        return next
    }

    /// `yyyy-MM-dd` of the day before, or `nil` for a malformed key.
    static func previousDay(of key: String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendar.timeZone = utc
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let before = calendar.date(byAdding: .day, value: -1, to: date) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: before)
        guard let year = c.year, let month = c.month, let dayOfMonth = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
    }
}
