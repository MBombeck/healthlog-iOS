import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The fixed rules of a sheet's bar and of the action behind its confirm
/// button. The bar itself is system chrome; what it shows and when it acts is
/// decided by the values checked here.
@MainActor
@Suite("Sheet scaffold: bar rules and action")
struct HLSheetScaffoldContractTests {
    /// Counts what an action did, on the actor the scaffold runs it on.
    @MainActor
    private final class Log {
        var runs = 0
    }

    @Test("each action names its kind")
    func kinds() {
        #expect(HLSheetAction.none.kind == .closeOnly)
        #expect(HLSheetAction.save { true }.kind == .save)
        #expect(HLSheetAction.add { true }.kind == .add)
        #expect(HLSheetAction.done().kind == .done)
        #expect(HLSheetAction.confirm("Send") { true }.kind == .confirm)
        #expect(HLSheetAction.confirm("Send", isEnabled: false) { true }.isEnabled == false)
        #expect(HLSheetAction.save(isEnabled: false) { true }.isEnabled == false)
        #expect(HLSheetAction.none.isEnabled)
    }

    @Test("every sheet leaves through the cross; a sheet whose changes hold has no check mark")
    func closeButton() {
        #expect(HLSheetBar.showsClose(for: .closeOnly))
        #expect(HLSheetBar.showsClose(for: .save))
        #expect(HLSheetBar.showsClose(for: .add))
        #expect(HLSheetBar.showsClose(for: .confirm))
        #expect(HLSheetBar.showsClose(for: .done))
        #expect(HLSheetBar.closeWord(for: .done) == .close)
        #expect(!HLSheetBar.showsConfirm(for: .done))
        #expect(!HLSheetBar.showsConfirm(for: .closeOnly))
        #expect(HLSheetBar.showsConfirm(for: .save))
        #expect(HLSheetBar.showsConfirm(for: .add))
        #expect(HLSheetBar.showsConfirm(for: .confirm))
    }

    @Test("the leading button cancels a form and closes everything else")
    func closeWord() {
        #expect(HLSheetBar.closeWord(for: .save) == .cancel)
        #expect(HLSheetBar.closeWord(for: .add) == .cancel)
        #expect(HLSheetBar.closeWord(for: .confirm) == .cancel)
        #expect(HLSheetBar.closeWord(for: .closeOnly) == .close)
    }

    @Test("the trailing button is spoken with the control word of its kind")
    func confirmWord() {
        #expect(HLSheetBar.confirmWord(for: .closeOnly) == nil)
        #expect(HLSheetBar.confirmWord(for: .save) == .save)
        #expect(HLSheetBar.confirmWord(for: .add) == .add)
        #expect(HLSheetBar.confirmWord(for: .done) == nil)
        #expect(HLSheetBar.confirmWord(for: .confirm) == nil, "a word of its own has no fixed control word")
    }

    @Test("the confirm button is spoken with the word of its action")
    func confirmLabel() {
        #expect(HLSheetAction.none.confirmLabel == nil)
        #expect(HLSheetAction.save { true }.confirmLabel == HLControlWord.save.text)
        #expect(HLSheetAction.add { true }.confirmLabel == HLControlWord.add.text)
        #expect(HLSheetAction.done().confirmLabel == nil, "Done closes with the cross, no check mark")

        let send = HLSheetAction.confirm("Send") { true }
        #expect(send.confirmLabel == Text("Send"))
        #expect(send.confirmLabel != HLControlWord.save.text, "a sheet that sends is still spoken as Save")
    }

    @Test("an action with its own word runs like a save")
    func confirmRuns() async {
        let log = Log()
        let runner = HLSheetActionRunner()
        let action = HLSheetAction.confirm("Send") {
            log.runs += 1
            return true
        }
        #expect(await runner.run(action))
        #expect(log.runs == 1)
    }

    @Test("closing asks first only when input would be lost")
    func discardQuestion() {
        #expect(HLSheetBar.closeAsksFirst(isDirty: true))
        #expect(!HLSheetBar.closeAsksFirst(isDirty: false))
    }

    @Test("the result of the action decides whether the sheet may close")
    func runnerReportsResult() async {
        let runner = HLSheetActionRunner()
        #expect(await runner.run(.save { true }))
        #expect(await runner.run(.save { false }) == false)
        #expect(!runner.isRunning)
    }

    @Test("a disabled action does not run")
    func disabledActionDoesNotRun() async {
        let log = Log()
        let runner = HLSheetActionRunner()
        let action = HLSheetAction.add(isEnabled: false) {
            log.runs += 1
            return true
        }
        #expect(await runner.run(action) == false)
        #expect(log.runs == 0)
    }

    @Test("Done runs its closure and lets the sheet close")
    func doneRuns() async {
        let log = Log()
        let runner = HLSheetActionRunner()
        #expect(await runner.run(.done { log.runs += 1 }))
        #expect(log.runs == 1)
    }

    @Test("a second tap during a save does not save twice")
    func oneRunAtATime() async {
        let log = Log()
        let runner = HLSheetActionRunner()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let action = HLSheetAction.save {
            log.runs += 1
            for await _ in gate {
                break
            }
            return true
        }

        let first = Task { @MainActor in await runner.run(action) }
        // Let the first run reach the point where it waits.
        for _ in 0 ..< 1000 where !runner.isRunning {
            await Task.yield()
        }
        #expect(runner.isRunning)

        #expect(await runner.run(action) == false, "the second tap went through")
        #expect(log.runs == 1)

        open.yield()
        open.finish()
        #expect(await first.value)
        #expect(!runner.isRunning)
        #expect(log.runs == 1)
    }

    // MARK: - Identifiers

    @Test("close and confirm carry an identifier on every sheet")
    func barIdentifiers() {
        let sheet = HLSheetScaffold("Add medication", action: .add { true }) { EmptyView() }
        #expect(sheet.closeIdentifier == "hl.sheet.close")
        #expect(sheet.confirmIdentifier == "hl.sheet.confirm")
        #expect(HLSheetBar.closeIdentifier != HLSheetBar.confirmIdentifier)
    }

    @Test("a sheet keeps the identifiers its tests already know")
    func ownIdentifiers() {
        let sheet = HLSheetScaffold(
            "Your new token",
            action: .done(),
            closeIdentifier: "settings.server.changeSheet.cancel",
            confirmIdentifier: "settings.mcp.reveal.done"
        ) { EmptyView() }
        #expect(sheet.closeIdentifier == "settings.server.changeSheet.cancel")
        #expect(sheet.confirmIdentifier == "settings.mcp.reveal.done")
    }

    // MARK: - Close callback and close word

    @Test("a close is reported once, however often the button is hit")
    func closeReportedOnce() {
        let log = Log()
        let exit = HLSheetExit()
        exit.closed { log.runs += 1 }
        exit.closed { log.runs += 1 }
        #expect(log.runs == 1)
    }

    @Test("a confirm is never reported as a close")
    func confirmIsNoClose() {
        let log = Log()
        let exit = HLSheetExit()
        exit.confirmed()
        exit.closed { log.runs += 1 }
        #expect(log.runs == 0)
    }

    @Test("a sheet without a close callback closes all the same")
    func closeWithoutCallback() {
        let exit = HLSheetExit()
        exit.closed(nil)
        let log = Log()
        exit.closed { log.runs += 1 }
        #expect(log.runs == 0, "the close was settled by the first call")
    }

    @Test("the close button is spoken with the sheet's own word where it has one")
    func ownCloseWord() {
        #expect(HLSheetBar.closeLabel(for: .closeOnly, own: "Decline") == Text("Decline"))
        #expect(HLSheetBar.closeLabel(for: .save, own: "Decline") == Text("Decline"))
        #expect(HLSheetBar.closeLabel(for: .closeOnly) == HLControlWord.close.text)
        #expect(HLSheetBar.closeLabel(for: .save) == HLControlWord.cancel.text)
        #expect(HLSheetBar.closeLabel(for: .closeOnly, own: nil) == HLControlWord.close.text)
    }

    // MARK: - Title from data

    @Test("a title from data is shown as it is")
    func verbatimTitle() {
        let percent = HLSheetScaffold(verbatim: "50 %") { EmptyView() }
        #expect(percent.titleText == Text(verbatim: "50 %"))

        // "Done" is a catalog key. A record of that name keeps its name.
        let named = HLSheetScaffold(verbatim: "Done") { EmptyView() }
        #expect(named.titleText == Text(verbatim: "Done"))
        #expect(named.titleText != Text("Done"))

        let keyed = HLSheetScaffold("Done") { EmptyView() }
        #expect(keyed.titleText == Text("Done"))
    }

    // MARK: - Height from content

    @Test("a sheet as tall as its content has one detent at that height")
    func fittedHeight() {
        #expect(HLSheetSize.fitted(height: 312).detents == [.height(312)])
        #expect(HLSheetSize.fitted(height: 312).detents != HLSheetSize.compact.detents)
        #expect(HLSheetSize.fitted(height: 312) != .fitted(height: 280))
    }

    @Test("the named sizes keep their detents")
    func namedSizes() {
        #expect(HLSheetSize.standard.detents == [.medium, .large])
        #expect(HLSheetSize.compact.detents == [.medium])
        #expect(HLSheetSize.form.detents == [.large])
    }

    // MARK: - Running work

    @Test("running work holds the sheet and asks nothing")
    func busyLocksClose() {
        #expect(HLSheetBar.closeStep(isDirty: true, isBusy: true) == .locked)
        #expect(HLSheetBar.closeStep(isDirty: false, isBusy: true) == .locked)
    }

    @Test("without running work the close asks only for unsaved input")
    func idleClose() {
        #expect(HLSheetBar.closeStep(isDirty: true, isBusy: false) == .asksFirst)
        #expect(HLSheetBar.closeStep(isDirty: false, isBusy: false) == .leaves)
    }

    @Test("a busy sheet is not closed by a link from outside")
    func busyKeepsSheetOnDeepLink() {
        #expect(!HLDiscardGuard.closesForDeepLink(isDirty: false, isSaving: true))
        #expect(HLDiscardGuard.closesForDeepLink(isDirty: false, isSaving: false))
    }
}
