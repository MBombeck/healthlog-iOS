import Foundation
@testable import HealthLog
import Testing

/// **Audit H2.** Locks the fully-framed VoiceOver label that
/// `ComplianceRingCard` feeds into `HLRing(accessibilityLabel:)`. Without it
/// the combined ring element announces only the bare value ("4 / 6") with no
/// context. The string is assembled in the model (not inline in the View) so
/// the EN/DE wiring is verifiable without a SwiftUI host.
@Suite("ComplianceSnapshot — ring accessibility label (audit H2)")
struct ComplianceSnapshotAccessibilityTests {
    // Locale-agnostic: the test sim runs in DE, so we assert on structure
    // (counts present, not a bare value, frame word present in whichever
    // locale resolved) rather than EN literals.

    @Test("scheduled day frames the value with count context")
    func scheduledLabel() {
        let snap = ComplianceSnapshot(scheduledToday: 6, takenToday: 4)
        let label = snap.ringAccessibilityLabel
        // Must carry BOTH counts so VoiceOver isn't a context-free "4 / 6"…
        #expect(label.contains("4"))
        #expect(label.contains("6"))
        // …and must be a framed sentence, not just the value.
        #expect(label.count > "4/6".count)
        // Whichever locale resolved, the compliance frame word is present.
        #expect(
            // Build 8 — the DE frame word is now "Therapietreue"; EN stays "compliance".
            label.localizedCaseInsensitiveContains("Therapietreue")
                || label.localizedCaseInsensitiveContains("compliance")
        )
    }

    @Test("empty-schedule day uses the nothing-scheduled label")
    func emptyScheduleLabel() {
        let snap = ComplianceSnapshot(scheduledToday: 0, takenToday: 0)
        let label = snap.ringAccessibilityLabel
        // Distinct from the scheduled-day label, and not the bare em-dash.
        #expect(
            label.localizedCaseInsensitiveContains("Therapietreue")
                || label.localizedCaseInsensitiveContains("compliance")
        )
        let scheduled = ComplianceSnapshot(scheduledToday: 6, takenToday: 4)
            .ringAccessibilityLabel
        #expect(label != scheduled)
    }
}
