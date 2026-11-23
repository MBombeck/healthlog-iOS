import AVFoundation
import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// Every way a tap on the Coach mic can fail ends in a named hint, the mic
/// stays offered and the draft is left alone. Driven through the recognizer
/// seam, because the test host has no on-device speech recognition.
@MainActor
@Suite("Coach dictation, failed starts and their hints")
struct CoachDictationFailureTests {
    @MainActor
    final class FakeRecognizer: CoachSpeechRecognizing {
        var supportsOnDeviceRecognition = true
        var isReadyForOnDeviceRecognition = true
        var authorized = true
        var startError: (any Error)?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var onTranscription: (@MainActor @Sendable (String) -> Void)?
        var onFinish: (@MainActor @Sendable ((any Error)?) -> Void)?

        func requestAuthorization() async -> Bool {
            authorized
        }

        func start(
            onTranscription: @escaping @MainActor @Sendable (String) -> Void,
            onFinish: @escaping @MainActor @Sendable ((any Error)?) -> Void
        ) throws {
            startCount += 1
            if let startError { throw startError }
            self.onTranscription = onTranscription
            self.onFinish = onFinish
        }

        func stop() {
            stopCount += 1
        }
    }

    @MainActor
    final class Draft {
        var text = "Wie war mein Schlaf"
        var binding: Binding<String> {
            Binding(get: { self.text }, set: { self.text = $0 })
        }
    }

    private struct SomeFailure: Error {}

    private func expectFailed(
        _ model: CoachDictationModel,
        with hint: CoachDictationHint,
        draft: Draft,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(model.hint == hint, sourceLocation: sourceLocation)
        #expect(model.phase == .idle, sourceLocation: sourceLocation)
        #expect(model.availability == .available, "the mic stays offered", sourceLocation: sourceLocation)
        #expect(draft.text == "Wie war mein Schlaf", "the draft is untouched", sourceLocation: sourceLocation)
    }

    @Test("a recognizer that is not ready at the tap shows the unavailable hint")
    func recognizerNotReady() async {
        let fake = FakeRecognizer()
        fake.isReadyForOnDeviceRecognition = false
        let model = CoachDictationModel(recognizer: fake)
        let draft = Draft()
        await model.start(into: draft.binding)
        expectFailed(model, with: .unavailable, draft: draft)
        #expect(fake.startCount == 0)
    }

    @Test("an input format that is not ready shows the busy-mic hint")
    func invalidInputFormat() async {
        let fake = FakeRecognizer()
        fake.startError = CoachSpeechStartError.invalidInputFormat
        let model = CoachDictationModel(recognizer: fake)
        let draft = Draft()
        await model.start(into: draft.binding)
        expectFailed(model, with: .micBusy, draft: draft)
        #expect(fake.stopCount == 1, "the half-started session is torn down")
    }

    @Test("an audio session held by another app shows the busy-mic hint")
    func audioSessionBusy() async {
        let fake = FakeRecognizer()
        fake.startError = NSError(
            domain: NSOSStatusErrorDomain,
            code: AVAudioSession.ErrorCode.insufficientPriority.rawValue
        )
        let model = CoachDictationModel(recognizer: fake)
        let draft = Draft()
        await model.start(into: draft.binding)
        expectFailed(model, with: .micBusy, draft: draft)
    }

    @Test("any other error at the start shows the start-failed hint")
    func throwsAtStart() async {
        let fake = FakeRecognizer()
        fake.startError = SomeFailure()
        let model = CoachDictationModel(recognizer: fake)
        let draft = Draft()
        await model.start(into: draft.binding)
        expectFailed(model, with: .startFailed, draft: draft)
    }

    @Test("a recognition error right after the start shows the start-failed hint")
    func recognitionErrorBeforeText() async throws {
        let fake = FakeRecognizer()
        let model = CoachDictationModel(recognizer: fake)
        let draft = Draft()
        await model.start(into: draft.binding)
        #expect(model.phase == .recording)
        let finish = try #require(fake.onFinish)
        finish(NSError(domain: "kAFAssistantErrorDomain", code: 1101))
        expectFailed(model, with: .startFailed, draft: draft)
    }

    @Test("an error after text arrived ends quietly and keeps the text")
    func recognitionErrorAfterText() async throws {
        let fake = FakeRecognizer()
        let model = CoachDictationModel(recognizer: fake)
        let draft = Draft()
        await model.start(into: draft.binding)
        let transcribe = try #require(fake.onTranscription)
        let finish = try #require(fake.onFinish)
        transcribe("in dieser Woche")
        finish(SomeFailure())
        #expect(model.hint == nil)
        #expect(model.phase == .idle)
        #expect(draft.text == "Wie war mein Schlaf in dieser Woche")
    }

    @Test("a refused permission keeps the settings route and shows no hint")
    func permissionRefused() async {
        let fake = FakeRecognizer()
        fake.authorized = false
        let model = CoachDictationModel(recognizer: fake)
        let draft = Draft()
        await model.start(into: draft.binding)
        #expect(model.availability == .denied)
        #expect(model.hint == nil)
        #expect(model.phase == .idle)
    }

    @Test("a tap shows the starting state at once")
    func startingStateIsImmediate() {
        let model = CoachDictationModel(recognizer: FakeRecognizer())
        let draft = Draft()
        model.toggle(into: draft.binding)
        #expect(model.phase == .starting)
        #expect(model.isActive)
        model.stop()
        #expect(model.phase == .idle)
    }

    @Test("the hint goes away with the next attempt")
    func hintClearsOnNextAttempt() async {
        let fake = FakeRecognizer()
        fake.startError = SomeFailure()
        let model = CoachDictationModel(recognizer: fake)
        let draft = Draft()
        await model.start(into: draft.binding)
        #expect(model.hint == .startFailed)
        model.toggle(into: draft.binding)
        #expect(model.hint == nil)
        #expect(model.phase == .starting)
    }

    @Test("only a device without an on-device recognizer hides the mic")
    func unsupportedOnlyAtCreation() async {
        let without = FakeRecognizer()
        without.supportsOnDeviceRecognition = false
        #expect(CoachDictationModel(recognizer: without).availability == .unsupported)

        let notReady = FakeRecognizer()
        notReady.isReadyForOnDeviceRecognition = false
        let model = CoachDictationModel(recognizer: notReady)
        await model.start(into: Draft().binding)
        #expect(model.availability == .available)
    }
}
