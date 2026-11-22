import AVFoundation
import Foundation
import Speech

/// The seam between ``CoachDictationModel`` and the speech framework, so
/// tests can drive every way a start can fail.
@MainActor
protocol CoachSpeechRecognizing: AnyObject {
    /// The device has an on-device recognizer for the locale at all.
    var supportsOnDeviceRecognition: Bool { get }
    /// The on-device recognizer can take a session right now.
    var isReadyForOnDeviceRecognition: Bool { get }
    /// Microphone and speech permission, `true` only when both are granted.
    func requestAuthorization() async -> Bool
    /// Starts audio and recognition. Throws when the session cannot start;
    /// afterwards reports text and the end of the session on the main actor.
    func start(
        onTranscription: @escaping @MainActor @Sendable (String) -> Void,
        onFinish: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) throws
    /// Tears the session down. Idempotent.
    func stop()
}

enum CoachSpeechStartError: Error {
    /// The on-device recognizer went away between the tap and the start.
    case recognizerNotReady
    /// The input node reported a zero sample rate or channel count.
    case invalidInputFormat
}

/// The real recognizer: `SFSpeechRecognizer` over the device microphone,
/// on-device only.
@MainActor
final class CoachSpeechRecognizer: CoachSpeechRecognizing {
    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(locale: Locale) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    var supportsOnDeviceRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    var isReadyForOnDeviceRecognition: Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    func requestAuthorization() async -> Bool {
        guard await Self.requestRecordPermission() else { return false }
        return await Self.requestSpeechAuthorization() == .authorized
    }

    func start(
        onTranscription: @escaping @MainActor @Sendable (String) -> Void,
        onFinish: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) throws {
        guard let recognizer, isReadyForOnDeviceRecognition else {
            throw CoachSpeechStartError.recognizerNotReady
        }
        try configureAudioSession()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Forced unconditionally, so mic audio never reaches Apple's speech
        // servers even if the readiness check above were bypassed.
        request.requiresOnDeviceRecognition = true
        self.request = request

        let inputNode = audioEngine.inputNode
        // Read the format after the session is active and check it before
        // installing the tap: a zero format traps inside `installTap`.
        let format = inputNode.inputFormat(forBus: 0)
        guard CoachDictationModel.isTapFormatValid(format) else {
            throw CoachSpeechStartError.invalidInputFormat
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(for: request))
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeResultHandler(onTranscription: onTranscription, onFinish: onFinish)
        )
    }

    /// Tears down the audio graph and the request and releases the audio
    /// session. Also runs on the failed-start paths, where the session may
    /// already be active.
    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        deactivateAudioSession()
    }

    // MARK: - Callbacks built outside the main actor

    // The audio and speech frameworks call these handlers off the main thread.
    // A closure written inside a main-actor method inherits that isolation and
    // the runtime traps when another thread calls it; built here, they carry none.

    /// Feeds each microphone buffer to the request, on the audio thread.
    nonisolated static func makeTapBlock(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { [weak request] buffer, _ in
            request?.append(buffer)
        }
    }

    /// Passes only Sendable values out of the recognizer's callback, then hops
    /// to the main actor.
    nonisolated static func makeResultHandler(
        onTranscription: @escaping @MainActor @Sendable (String) -> Void,
        onFinish: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { @Sendable result, error in
            let transcription = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                if let transcription { onTranscription(transcription) }
                if error != nil || isFinal { onFinish(error) }
            }
        }
    }

    nonisolated static func makeRecordPermissionHandler(
        _ continuation: CheckedContinuation<Bool, Never>
    ) -> @Sendable (Bool) -> Void {
        { @Sendable granted in
            continuation.resume(returning: granted)
        }
    }

    nonisolated static func makeSpeechAuthorizationHandler(
        _ continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>
    ) -> @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void {
        { @Sendable status in
            continuation.resume(returning: status)
        }
    }

    @concurrent
    private nonisolated static func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission(completionHandler: makeRecordPermissionHandler(continuation))
        }
    }

    @concurrent
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization(makeSpeechAuthorizationHandler(continuation))
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Mode `.default`, not `.measurement`: the latter forces a route change
        // that leaves the input format at zero for a moment.
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
