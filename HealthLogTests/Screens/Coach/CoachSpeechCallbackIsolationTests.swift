import AVFoundation
import Foundation
@testable import HealthLog
import Speech
import Testing

/// The audio and speech frameworks call the dictation handlers off the main
/// thread. Each handler is built and called on a detached task here, the way
/// the frameworks do it; a handler that had picked up main-actor isolation
/// would trap and take the test host down with it.
@Suite("Coach dictation, callbacks off the main thread")
struct CoachSpeechCallbackIsolationTests {
    @Test("the tap block runs on a background thread with a real buffer")
    func tapBlockOffMain() async {
        let ran = await Task.detached {
            let request = SFSpeechAudioBufferRecognitionRequest()
            let block = CoachSpeechRecognizer.makeTapBlock(for: request)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { return false }
            buffer.frameLength = 1024
            block(buffer, AVAudioTime(sampleTime: 0, atRate: 48000))
            request.endAudio()
            return true
        }.value
        #expect(ran)
    }

    @Test("the result handler runs off the main thread and reports back on the main actor")
    func resultHandlerOffMain() async {
        let arrivedOnMain = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task.detached {
                let handler = CoachSpeechRecognizer.makeResultHandler(
                    onTranscription: { _ in },
                    onFinish: { error in
                        continuation.resume(returning: error != nil && Thread.isMainThread)
                    }
                )
                handler(nil, NSError(domain: "kAFAssistantErrorDomain", code: 1101))
            }
        }
        #expect(arrivedOnMain)
    }

    @Test("the permission handlers run off the main thread")
    func permissionHandlersOffMain() async {
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task.detached {
                CoachSpeechRecognizer.makeRecordPermissionHandler(continuation)(true)
            }
        }
        #expect(granted)
        let status = await withCheckedContinuation {
            (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            Task.detached {
                CoachSpeechRecognizer.makeSpeechAuthorizationHandler(continuation)(.authorized)
            }
        }
        #expect(status == .authorized)
    }

    /// Keeps the crashing form from coming back: none of the four framework
    /// calls may get a closure literal written in the main-actor class.
    @Test("no framework call in the recognizer takes a closure literal")
    func noClosureLiteralsAtFrameworkCalls() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HealthLog/Screens/Coach/CoachSpeechRecognizer.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let forbidden = [
            #"installTap\([^\n]*\)\s*\{"#,
            #"installTap\([^\n]*block:\s*\{"#,
            #"requestRecordPermission\s*(\(\s*(completionHandler:\s*)?)?\{"#,
            #"\.requestAuthorization\s*(\(\s*)?\{"#,
            #"recognitionTask\(\s*with:[^)]*\)\s*\{"#,
            #"recognitionTask\(\s*with:[^)]*resultHandler:\s*\{"#
        ]
        for pattern in forbidden {
            #expect(source.range(of: pattern, options: .regularExpression) == nil, "\(pattern)")
        }
        // The calls themselves are still there, so the guard looks at real code.
        for call in ["installTap(", "requestRecordPermission(", ".requestAuthorization(", "recognitionTask("] {
            #expect(source.contains(call), "\(call)")
        }
    }
}
