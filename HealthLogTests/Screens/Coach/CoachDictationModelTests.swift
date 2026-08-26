import AVFoundation
@testable import HealthLog
import Testing

/// **C5 (b199 walkthrough) — mic-crash guard.**
///
/// The real crash was an uncatchable CoreAudio `NSException`: `installTap` traps
/// (`IsFormatSampleRateAndChannelCountValid`) when the input route is still
/// settling and the node's format has a zero sample-rate / channel-count.
/// `CoachDictationModel.start` now validates the tap format with
/// ``CoachDictationModel/isTapFormatValid(_:)`` BEFORE installing the tap and
/// refuses gracefully on an invalid format instead of aborting the process.
///
/// The audio engine cannot be started in the headless simulator test host, so we
/// pin the format-guard branch directly — the single decision that turns the trap
/// into a clean refuse-and-teardown.
@Suite("Coach dictation — tap-format guard (C5 crash fix)")
struct CoachDictationModelTests {
    @Test("a valid 48 kHz mono format is accepted")
    func acceptsValidFormat() throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)
        )
        #expect(CoachDictationModel.isTapFormatValid(format) == true)
    }

    @Test("a valid 44.1 kHz stereo format is accepted")
    func acceptsStereoFormat() throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        )
        #expect(CoachDictationModel.isTapFormatValid(format) == true)
    }

    /// M-1 (v0153) — `stop()` is idempotent and safe to call on a model that
    /// never started a session (the refuse-before-`isRecording` path the leak fix
    /// protects). The real session-leak assertion (session deactivated on the
    /// refuse/throw paths) needs a live `AVAudioSession`, which the headless test
    /// host cannot activate; this pins the observable contract — repeated `stop()`
    /// on a fresh model neither traps nor mutates `isRecording`.
    @MainActor
    @Test("stop() is a safe no-op on a never-started model (M-1 teardown contract)")
    func stopIsIdempotentBeforeStart() {
        let model = CoachDictationModel()
        #expect(model.isRecording == false)
        model.stop()
        model.stop()
        #expect(model.isRecording == false)
    }

    @Test("a zero sample-rate / channel-count format is rejected (the trap path)")
    func rejectsZeroFormat() throws {
        // Build a format with a zeroed AudioStreamBasicDescription — exactly the
        // "input route not yet bound" shape (sampleRate 0, channels 0) that makes
        // `installTap` trap. The guard must reject it so `start()` refuses
        // gracefully instead of aborting the process.
        var asbd = AudioStreamBasicDescription()
        let format = try #require(AVAudioFormat(streamDescription: &asbd))
        #expect(format.sampleRate == 0)
        #expect(format.channelCount == 0)
        #expect(CoachDictationModel.isTapFormatValid(format) == false)
    }
}
