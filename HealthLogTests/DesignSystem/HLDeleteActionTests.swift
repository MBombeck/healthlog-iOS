import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The two steps of the delete ladder. A single entry that can be brought
/// back goes at once; a container with history asks first, and its swipe
/// must not run through. Whatever the control, a deletion runs once.
@MainActor
@Suite("Delete ladder")
struct HLDeleteActionTests {
    @MainActor
    private final class Log {
        var deletions = 0
    }

    /// Lets the tasks a tap has started run.
    private func settle(until done: () -> Bool = { false }) async {
        for _ in 0 ..< 1000 where !done() {
            await Task.yield()
        }
    }

    @Test("an undoable deletion asks nothing and may be swiped through")
    func undoableShape() {
        let action = HLDeleteAction.undoable {}
        #expect(!action.requiresConfirmation)
        #expect(action.allowsFullSwipe)
        #expect(action.question == nil)
    }

    @Test("a confirmed deletion asks first and cannot be swiped through")
    func confirmedShape() {
        let action = HLDeleteAction.confirmed(title: "Delete entry?") {}
        #expect(action.requiresConfirmation)
        #expect(!action.allowsFullSwipe)
        #expect(action.question != nil)
    }

    @Test("running the action deletes exactly once")
    func runDeletes() async {
        let log = Log()
        await HLDeleteAction.undoable { log.deletions += 1 }.run()
        #expect(log.deletions == 1)

        await HLDeleteAction.confirmed(title: "Delete entry?") { log.deletions += 1 }.run()
        #expect(log.deletions == 2)
    }

    @Test("a tap on an undoable delete control deletes without a question")
    func undoableTapDeletes() async {
        let log = Log()
        let runner = HLDeleteRunner()
        runner.trigger(.undoable { log.deletions += 1 })
        await settle { log.deletions > 0 && !runner.isRunning }
        #expect(log.deletions == 1)
        #expect(!runner.isAsking)
        #expect(!runner.isRunning)
    }

    @Test("a tap on a confirmed delete control only raises the question")
    func confirmedTapAsks() async {
        let log = Log()
        let runner = HLDeleteRunner()
        runner.trigger(.confirmed(title: "Delete entry?") { log.deletions += 1 })
        await settle()
        #expect(runner.isAsking)
        #expect(runner.asked?.question != nil)
        #expect(log.deletions == 0, "the entry was deleted before the question was answered")
    }

    @Test("the answer to the question deletes once, and leaving it deletes nothing")
    func answer() async {
        let log = Log()
        let runner = HLDeleteRunner()
        let action = HLDeleteAction.confirmed(title: "Delete entry?") { log.deletions += 1 }

        runner.trigger(action)
        // Cancel: the alert only takes the question down.
        runner.isAsking = false
        await settle()
        #expect(log.deletions == 0)

        runner.trigger(action)
        runner.confirm()
        await settle { log.deletions > 0 && !runner.isRunning }
        #expect(log.deletions == 1)
        #expect(!runner.isAsking)
    }

    @Test("two taps in a row delete once")
    func doubleTap() async {
        let log = Log()
        let runner = HLDeleteRunner()
        let action = HLDeleteAction.undoable { log.deletions += 1 }
        runner.trigger(action)
        runner.trigger(action)
        await settle()
        #expect(log.deletions == 1, "the second tap deleted again")
        #expect(!runner.isRunning)
    }

    @Test("a tap while a deletion runs does nothing")
    func oneRunAtATime() async {
        let log = Log()
        let runner = HLDeleteRunner()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let action = HLDeleteAction.undoable {
            log.deletions += 1
            for await _ in gate {
                break
            }
        }

        runner.trigger(action)
        await settle { log.deletions > 0 }
        #expect(runner.isRunning)

        runner.trigger(action)
        runner.trigger(.confirmed(title: "Delete entry?") { log.deletions += 1 })
        #expect(!runner.isAsking, "a question came up while a deletion was running")
        #expect(await runner.run(action) == false, "a second run went through")
        await settle()
        #expect(log.deletions == 1)

        open.yield()
        open.finish()
        await settle { !runner.isRunning }
        #expect(!runner.isRunning)
        #expect(log.deletions == 1)

        #expect(await runner.run(action))
        #expect(log.deletions == 2, "the runner stayed locked after the deletion")
    }

    // MARK: - The word of the question

    @Test("the question answers with Delete unless the action brings its own word")
    func standardWord() {
        #expect(HLDeleteAction.confirmed(title: "Delete entry?") {}.wordText == HLControlWord.delete.text)
        #expect(HLDeleteAction.undoable {}.wordText == HLControlWord.delete.text)
        #expect(HLDeleteAction.confirmed(title: "Delete entry?") {}.symbol == "trash")
    }

    @Test("the question carries the word it was given")
    func ownWord() async {
        let action = HLDeleteAction.confirmed(
            title: "End this session?",
            word: "Revoke",
            symbol: "xmark.circle"
        ) {}
        #expect(action.wordText == Text("Revoke"))
        #expect(action.wordText != HLControlWord.delete.text)
        #expect(action.symbol == "xmark.circle")

        let runner = HLDeleteRunner()
        runner.trigger(action)
        await settle()
        #expect(runner.isAsking)
        #expect(runner.asked?.wordText == Text("Revoke"), "the question lost the word on the way")
    }

    @Test("an own word changes nothing about the step")
    func ownWordKeepsBehaviour() async {
        let log = Log()
        let runner = HLDeleteRunner()
        let action = HLDeleteAction.confirmed(title: "End this session?", word: "Revoke") { log.deletions += 1 }
        #expect(action.requiresConfirmation)
        #expect(!action.allowsFullSwipe)

        runner.trigger(action)
        await settle()
        #expect(log.deletions == 0, "it ran before the question was answered")
        runner.confirm()
        await settle { log.deletions > 0 && !runner.isRunning }
        #expect(log.deletions == 1)
    }

    @Test("a question built from data is shown as it is")
    func verbatimQuestion() {
        let action = HLDeleteAction.confirmed(verbatim: "Delete \u{201E}50 %\u{201C}?", message: "Done") {}
        #expect(action.question?.title == Text(verbatim: "Delete \u{201E}50 %\u{201C}?"))
        #expect(action.question?.message == Text(verbatim: "Done"))
        #expect(action.question?.message != Text("Done"), "a message from data was looked up in the catalog")
        #expect(action.requiresConfirmation)
        #expect(action.wordText == HLControlWord.delete.text)
    }

    // MARK: - Forms of the button

    @Test("the sign alone is at least 44 points in both directions")
    func iconHitArea() throws {
        let button = HLDeleteButton(form: .icon, action: .undoable {})
        for typeSize in [DynamicTypeSize.xSmall, .large, .accessibility5] {
            let size = try DesignContractMeasure.size(of: button, width: nil, typeSize: typeSize)
            #expect(size.width >= HLHitTarget.minimum, "\(typeSize): \(size.width) pt wide")
            #expect(size.height >= HLHitTarget.minimum, "\(typeSize): \(size.height) pt high")
        }
    }

    @Test("the sign alone is spoken as Delete")
    func iconSpokenLabel() {
        #expect(HLDeleteButton(form: .icon, action: .undoable {}).label == HLControlWord.delete.text)
        #expect(HLDeleteButton(form: .icon, action: .confirmed(title: "Delete entry?") {}).label
            == HLControlWord.delete.text)
    }

    @Test("a button says its own title, else the word of its action")
    func buttonLabel() {
        let revoke = HLDeleteAction.confirmed(title: "End this session?", word: "Revoke") {}
        #expect(HLDeleteButton(form: .row, action: revoke).label == Text("Revoke"))
        #expect(HLDeleteButton("Remove entry", form: .icon, action: revoke).label == Text("Remove entry"))
        #expect(HLDeleteButton("Delete 3 entries", form: .bar, action: .undoable {}).label == Text("Delete 3 entries"))
        #expect(HLDeleteButton(form: .bar, action: .undoable {}).label == HLControlWord.delete.text)
    }

    @Test("every form of the button renders")
    func formsRender() throws {
        let action = HLDeleteAction.confirmed(title: "Delete entry?") {}
        for form in [HLDeleteButton.Form.row, .page, .icon, .bar] {
            let size = try DesignContractMeasure.size(of: HLDeleteButton(form: form, action: action))
            #expect(size.height > 0, "\(form) has no height")
        }
    }
}
