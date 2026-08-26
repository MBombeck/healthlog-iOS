import AVFoundation
import Foundation
import Speech
import SwiftUI

/// **Coach voice dictation (web-parity v1.18.7).**
///
/// Drives the mic affordance in the AskCoach composer: requests microphone +
/// speech-recognition permission, runs a live `SFSpeechRecognizer` session over
/// the device microphone, and streams the running transcription into a bound
/// draft. The user reviews the transcribed text and sends through the normal
/// composer path — dictation never auto-sends.
///
/// **Privacy / on-device (hard contract).** Health-conversation audio must
/// never leave the phone. On-device recognition is therefore a *requirement*,
/// not a preference: the mic is shown only when the recognizer reports
/// `supportsOnDeviceRecognition` (`availability == .available`), and a
/// server-only recognizer is gated to `.unsupported` so the mic is never offered
/// — we never fall back to Apple's speech servers for this surface. As
/// defence-in-depth `requiresOnDeviceRecognition` is then forced `true`
/// unconditionally on the request, and `start` re-checks the on-device gate (so
/// an availability flip cannot open a transmitting session). Nothing is
/// persisted. (Audit b198 H-1: the earlier "set only when supported" logic could
/// transmit on a server-only locale — fixed by the gate + unconditional flag.)
///
/// **Lifecycle.** `@MainActor @Observable`; the audio engine + recognition task
/// are torn down on `stop()` and on `deinit`-equivalent (`stop()` is idempotent).
/// The model holds no `@unchecked Sendable` state — all mutable members are
/// touched only on the main actor.
@MainActor
@Observable
final class CoachDictationModel {
    /// High-level availability of the dictation affordance on this device.
    enum Availability: Equatable {
        /// Recognizer exists for the locale, is reachable, AND supports
        /// **on-device** recognition — mic can be shown. On-device support is a
        /// hard requirement (not a preference): the privacy contract is that
        /// health-conversation audio never leaves the phone, so a server-only
        /// recognizer is treated as `.unsupported`, not `.available`.
        case available
        /// No recognizer for the current locale, speech recognition is
        /// restricted on the device, OR the recognizer does not support
        /// on-device transcription — hide the mic entirely (we never fall back
        /// to Apple's speech servers for this surface).
        case unsupported
        /// The user denied microphone or speech-recognition permission — show a
        /// disabled mic that routes to Settings on tap.
        case denied
    }

    /// `true` while an audio session + recognition task are live.
    private(set) var isRecording = false

    /// Drives the mic glyph + whether tapping starts a session. Recomputed after
    /// each permission resolution.
    private(set) var availability: Availability

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// The draft text that existed when the session started, so streamed partial
    /// results are appended after it rather than replacing prior typing.
    private var baselineText = ""

    init(locale: Locale = .current) {
        let recognizer = SFSpeechRecognizer(locale: locale)
        self.recognizer = recognizer
        // On-device support is required, not preferred — a server-only
        // recognizer would stream mic audio off-device, which this surface must
        // never do. Gate the mic to `.unsupported` in that case.
        availability = Self.isOnDeviceReady(recognizer) ? .available : .unsupported
    }

    /// `true` only when the recognizer exists, is reachable, AND can transcribe
    /// fully on-device. The single source of truth for the on-device gate.
    private static func isOnDeviceReady(_ recognizer: SFSpeechRecognizer?) -> Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    /// Pre-`installTap` validity check for the input node's format. `installTap`
    /// asserts `IsFormatSampleRateAndChannelCountValid` and traps with an
    /// uncatchable ObjC exception when the route is still settling and the
    /// format has a zero sample-rate / channel-count. Calling this first lets
    /// `start()` refuse gracefully instead of crashing. Exposed (not private) so
    /// the guard branch is unit-testable without an audio engine — the headless
    /// test host cannot start `AVAudioEngine`.
    nonisolated static func isTapFormatValid(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    // MARK: - Public API

    /// Toggle a dictation session, transcribing into `draft`. Requests the two
    /// permissions on first use. Safe to call repeatedly; a second tap while
    /// recording stops the session and keeps whatever was transcribed.
    func toggle(into draft: Binding<String>) {
        if isRecording {
            stop()
        } else {
            Task { await start(into: draft) }
        }
    }

    /// Stop the session and tear down the audio graph. Idempotent.
    func stop() {
        guard isRecording || task != nil else { return }
        teardown()
    }

    /// **M-1 (v0153) — unconditional teardown.** Tears down the audio graph +
    /// recognition request AND deactivates the AVAudioSession, regardless of
    /// `isRecording`. The `start()` refuse (format-guard) and `catch` paths fire
    /// AFTER `configureAudioSession()` has already activated the session but
    /// BEFORE `isRecording = true`; calling `stop()` there short-circuits on its
    /// `guard isRecording || task != nil`, leaving the session ducking other
    /// audio and `self.request` dangling. Those paths call this directly so the
    /// session is always released. Safe to call repeatedly — every step is
    /// idempotent.
    private func teardown() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        deactivateAudioSession()
    }

    // MARK: - Start

    private func start(into draft: Binding<String>) async {
        guard let recognizer, Self.isOnDeviceReady(recognizer) else {
            // Re-check at start time: availability can flip (recognizer comes /
            // goes). If on-device is not possible, refuse rather than transmit.
            availability = .unsupported
            return
        }
        guard await ensurePermissions() else {
            availability = .denied
            return
        }
        availability = .available

        baselineText = draft.wrappedValue

        do {
            try configureAudioSession()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Defence-in-depth: force on-device transcription unconditionally so
            // mic audio never reaches Apple's speech servers, even if the
            // availability gate above were ever bypassed. The `start` guard has
            // already confirmed `supportsOnDeviceRecognition`, so this cannot
            // make an otherwise-valid session fail.
            request.requiresOnDeviceRecognition = true
            self.request = request

            let inputNode = audioEngine.inputNode
            // Read the tap format from the **input** node AFTER the session is
            // active (not `outputFormat`) — and guard it before installing the
            // tap. `installTap(format:)` asserts `IsFormatSampleRateAndChannelCountValid`
            // and traps with an uncatchable ObjC `NSException` (NOT a Swift error,
            // so the `catch` below can't intercept it) when the format has a
            // zero sample-rate / channel-count. That happens when the hardware
            // input route is still settling right after `setActive(true)`. Turn
            // the would-be crash into a graceful refuse-and-teardown.
            let format = inputNode.inputFormat(forBus: 0)
            guard Self.isTapFormatValid(format) else {
                HLLog.ui
                    .warning(
                        "Coach dictation: input format not ready (sampleRate/channelCount == 0) — refusing rather than trapping installTap."
                    )
                // M-1: `isRecording` is still false here (set only after the
                // engine starts), so `stop()` would short-circuit and leave the
                // just-activated session ducking other audio. Tear down directly.
                teardown()
                availability = .unsupported
                return
            }
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                // The recognizer's `@Sendable` callback runs off the main actor.
                // Capture only `Sendable` values (the transcription String + a
                // finished flag), then hop to the main actor to mutate model
                // state — no `assumeIsolated` painkiller.
                let transcription = result?.bestTranscription.formattedString
                let didFail = error != nil
                let isFinal = result?.isFinal ?? false
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let transcription {
                        apply(transcription: transcription, to: draft)
                    }
                    if didFail || isFinal {
                        finish(didFail: didFail)
                    }
                }
            }
        } catch {
            HLLog.ui.warning("Coach dictation failed to start: \(LogSanitizer.redact(String(describing: error)))")
            // M-1: `configureAudioSession()` may have already activated the
            // session before the throw (and `isRecording` is still false), so
            // `stop()` would short-circuit. Tear down unconditionally.
            teardown()
        }
    }

    // MARK: - Streaming

    private func apply(transcription: String, to draft: Binding<String>) {
        let separator = baselineText.isEmpty || baselineText.hasSuffix(" ") ? "" : " "
        draft.wrappedValue = baselineText + separator + transcription
    }

    private func finish(didFail: Bool) {
        // A user-initiated cancel surfaces as a failure too; only log when a
        // session was genuinely live (we tear ours down via `stop()`).
        if didFail, isRecording {
            HLLog.ui.warning("Coach dictation ended with a recognition error.")
        }
        stop()
    }

    // MARK: - Permissions

    /// Resolves both microphone + speech-recognition authorization, returning
    /// `true` only when BOTH are granted.
    private func ensurePermissions() async -> Bool {
        let micGranted = await requestMicrophonePermission()
        guard micGranted else { return false }
        let speechStatus = await requestSpeechAuthorization()
        return speechStatus == .authorized
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Mode `.default` (not `.measurement`): `.measurement` disables input
        // processing/AGC and forces a hardware-route change that re-negotiates
        // the input node's format asynchronously — which is what left the tap
        // format at sampleRate 0 and trapped `installTap` (the C5 crash).
        // Apple's own speech-recognition sample uses the default record mode for
        // dictation; we match it.
        try session.setCategory(.record, mode: .default, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            HLLog.ui.debug("Coach dictation audio session deactivate failed: \(LogSanitizer.redact(String(describing: error)))")
        }
    }
}
