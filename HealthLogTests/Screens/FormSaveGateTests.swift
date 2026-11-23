import Foundation
@testable import HealthLog
import Testing

/// The save state the form sheets close on: a failed save keeps the sheet open
/// with its error, and a second tap while a save runs does not save twice.
@MainActor
@Suite("Form save gate")
struct FormSaveGateTests {
    @MainActor
    private final class Counter {
        var value = 0
    }

    @Test("A failed save keeps the sheet open and holds the error")
    func failureKeepsSheetOpen() async {
        let gate = FormSaveGate()
        let mayClose = await gate.submit { .server(status: 422, code: "VALIDATION", message: "Nope") }
        #expect(mayClose == false)
        #expect(gate.error == .server(status: 422, code: "VALIDATION", message: "Nope"))
        #expect(gate.isSaving == false)
    }

    @Test("A saved entry lets the sheet close and clears an earlier error")
    func successClosesSheet() async {
        let gate = FormSaveGate()
        _ = await gate.submit { .offline }
        let mayClose = await gate.submit { nil }
        #expect(mayClose)
        #expect(gate.error == nil)
    }

    @Test("A second tap while the first save runs saves once")
    func doubleTapSavesOnce() async {
        let gate = FormSaveGate()
        let runs = Counter()
        let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)

        let first = Task { @MainActor in
            await gate.submit {
                runs.value += 1
                for await _ in release {
                    break
                }
                return nil
            }
        }
        while !gate.isSaving {
            await Task.yield()
        }

        let second = await gate.submit {
            runs.value += 1
            return nil
        }
        releaseContinuation.yield()
        releaseContinuation.finish()
        let firstClosed = await first.value

        #expect(second == false)
        #expect(firstClosed)
        #expect(runs.value == 1)
        #expect(gate.error == nil)
    }
}
