@testable import HealthLog
import Testing

/// **A2 (b244) — the three-state cycle opt-in presentation.**
///
/// The flag gates existence; the gate's availability decides toggle vs a neutral
/// offer so a non-cycle user never sees a live-looking "cycle tracking" toggle,
/// while the tertiary-override opt-in path stays reachable for everyone. The
/// opt-in FLIP itself is existing, tested logic (`setCycleTrackingOptIn` → PATCH
/// cycle-prefs) — only the presentation decision is new.
@Suite("Cycle opt-in presentation")
struct CycleOptInPresentationTests {
    @Test(
        "mode: flag off → hidden; on+available → toggle; on+not-available → offer",
        arguments: [
            (false, false, CycleOptInPresentation.Mode.hidden),
            (false, true, .hidden), // flag off wins regardless of availability
            (true, true, .toggle),
            (true, false, .offer)
        ]
    )
    func modeResolution(_ flagOn: Bool, _ available: Bool, _ expected: CycleOptInPresentation.Mode) {
        #expect(CycleOptInPresentation.mode(flagOn: flagOn, available: available) == expected)
    }
}
