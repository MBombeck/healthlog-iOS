@testable import HealthLog
import Testing

/// #115 · 1.1 T1 — the ordering rules behind the 286 "+"-crash fix.
///
/// TestFlight 1.1.0 (286) aborted in `SheetBridge.present(…isPreempting:)`: a
/// shell sheet was raised while another presentation was still on the window's
/// root controller, and SwiftUI's animated preemption ran a zoom morph from a
/// source that could no longer produce one. `ShellSheetGate` is the single owner
/// of "which shell sheet is up"; these cases pin that it never hands out a second
/// sheet while one is presented or animating out, that a "+" re-tap is dropped,
/// and that a parked request comes back exactly once the stage is free.
@Suite("Shell sheet gate (T1)")
struct ShellSheetGateTests {
    @Test("An idle stage presents at once and holds the sheet as active")
    func idlePresents() {
        var gate = ShellSheetGate()
        #expect(gate.request(.capturePicker) == .present(.capturePicker))
        #expect(gate.active == .capturePicker)
        #expect(!gate.isIdle)
    }

    @Test("A request while a sheet is up is parked, never presented over it")
    func busyStageParks() {
        var gate = ShellSheetGate()
        _ = gate.request(.measure)
        #expect(gate.request(.mood) == .deferred)
        #expect(gate.active == .measure)
        #expect(gate.queued == .mood)
    }

    @Test("The parked request presents only once the current sheet finished dismissing")
    func parkedRequestResumesOnDismiss() {
        var gate = ShellSheetGate()
        _ = gate.request(.measure)
        _ = gate.request(.medicationQuickIntake)
        #expect(gate.didDismiss(.measure) == .medicationQuickIntake)
        #expect(gate.active == .medicationQuickIntake)
        #expect(gate.queued == nil)
        #expect(gate.didDismiss(.medicationQuickIntake) == nil)
        #expect(gate.isIdle)
    }

    @Test("A '+' re-tap while the capture picker is up or animating is dropped")
    func captureRetapIgnored() {
        var gate = ShellSheetGate()
        _ = gate.request(.capturePicker)
        #expect(gate.request(.capturePicker) == .ignored)
        #expect(gate.request(.capturePicker) == .ignored)
        #expect(gate.queued == nil)
    }

    @Test("A '+' tap while a follow-up sheet is up does not preempt it")
    func captureOverFollowUpIgnored() {
        var gate = ShellSheetGate()
        _ = gate.request(.mood)
        #expect(gate.request(.capturePicker) == .ignored)
        #expect(gate.active == .mood)
    }

    @Test("A '+' tap while a staged follow-up waits for the picker cannot jump the queue")
    func captureBehindStagedHandOffIgnored() {
        var gate = ShellSheetGate()
        _ = gate.request(.capturePicker)
        #expect(gate.request(.measure) == .deferred)
        #expect(gate.request(.capturePicker) == .ignored)
        #expect(gate.didDismiss(.capturePicker) == .measure)
    }

    @Test("The staged capture hand-off presents its sheet after the picker's onDismiss")
    func stagedHandOff() {
        var gate = ShellSheetGate()
        _ = gate.request(.capturePicker)
        #expect(gate.request(.cycle) == .deferred)
        #expect(gate.active == .capturePicker)
        #expect(gate.didDismiss(.capturePicker) == .cycle)
    }

    @Test("Only the latest parked request survives")
    func latestParkedWins() {
        var gate = ShellSheetGate()
        _ = gate.request(.measure)
        _ = gate.request(.mood)
        _ = gate.request(.measurePrefill(.weight))
        #expect(gate.didDismiss(.measure) == .measurePrefill(.weight))
    }

    @Test("A dismissal of a sheet that is not the active one releases nothing")
    func foreignDismissIgnored() {
        var gate = ShellSheetGate()
        _ = gate.request(.measure)
        _ = gate.request(.mood)
        #expect(gate.didDismiss(.capturePicker) == nil)
        #expect(gate.active == .measure)
        #expect(gate.queued == .mood)
    }

    @Test("Prefill requests of any kind share one sheet slot")
    func prefillSharesSlot() {
        var gate = ShellSheetGate()
        _ = gate.request(.measurePrefill(.bloodPressure))
        #expect(gate.didDismiss(.measurePrefill) == nil)
        #expect(gate.isIdle)
    }

    @Test("An occupied stage outside the gate (consent sheet) parks requests until it resumes")
    func blockedStageParksUntilResume() {
        var gate = ShellSheetGate()
        #expect(gate.request(.mood, blocked: true) == .deferred)
        #expect(gate.request(.capturePicker, blocked: true) == .ignored)
        #expect(gate.resume(blocked: true) == nil)
        #expect(gate.resume() == .mood)
        #expect(gate.active == .mood)
    }

    @Test("A sheet that finishes dismissing while the consent sheet holds the stage keeps the next one parked")
    func dismissWhileBlockedKeepsParked() {
        var gate = ShellSheetGate()
        _ = gate.request(.measure)
        _ = gate.request(.mood)
        #expect(gate.didDismiss(.measure, blocked: true) == nil)
        #expect(gate.active == nil)
        #expect(gate.queued == .mood)
        #expect(gate.resume() == .mood)
    }

    @Test(
        "Stage plan: clear animates, a settled foreign presentation is preempted without animation, a transition waits",
        arguments: [
            (false, false, ShellPresentationStage.Plan.presentAnimated),
            (true, false, .presentWithoutAnimation),
            (true, true, .wait),
            (false, true, .wait)
        ]
    )
    func stagePlan(hasPresented: Bool, isTransitioning: Bool, expected: ShellPresentationStage.Plan) {
        let stage = ShellPresentationStage.classify(hasPresented: hasPresented, isTransitioning: isTransitioning)
        #expect(stage.plan == expected)
    }
}
