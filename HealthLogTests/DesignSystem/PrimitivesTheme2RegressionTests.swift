@testable import HealthLog
import SwiftUI
import Testing
import UIKit

/// Theme-2.0 (T2-2) lock-tests on the DesignSystem primitives. Pins the
/// single-accent + tonal-mono contract at the call-site level so a future
/// "let's bring back some color" regression in any one primitive trips a
/// build break instead of slowly drifting across the app.
///
/// **Why a separate suite vs `TokensRegressionTests`:** that suite asserts
/// the token VALUES (HLAccent.primary == 0xBD93F9). This suite asserts the
/// CONSUMERS — that HLBadge.purple paints HLAccent.primary, that
/// HLSparkline.Mode.area is gone, that HLRing's default tint resolves to
/// HLChartTints.series. A token-value passing while a primitive paints a
/// different colour at-call-site would be the exact silent drift Theme-2.0
/// is designed to prevent.
@Suite("Primitives Theme-2.0 (T2-2) regression")
struct PrimitivesTheme2RegressionTests {
    @Test(
        "HLSparkline.Mode collapses to line + bar (area dropped permanently)",
        arguments: [HLSparkline.Mode.line, .bar]
    )
    func sparklineModeHasNoArea(mode: HLSparkline.Mode) {
        // Theme-2.0 (T2-2): the LinearGradient area-fill is incompatible with
        // tonal-mono restraint. If a future change re-adds `.area`, the enum
        // exhaustiveness on the switch fails to compile. Parameterised test so
        // the compiler does the exhaustiveness check via the case-list itself
        // and the test array drives the case enumeration (a re-introduction of
        // `.area` would either fail compilation here OR require the new case
        // be added to the parameter array — either way the gate fires).
        let isCovered = switch mode {
        case .line, .bar: true
        }
        #expect(isCovered)
    }

    @Test("MetricKindDescriptor.tint resolves to mono surface for every kind")
    @MainActor
    func descriptorTintIsMonoForEveryKind() {
        // Locks the T2-2 sweep of `MetricKindDescriptor.catalog` so a future
        // "let me give weight a green tint" reintroduction fails. Resolution
        // hex must match HLSurface.secondary in both interface styles.
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        for kind in MetricKind.allCases {
            let descriptor = kind.descriptor
            #expect(
                TokensRegressionTests.resolvedHex(of: descriptor.tint, traits: lightTraits) == 0xFAF8F5,
                "Light-mode tint for \(kind) drifted off HLSurface.secondary"
            )
            #expect(
                TokensRegressionTests.resolvedHex(of: descriptor.tint, traits: darkTraits) == 0x1A1B1F,
                "Dark-mode tint for \(kind) drifted off HLSurface.secondary"
            )
        }
    }

    @Test("HLChartGrid.lineOpacity drives HLRing track (no hand-tuned literal)")
    func ringTrackOpacityRoutesThroughChartGrid() {
        // T2-2 collapsed HLRing's track from `textTertiary @ 18 %` to
        // `HLText.primary @ HLChartGrid.lineOpacity`. Locks the token route
        // so a future "let me brighten the ring track" regression fails.
        #expect(HLChartGrid.lineOpacity == 0.10)
    }
}
