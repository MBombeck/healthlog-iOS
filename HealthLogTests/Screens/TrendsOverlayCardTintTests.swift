@testable import HealthLog
import SwiftUI
import Testing
import UIKit

/// V052-R1 reconcile (2026-05-17) — locks `TrendsOverlayCard.tint(for:)`
/// against the multi-series differentiation contract.
///
/// **Why this exists:** Visual-Polish-1 (2026-05-16) flagged that the
/// overlay chart rendered every series in the same Dracula-Purple tint.
/// V052-R1 then caught a follow-up regression: a fixed 4-tint Dracula
/// palette collides with the user-picked accent when the operator
/// selects e.g. `.cyan` as their accent (weight and BP both render cyan).
///
/// v0.8.1 monochrome-restore: the lead series no longer follows the (retired)
/// user-picked accent — it is the monochrome `HLText.primary`. The whole ramp
/// is now monochrome: lead = `HLText.primary`, companions = the same colour at
/// 80% / 55% / 35% opacity. The helpers below resolve against an explicit dark
/// trait collection so the alpha ramp scales cleanly off a full-opacity base
/// (in light mode `HLText.primary` is alpha-over-surface, which would scale the
/// whole ramp). These tests anchor:
///
/// 1. The mapping is deterministic — same metric, same tint, every call.
/// 2. The first four `MetricKind.allCases` positions return visually
///    distinct tints (accent + 3 graphite companions) — the critical
///    differentiation invariant.
/// 3. Beyond position 4 the ramp cycles via modulo (rare path; locked so
///    a future bounds-check refactor doesn't crash on 5+ metric overlays).
/// 4. The chip-swatch tint (private inside the peer struct) matches the
///    chart-line tint for the same metric — covered transitively here
///    because the chip routes through the same static `tint(for:)`.
@Suite("TrendsOverlayCard multi-series tint mapping")
@MainActor
struct TrendsOverlayCardTintTests {
    /// Dark trait collection — resolves the monochrome ramp off a
    /// full-opacity base so the companion alpha ladder reads cleanly.
    private let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

    /// Reusable colour-to-hex decoder; resolves against dark traits so the
    /// asset-catalog-backed `HLText.primary` lead is deterministic.
    private func hex(of color: Color) -> UInt32 {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        let resolved = UIColor(color).resolvedColor(with: darkTraits)
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        let rb = UInt32((r * 255).rounded()) & 0xFF
        let gb = UInt32((g * 255).rounded()) & 0xFF
        let bb = UInt32((b * 255).rounded()) & 0xFF
        return (rb << 16) | (gb << 8) | bb
    }

    /// Alpha helper for graphite-companion assertions (resolved in dark).
    private func alpha(of color: Color) -> CGFloat {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        let resolved = UIColor(color).resolvedColor(with: darkTraits)
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        return a
    }

    @Test("The first four MetricKind positions render distinguishable lines")
    func firstFourMetricsAreDistinguishable() {
        // Default picker = Dracula-purple; reset to guarantee a stable lead.
        UserDefaults.standard.removeObject(forKey: "hl.settings.tint")
        let kinds = Array(MetricKind.allCases.prefix(4))
        let tints = kinds.map { TrendsOverlayCard.tint(for: $0) }

        // Critical invariant: a 4-metric overlay must render 4 distinguishable
        // lines so the user can read which line is which. v0.8.1 contract:
        // lead = monochrome `HLText.primary`, companions = the same colour at
        // ~0.80 / ~0.55 / ~0.35 opacity. We assert the visual differentiation
        // by composite signature (hue + alpha): lead is the full-opacity
        // monochrome, companions have a strictly decreasing alpha ramp. Alpha
        // tolerance covers UIColor display-P3 round-trip quantisation.
        #expect(hex(of: tints[0]) == 0xEBEBF5) // monochrome — lead (dark #EBEBF5)
        let a1 = alpha(of: tints[1])
        let a2 = alpha(of: tints[2])
        let a3 = alpha(of: tints[3])
        #expect(abs(a1 - 0.80) < 0.05)
        #expect(abs(a2 - 0.575) < 0.05)
        #expect(abs(a3 - 0.325) < 0.05)
        #expect(a1 > a2)
        #expect(a2 > a3)
    }

    @Test("The same MetricKind always returns the same tint (deterministic)")
    func mappingIsDeterministic() {
        // Determinism is load-bearing: if the same metric flipped colour
        // between sessions or app launches, the user couldn't build mental
        // anchors ("the cyan line is always BP"). Anchored against
        // `MetricKind.allCases` index — a future case-reorder in
        // `Measurement.swift` will visibly re-colour the chart, which is
        // an intentional + traceable change.
        for kind in MetricKind.allCases {
            let a = TrendsOverlayCard.tint(for: kind)
            let b = TrendsOverlayCard.tint(for: kind)
            #expect(hex(of: a) == hex(of: b))
        }
    }

    @Test("Index past 4 cycles via modulo without crashing")
    func cyclesPastFourMetrics() {
        // `MetricKind.allCases` ships 18+ cases as of v0.5.2 (was 11 in
        // v0.5.0); position 4+ cycles back to ramp[0]. Operator surfaces
        // typically show 2-4 metrics overlaid — but the modulo path must
        // be safe (no out-of-bounds crash) for any future surface that
        // toggles all kinds on simultaneously.
        UserDefaults.standard.removeObject(forKey: "hl.settings.tint")
        let all = MetricKind.allCases
        #expect(all.count >= 5) // sanity — we have at least 5 metrics today

        // Position 4 should cycle back to position 0 (monochrome lead).
        if all.count > 4 {
            let fifth = TrendsOverlayCard.tint(for: all[4])
            #expect(hex(of: fifth) == 0xEBEBF5)
        }
        // Position 5 cycles to position 1 (graphite at ~0.80).
        if all.count > 5 {
            let sixth = TrendsOverlayCard.tint(for: all[5])
            #expect(abs(alpha(of: sixth) - 0.80) < 0.05)
        }
    }

    @Test("All MetricKind positions resolve to a tint in the multi-series ramp")
    func everyMetricResolvesToRampMember() {
        // Stability invariant: no metric kind should escape the ramp into a
        // raw `HLColor.*` or off-palette hex. Every tint returned by
        // `tint(for:)` must be one of the 4 canonical ramp positions —
        // anchors against drift if a maintainer adds a special-case
        // `if kind == .bloodPressure { return HLColor.red }` branch.
        let rampHexes = Set(HLChartTints.multiSeriesRamp.map { hex(of: $0) })
        for kind in MetricKind.allCases {
            let tintHex = hex(of: TrendsOverlayCard.tint(for: kind))
            #expect(rampHexes.contains(tintHex))
        }
    }
}
