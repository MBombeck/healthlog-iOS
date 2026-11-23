#if canImport(ActivityKit)

    import Foundation
    @testable import HealthLog
    import Testing

    /// A Live Activity names one slot for its whole life. Two doses of the same
    /// medication on one day must therefore never share an Activity, and the
    /// "Taken" button must only ever claim a dose that was recorded.
    @Suite("Live Activity slot binding and honest confirmation")
    struct MedicationLiveActivitySlotTests {
        private let morning = Date(timeIntervalSince1970: 1_800_000_000)
        private var noon: Date {
            morning.addingTimeInterval(4 * 60 * 60)
        }

        // MARK: - Slot decision

        @Test("a running Activity for the same slot is reused")
        func sameSlotReuses() {
            let running = [MedicationLiveActivityPlan.RunningSlot(id: "a", slot: morning, isLive: true)]
            #expect(
                MedicationLiveActivityPlan.slotDecision(running: running, requestedSlot: morning)
                    == .reuse(id: "a", end: [])
            )
        }

        @Test("08:00 still running when 12:00 is due → the 08:00 Activity ends, a new one is requested")
        func laterSlotReplaces() {
            let running = [MedicationLiveActivityPlan.RunningSlot(id: "a", slot: morning, isLive: true)]
            #expect(
                MedicationLiveActivityPlan.slotDecision(running: running, requestedSlot: noon)
                    == .request(end: ["a"])
            )
        }

        @Test("an ended Activity that still lingers is neither reused nor ended again")
        func endedIsIgnored() {
            let running = [MedicationLiveActivityPlan.RunningSlot(id: "a", slot: noon, isLive: false)]
            #expect(
                MedicationLiveActivityPlan.slotDecision(running: running, requestedSlot: noon)
                    == .request(end: [])
            )
        }

        @Test("a stray second Activity of the medication ends when the matching one is reused")
        func duplicatesEnd() {
            let running = [
                MedicationLiveActivityPlan.RunningSlot(id: "old", slot: morning, isLive: true),
                MedicationLiveActivityPlan.RunningSlot(id: "current", slot: noon, isLive: true)
            ]
            #expect(
                MedicationLiveActivityPlan.slotDecision(running: running, requestedSlot: noon)
                    == .reuse(id: "current", end: ["old"])
            )
        }

        @Test("sub-second drift from the intent parameter still names the same slot")
        func driftWithinASecond() {
            let running = [MedicationLiveActivityPlan.RunningSlot(id: "a", slot: noon, isLive: true)]
            #expect(
                MedicationLiveActivityPlan.slotDecision(running: running, requestedSlot: noon.addingTimeInterval(0.4))
                    == .reuse(id: "a", end: [])
            )
        }

        // MARK: - Confirmation

        @Test("a landed write keeps the check")
        func landedIsRecorded() {
            #expect(MarkDoseFromLiveActivityIntent.commitOutcome(signedIn: true, error: nil) == .recorded)
        }

        @Test("a write queued on the outbox keeps the check")
        func queuedIsRecorded() {
            #expect(MarkDoseFromLiveActivityIntent.commitOutcome(signedIn: true, error: HLError.offline) == .recorded)
        }

        @Test("signed out or a non-retriable failure takes the check back")
        func failureIsNotRecorded() {
            #expect(MarkDoseFromLiveActivityIntent.commitOutcome(signedIn: false, error: nil) == .notRecorded)
            let refused = HLError.server(status: 422, code: "x", message: "no")
            #expect(MarkDoseFromLiveActivityIntent.commitOutcome(signedIn: true, error: refused) == .notRecorded)
        }

        @Test("the reverted state is the plain pending button")
        func revertedState() {
            var confirming = MedicationActivityAttributes.ContentState(status: .taken, countdownTarget: noon)
            confirming.confirmed = true
            confirming.pendingConfirm = true
            confirming.pendingConfirmStartedAt = noon
            let reverted = MarkDoseFromLiveActivityIntent.reverted(from: confirming)
            #expect(reverted.status == .pending)
            #expect(!reverted.confirmed)
            #expect(!reverted.pendingConfirm)
            #expect(reverted.pendingConfirmStartedAt == nil)
            #expect(reverted.countdownTarget == noon)
        }
    }

#endif
