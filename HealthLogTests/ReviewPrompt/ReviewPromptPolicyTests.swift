import Foundation
@testable import HealthLog
import Testing

/// Pins when the App Store review prompt may appear.
@Suite("Review prompt policy")
struct ReviewPromptPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    /// Active app, on a tab root, nothing in the way.
    private let calm = ReviewPromptMoment(isForegroundActive: true, isAtTabRoot: true)
    private let day: TimeInterval = 24 * 60 * 60

    private func days(_ count: Double) -> Date {
        start.addingTimeInterval(count * day)
    }

    /// Seen on `start`, ten clean values recorded.
    private var tenValues: ReviewPromptState {
        var state = ReviewPromptPolicy.seen(ReviewPromptState(), now: start)
        for _ in 0 ..< 10 {
            state = ReviewPromptPolicy.recordingCapture(state, flagged: false, now: start)
        }
        return state
    }

    private func adherentWeek(endingOn last: Int = 7) -> ReviewPromptState {
        var state = ReviewPromptPolicy.seen(ReviewPromptState(), now: start)
        for dayOfMonth in (last - 6) ... last {
            state = ReviewPromptPolicy.recordingDay(
                state,
                day: String(format: "2027-03-%02d", dayOfMonth),
                statuses: [.taken, .taken]
            )
        }
        return state
    }

    // MARK: Triggers

    @Test("The tenth value arms the prompt, the ninth does not")
    func tenthValue() {
        var state = ReviewPromptPolicy.seen(ReviewPromptState(), now: start)
        for _ in 0 ..< 9 {
            state = ReviewPromptPolicy.recordingCapture(state, flagged: false, now: start)
        }
        #expect(ReviewPromptPolicy.trigger(for: state) == nil)
        state = ReviewPromptPolicy.recordingCapture(state, flagged: false, now: start)
        #expect(ReviewPromptPolicy.trigger(for: state) == .tenthValue)
    }

    @Test("Seven consecutive days with every dose taken arm the prompt")
    func adherenceWeek() {
        #expect(ReviewPromptPolicy.trigger(for: adherentWeek()) == .adherenceWeek)
        #expect(adherentWeek().streakDays == 7)
    }

    @Test("Six days are not a week")
    func sixDays() {
        var state = ReviewPromptState()
        for dayOfMonth in 1 ... 6 {
            state = ReviewPromptPolicy.recordingDay(state, day: "2027-03-0\(dayOfMonth)", statuses: [.taken])
        }
        #expect(state.streakDays == 6)
        #expect(ReviewPromptPolicy.trigger(for: state) == nil)
    }

    @Test("A gap day starts the streak over")
    func gapResets() {
        var state = ReviewPromptPolicy.recordingDay(ReviewPromptState(), day: "2027-03-01", statuses: [.taken])
        state = ReviewPromptPolicy.recordingDay(state, day: "2027-03-02", statuses: [.taken])
        state = ReviewPromptPolicy.recordingDay(state, day: "2027-03-04", statuses: [.taken])
        #expect(state.streakDays == 1)
    }

    @Test("A day with an open, skipped, or missed dose, or no dose at all, does not count")
    func incompleteDays() {
        let base = ReviewPromptState()
        for statuses: [IntakeStatus] in [[], [.taken, .pending], [.taken, .skipped], [.missed], [.snoozed]] {
            #expect(ReviewPromptPolicy.recordingDay(base, day: "2027-03-01", statuses: statuses) == base)
        }
    }

    @Test("The same day reported twice counts once")
    func sameDayOnce() {
        let once = ReviewPromptPolicy.recordingDay(ReviewPromptState(), day: "2027-03-01", statuses: [.taken])
        #expect(ReviewPromptPolicy.recordingDay(once, day: "2027-03-01", statuses: [.taken]) == once)
    }

    @Test("Streaks carry across month and year ends")
    func previousDay() {
        #expect(ReviewPromptPolicy.previousDay(of: "2027-03-01") == "2027-02-28")
        #expect(ReviewPromptPolicy.previousDay(of: "2028-03-01") == "2028-02-29")
        #expect(ReviewPromptPolicy.previousDay(of: "2027-01-01") == "2026-12-31")
        #expect(ReviewPromptPolicy.previousDay(of: "garbage") == nil)
    }

    // MARK: Moment

    @Test("Each unsettled moment blocks the prompt")
    func momentBlocks() {
        let unsettle: [(inout ReviewPromptMoment) -> Void] = [
            { $0.isForegroundActive = false },
            { $0.isDemo = true },
            { $0.isOffline = true },
            { $0.hasError = true },
            { $0.isInOnboarding = true },
            { $0.isInCoach = true },
            { $0.isSheetPresented = true },
            { $0.hasOverlay = true },
            { $0.isAtTabRoot = false }
        ]
        #expect(calm.isCalm)
        for change in unsettle {
            var moment = calm
            change(&moment)
            #expect(!moment.isCalm)
            #expect(ReviewPromptPolicy.promptNow(tenValues, moment: moment, version: "1.6", now: days(8)) == nil)
        }
    }

    @Test("A moment built without arguments is not calm")
    func defaultMomentNotCalm() {
        #expect(!ReviewPromptMoment().isCalm)
    }

    // MARK: Observation

    private var settled: ReviewPromptObservation {
        ReviewPromptObservation(
            hasActiveScene: true,
            scenePhaseIsActive: true,
            routerSaysRoot: true,
            interfaceUp: true,
            serverAnswers: true
        )
    }

    @Test("Without an active foreground scene the moment is not calm")
    func noActiveScene() {
        #expect(settled.moment.isCalm)
        var noScene = settled
        noScene.hasActiveScene = false
        #expect(!noScene.moment.isCalm)
        #expect(!noScene.moment.isForegroundActive)
        var inactive = settled
        inactive.scenePhaseIsActive = false
        #expect(!inactive.moment.isCalm)
    }

    @Test("Presentation, banners, offline, and an unanswered server each keep it unsettled")
    func observationBlocks() {
        var presented = settled
        presented.hasPresentation = true
        #expect(presented.moment.isSheetPresented && !presented.moment.isCalm)
        var overlay = settled
        overlay.hasOverlay = true
        #expect(!overlay.moment.isCalm)
        var offline = settled
        offline.interfaceUp = false
        #expect(offline.moment.isOffline && !offline.moment.hasError)
        var silent = settled
        silent.serverAnswers = false
        #expect(silent.moment.hasError && !silent.moment.isOffline)
        var demo = settled
        demo.isDemo = true
        #expect(!demo.moment.isCalm)
    }

    @Test("The router decides the root where it keeps a path, the stack where it does not, else not root")
    func rootSources() {
        var stack = settled
        stack.routerSaysRoot = nil
        stack.stackIsAtRoot = true
        #expect(stack.moment.isAtTabRoot)
        stack.stackIsAtRoot = false
        #expect(!stack.moment.isAtTabRoot)
        stack.stackIsAtRoot = nil
        #expect(!stack.moment.isAtTabRoot)
        var router = settled
        router.routerSaysRoot = false
        router.stackIsAtRoot = true
        #expect(!router.moment.isAtTabRoot)
    }

    // MARK: Waiting

    @Test("The wait suspends outside the active app and prompts only on a second calm look")
    func waitSteps() {
        var background = calm
        background.isForegroundActive = false
        #expect(ReviewPromptPolicy.waitStep(background, wasCalm: true) == .suspend)
        #expect(ReviewPromptPolicy.waitStep(calm, wasCalm: false) == .wait(calm: true))
        #expect(ReviewPromptPolicy.waitStep(calm, wasCalm: true) == .prompt)
        var busy = calm
        busy.isSheetPresented = true
        #expect(ReviewPromptPolicy.waitStep(busy, wasCalm: true) == .wait(calm: false))
    }

    // MARK: Pacing

    @Test("Not in the first week after the first launch")
    func firstWeek() {
        #expect(ReviewPromptPolicy.promptNow(tenValues, moment: calm, version: "1.6", now: days(6.9)) == nil)
        #expect(ReviewPromptPolicy.promptNow(tenValues, moment: calm, version: "1.6", now: days(7)) == .tenthValue)
    }

    @Test("Without a first-launch date nothing is shown")
    func noFirstSeen() {
        var state = tenValues
        state.firstSeenAt = nil
        #expect(ReviewPromptPolicy.promptNow(state, moment: calm, version: "1.6", now: days(30)) == nil)
    }

    @Test("Not within a day of a flagged value")
    func quietAfterFlaggedValue() {
        let flagged = ReviewPromptPolicy.recordingCapture(tenValues, flagged: true, now: days(10))
        #expect(flagged.capturedValues == 11)
        #expect(ReviewPromptPolicy.promptNow(flagged, moment: calm, version: "1.6", now: days(10.5)) == nil)
        #expect(ReviewPromptPolicy.promptNow(flagged, moment: calm, version: "1.6", now: days(11)) == .tenthValue)
    }

    @Test("Once per version and 120 days apart")
    func pacing() {
        let shown = ReviewPromptPolicy.prompted(tenValues, version: "1.6", now: days(8))
        var armed = shown
        armed.streakDays = 7
        #expect(ReviewPromptPolicy.promptNow(armed, moment: calm, version: "1.6", now: days(300)) == nil)
        #expect(ReviewPromptPolicy.promptNow(armed, moment: calm, version: "1.7", now: days(127)) == nil)
        #expect(ReviewPromptPolicy.promptNow(armed, moment: calm, version: "1.7", now: days(128)) == .adherenceWeek)
    }

    @Test("Prompting spends the tenth value and the streak")
    func promptingSpendsTriggers() {
        let shown = ReviewPromptPolicy.prompted(tenValues, version: "1.6", now: days(8))
        #expect(shown.tenthValueUsed)
        #expect(shown.streakDays == 0)
        #expect(shown.promptedVersion == "1.6")
        #expect(shown.lastPromptAt == days(8))
        #expect(ReviewPromptPolicy.trigger(for: shown) == nil)
    }

    @Test("Signing out clears the counters and keeps the pacing")
    func signOut() {
        var state = ReviewPromptPolicy.prompted(tenValues, version: "1.6", now: days(8))
        state = ReviewPromptPolicy.recordingCapture(state, flagged: true, now: days(9))
        state = ReviewPromptPolicy.recordingDay(state, day: "2027-03-01", statuses: [.taken])
        let out = ReviewPromptPolicy.signedOut(state)
        #expect(out.capturedValues == 0)
        #expect(out.streakDays == 0)
        #expect(out.lastAdherentDay == nil)
        #expect(out.lastFlaggedCaptureAt == nil)
        #expect(!out.tenthValueUsed)
        #expect(out.firstSeenAt == start)
        #expect(out.lastPromptAt == days(8))
        #expect(out.promptedVersion == "1.6")
    }

    @Test("The account day is cut in the profile zone, and rows from another day are left out")
    func todayInProfileZone() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        // 23:15 UTC on 1 March is 00:15 on 2 March in Berlin.
        let now = Date(timeIntervalSince1970: 1_803_942_900)
        let lateEvening = now.addingTimeInterval(-3600)
        let afterMidnight = now.addingTimeInterval(1800)
        let intakes = [
            MedicationIntake(id: "a", medicationId: "m", scheduledAt: lateEvening, takenAt: nil, status: .pending),
            MedicationIntake(id: "b", medicationId: "m", scheduledAt: afterMidnight, takenAt: now, status: .taken)
        ]
        let inBerlin = ReviewPromptPolicy.today(intakes, now: now, timeZone: berlin)
        #expect(inBerlin.day == "2027-03-02")
        #expect(inBerlin.statuses == [.taken])
        let inUTC = ReviewPromptPolicy.today(intakes, now: now, timeZone: utc)
        #expect(inUTC.day == "2027-03-01")
        #expect(inUTC.statuses == [.pending, .taken])
    }

    @Test("The first-launch date is set once")
    func seenOnce() {
        let first = ReviewPromptPolicy.seen(ReviewPromptState(), now: start)
        #expect(ReviewPromptPolicy.seen(first, now: days(3)).firstSeenAt == start)
    }

    @Test("The stored state holds counters and dates only")
    func stateShape() throws {
        let data = try JSONEncoder().encode(adherentWeek())
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys).isSubset(of: [
            "firstSeenAt", "capturedValues", "tenthValueUsed", "streakDays", "lastAdherentDay",
            "lastFlaggedCaptureAt", "lastPromptAt", "promptedVersion"
        ]))
    }
}
