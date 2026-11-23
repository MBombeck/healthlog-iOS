import AVFoundation
import Foundation
import SwiftUI

/// **Coach voice dictation (web-parity v1.18.7).**
///
/// Drives the mic in the AskCoach composer: asks for microphone and speech
/// permission, runs a live on-device recognition session and streams the
/// running transcription into a bound draft. The user reviews the text and
/// sends through the normal composer path; dictation never auto-sends.
///
/// **Privacy (hard contract).** Health-conversation audio never leaves the
/// phone. The mic is offered only when the recognizer supports on-device
/// recognition, the request forces it, and there is no fallback to Apple's
/// speech servers. Nothing is persisted.
///
/// **Every tap has a visible answer.** A tap shows the active disc at once
/// (`phase == .starting`), and every way a start can fail ends in a named
/// ``CoachDictationHint`` the composer shows above the field. The recognizer
/// sits behind ``CoachSpeechRecognizing`` so each of those paths is testable.
@MainActor
@Observable
final class CoachDictationModel {
    /// What the device can do at all, decided when the sheet opens.
    enum Availability: Equatable {
        /// An on-device recognizer exists for the locale: the mic is shown.
        case available
        /// No recognizer, or one that would need the network: the mic is
        /// hidden. Only ever set at creation, never after a failed tap.
        case unsupported
        /// Microphone or speech permission was refused: the slashed mic
        /// routes to Settings.
        case denied
    }

    enum Phase: Equatable {
        case idle
        /// Tapped; permissions and the audio graph are being set up.
        case starting
        case recording
    }

    private(set) var availability: Availability
    private(set) var phase: Phase = .idle
    /// Why the last tap did not lead to a dictation, until the next tap or
    /// keystroke clears it.
    private(set) var hint: CoachDictationHint?

    /// `true` while the audio session and recognition task are live.
    var isRecording: Bool {
        phase == .recording
    }

    /// `true` from the tap until the session ends: the mic shows its active disc.
    var isActive: Bool {
        phase != .idle
    }

    private let recognizer: any CoachSpeechRecognizing

    /// The draft that existed when the session started, so streamed partial
    /// results are appended after it rather than replacing prior typing.
    private var baselineText = ""
    /// Whether this session has already written text into the draft.
    private var receivedText = false

    init(recognizer: (any CoachSpeechRecognizing)? = nil) {
        let recognizer = recognizer ?? Self.makeRecognizer()
        self.recognizer = recognizer
        availability = recognizer.supportsOnDeviceRecognition ? .available : .unsupported
    }

    private static func makeRecognizer() -> any CoachSpeechRecognizing {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uitest-coach-dictation") {
                return CoachDictationUITestRecognizer()
            }
        #endif
        return CoachSpeechRecognizer(locale: .current)
    }

    /// Pre-`installTap` validity check for the input node's format.
    /// `installTap` traps with an uncatchable exception on a zero sample rate
    /// or channel count, which happens while the input route is still
    /// settling; the recognizer refuses instead.
    nonisolated static func isTapFormatValid(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    // MARK: - Public API

    /// Start a session, or stop the running one and keep what was transcribed.
    func toggle(into draft: Binding<String>) {
        if isActive {
            stop()
        } else {
            beginStarting()
            Task { await run(into: draft) }
        }
    }

    /// Stop the session and tear down the audio graph. Idempotent.
    func stop() {
        guard isActive else { return }
        phase = .idle
        recognizer.stop()
    }

    func clearHint() {
        hint = nil
    }

    // MARK: - Start

    private func beginStarting() {
        hint = nil
        phase = .starting
    }

    /// A start that can be awaited (tests); `toggle` is the tap.
    func start(into draft: Binding<String>) async {
        beginStarting()
        await run(into: draft)
    }

    private func run(into draft: Binding<String>) async {
        // Stopped again before the task ran.
        guard phase == .starting else { return }
        // Re-checked at the tap: a recognizer can exist and still not be
        // ready (offline model missing, Siri and Dictation off).
        guard recognizer.isReadyForOnDeviceRecognition else {
            fail(.unavailable, error: nil)
            return
        }
        guard await recognizer.requestAuthorization() else {
            phase = .idle
            availability = .denied
            return
        }
        // Stopped again while the permission prompt was up.
        guard phase == .starting else { return }
        availability = .available
        baselineText = draft.wrappedValue
        receivedText = false
        do {
            try recognizer.start(
                onTranscription: { [weak self] text in
                    self?.apply(transcription: text, to: draft)
                },
                onFinish: { [weak self] error in
                    self?.finish(error: error)
                }
            )
            phase = .recording
        } catch {
            recognizer.stop()
            fail(Self.hint(forStartError: error), error: error)
        }
    }

    /// Which hint a failed start shows.
    nonisolated static func hint(forStartError error: any Error) -> CoachDictationHint {
        switch error {
        case CoachSpeechStartError.recognizerNotReady: return .unavailable
        case CoachSpeechStartError.invalidInputFormat: return .micBusy
        default: break
        }
        let nsError = error as NSError
        let busyCodes = [
            AVAudioSession.ErrorCode.isBusy.rawValue,
            AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue,
            AVAudioSession.ErrorCode.insufficientPriority.rawValue
        ]
        if nsError.domain == NSOSStatusErrorDomain, busyCodes.contains(nsError.code) { return .micBusy }
        return .startFailed
    }

    // MARK: - Streaming

    private func apply(transcription: String, to draft: Binding<String>) {
        guard isActive else { return }
        let separator = baselineText.isEmpty || baselineText.hasSuffix(" ") ? "" : " "
        draft.wrappedValue = baselineText + separator + transcription
        receivedText = true
    }

    /// The recognition ended on its own (final result or error). An error
    /// before any text arrived is a failed start; after text it ends quietly
    /// and the text stays.
    private func finish(error: (any Error)?) {
        // Our own `stop()` already went idle; its cancel callback is not news.
        guard isActive else { return }
        phase = .idle
        recognizer.stop()
        if let error, !receivedText {
            fail(.startFailed, error: error)
        }
    }

    private func fail(_ reason: CoachDictationHint, error: (any Error)?) {
        phase = .idle
        hint = reason
        let nsError = error.map { $0 as NSError }
        let domain = nsError?.domain ?? "none"
        let code = nsError?.code ?? 0
        HLLog.ui.warning("Coach dictation did not start: \(reason.logName) (\(domain) \(code))")
    }
}

/// Why a tap on the mic did not lead to a dictation. Shown as one quiet line
/// above the composer.
enum CoachDictationHint: Equatable {
    /// The on-device recognizer is not ready on this device right now.
    case unavailable
    /// Anything else at or right after the start.
    case startFailed
    /// The input format was not ready or another app holds the audio session.
    case micBusy

    var text: String {
        switch self {
        case .unavailable: String(localized: "coach.dictation.hint.unavailable")
        case .startFailed: String(localized: "coach.dictation.hint.startFailed")
        case .micBusy: String(localized: "coach.dictation.hint.micBusy")
        }
    }

    var logName: String {
        switch self {
        case .unavailable: "unavailable"
        case .startFailed: "startFailed"
        case .micBusy: "micBusy"
        }
    }
}
