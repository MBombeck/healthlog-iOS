#if DEBUG
    import Foundation

    /// UI-test seam (`-uitest-coach-dictation`): dictation counts as possible,
    /// the start fails. The simulator has no on-device recognizer, so without
    /// this the mic and its hint line could never be seen in a test or a
    /// picture. The short wait keeps the starting disc on screen long enough
    /// to photograph it.
    @MainActor
    final class CoachDictationUITestRecognizer: CoachSpeechRecognizing {
        private struct StartFailure: Error {}

        let supportsOnDeviceRecognition = true
        let isReadyForOnDeviceRecognition = true

        func requestAuthorization() async -> Bool {
            try? await Task.sleep(for: .seconds(2))
            return true
        }

        func start(
            onTranscription _: @escaping @MainActor @Sendable (String) -> Void,
            onFinish _: @escaping @MainActor @Sendable ((any Error)?) -> Void
        ) throws {
            throw StartFailure()
        }

        func stop() {}
    }
#endif
