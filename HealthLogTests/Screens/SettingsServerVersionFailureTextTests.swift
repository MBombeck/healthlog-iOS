import Foundation
@testable import HealthLog
import Testing

/// **H2 (1.1.0) — no Swift type name under "Version unavailable".**
///
/// The QA sweep photographed Settings → Server reading "Der Vorgang konnte
/// nicht abgeschlossen werden. (HealthLog.HLError-Fehler 2.)": the screen showed
/// `localizedDescription` of an `HLError`, which does not conform to
/// `LocalizedError`, so Foundation printed the type and case index. The screen
/// now shows the same user-facing sentence every store uses.
@Suite("Settings → Server — version failure text")
struct SettingsServerVersionFailureTextTests {
    @Test("An HLError reads as its user-facing sentence, never the type name")
    func hlErrorIsLocalizedCopy() {
        for error in [HLError.decoding("bad"), .offline, .unauthorized] {
            let text = SettingsServerScreen.versionFailureText(for: error)
            #expect(!text.contains("HLError"), "\(text)")
            #expect(text == HLError.userFacingText(for: error))
        }
    }

    @Test("A foreign error falls back to the neutral sentence")
    func foreignErrorIsNeutral() {
        let text = SettingsServerScreen.versionFailureText(for: CocoaError(.fileReadCorruptFile))
        #expect(text == HLError.userFacingText(for: CocoaError(.fileReadCorruptFile)))
    }
}
