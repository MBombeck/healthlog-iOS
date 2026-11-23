import Foundation
@testable import HealthLog
import Testing

/// Pins which layer of each widget takes the tint in tinted and clear rendering.
@Suite("Widget tint policy")
struct WidgetTintPolicyTests {
    @Test("Every widget puts at least one layer into the accent group", arguments: WidgetSurface.allCases)
    func everySurfaceHasAnAccent(surface: WidgetSurface) {
        #expect(!WidgetTintPolicy.accentLayers(for: surface).isEmpty)
    }

    @Test("Tracks and captions never take the tint", arguments: WidgetSurface.allCases)
    func framingLayersStayPrimary(surface: WidgetSurface) {
        #expect(!WidgetTintPolicy.isAccented(.ringTrack, in: surface))
        #expect(!WidgetTintPolicy.isAccented(.secondaryText, in: surface))
        #expect(!WidgetTintPolicy.isAccented(.headerTitle, in: surface))
    }

    @Test("Ring widgets tint the ring and keep the value in the primary tone")
    func ringWidgets() {
        for surface in [WidgetSurface.compliance, .healthScore, .watchNextDose, .watchHealthScore] {
            #expect(WidgetTintPolicy.isAccented(.ringProgress, in: surface))
            #expect(!WidgetTintPolicy.isAccented(.primaryValue, in: surface))
        }
    }

    @Test("Ring and status glyph share the tint, so the state is never carried by a hue alone")
    func statusGlyphTinted() {
        for surface in WidgetSurface.allCases where surface != .latestMeasurement {
            #expect(WidgetTintPolicy.isAccented(.statusSymbol, in: surface))
        }
    }

    @Test("Interactive widgets tint their control")
    func controlsTinted() {
        #expect(WidgetTintPolicy.isAccented(.actionButton, in: .nextDose))
        #expect(WidgetTintPolicy.isAccented(.actionButton, in: .mood))
    }

    @Test("The latest-measurement widget tints its value, which is all it shows")
    func latestMeasurementTintsValue() {
        #expect(WidgetTintPolicy.isAccented(.primaryValue, in: .latestMeasurement))
        #expect(WidgetTintPolicy.isAccented(.primaryValue, in: .watchLatestMeasurement))
    }

    @Test("Only full colour keeps status colours")
    func statusColourOnlyInFullColour() {
        #expect(WidgetTint.fullColor.keepsStatusColor)
        #expect(!WidgetTint.accented.keepsStatusColor)
        #expect(!WidgetTint.vibrant.keepsStatusColor)
    }

    @Test("Each score band has its own shape, and no band keeps the heart")
    func bandSymbols() {
        let bands: [String?] = ["green", "yellow", "red", nil]
        let symbols = bands.map(WidgetTintPolicy.healthScoreBandSymbol(band:))
        #expect(Set(symbols).count == bands.count)
        #expect(WidgetTintPolicy.healthScoreBandSymbol(band: nil) == "heart.fill")
        #expect(WidgetTintPolicy.healthScoreBandSymbol(band: "purple") == "heart.fill")
    }
}
