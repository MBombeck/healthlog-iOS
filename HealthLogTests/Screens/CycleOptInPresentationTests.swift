@testable import HealthLog
import Testing

/// **The cycle opt-in presentation.**
///
/// The gate's availability decides toggle vs a neutral offer so a non-cycle
/// user never sees a live-looking "cycle tracking" toggle, while the
/// tertiary-override opt-in path stays reachable for everyone. The opt-in FLIP
/// itself is existing, tested logic (`setCycleTrackingOptIn` → PATCH
/// cycle-prefs) — only the presentation decision is new.
@Suite("Cycle opt-in presentation")
struct CycleOptInPresentationTests {
    @Test(
        "mode: available → toggle; not available → offer",
        arguments: [
            (true, CycleOptInPresentation.Mode.toggle),
            (false, .offer)
        ]
    )
    func modeResolution(_ available: Bool, _ expected: CycleOptInPresentation.Mode) {
        #expect(CycleOptInPresentation.mode(available: available) == expected)
    }
}
