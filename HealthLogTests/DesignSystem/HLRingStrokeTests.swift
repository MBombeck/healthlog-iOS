import CoreGraphics
import Foundation
@testable import HealthLog
import Testing

/// Locks the **Withings stroke proportion** for `HLRing` — 8.5 % of the ring's
/// shorter side, with a hard floor at 6 pt to prevent „Faden"-Optik bei
/// Mini-Rings (Skeleton placeholders, future 1×1-Tile activity rings).
///
/// Vertragsgrundlage: `.planning/v05x-marathon/R2-visual-design-spec.md` §
/// "Primitive #2 — HLRing". Die Funktion ist als pure `static` extrahiert,
/// damit hier ohne SwiftUI-Host getestet werden kann.
///
/// Cross-screen consistency: jeder Ring app-wide (`HealthScoreTile` 92 pt,
/// `ComplianceRingCard` 92 pt, hypothetische 60 pt Activity-Mini-Rings, 140 pt
/// Hero-Variante) bezieht seine Linienstärke aus dieser einen Quelle — bricht
/// dieser Test, bricht das Rhythm-Gefühl auf allen Surfaces gleichzeitig.
@Suite("HLRing stroke derivation contract")
struct HLRingStrokeTests {
    @Test("60 pt ring clamps to 6 pt floor (rohwert 5.1 → floor)")
    func smallRing() {
        // Roh: 60 × 0.085 = 5.1, aber unterhalb der 6-pt-Floor — schützt
        // Mini-Rings (Skeleton, hypothetische 1×1-Tile-Activity-Rings) vor
        // "Faden-Optik". Boundary liegt bei side ≈ 70.59.
        let stroke = HLRing.derivedStroke(forSide: 60)
        #expect(stroke == 6)
    }

    @Test("92 pt ring → ~7.82 pt stroke (HealthScore + Compliance)")
    func tileRing() {
        // Beide produktiven Callsites (`HealthScoreLoaded`, `ComplianceRingCard`)
        // setzen `.frame(width: 92, height: 92)` — dieser Test sichert genau
        // den Wert, den der Operator auf seinem iPhone sieht.
        let stroke = HLRing.derivedStroke(forSide: 92)
        #expect(abs(stroke - 7.82) < 0.01)
    }

    @Test("140 pt ring → ~11.9 pt stroke (Hero variant)")
    func heroRing() {
        let stroke = HLRing.derivedStroke(forSide: 140)
        #expect(abs(stroke - 11.9) < 0.01)
    }

    @Test("32 pt micro ring clamps to 6 pt floor (not 2.72 pt)")
    func microRingFloor() {
        // 32 × 0.085 = 2.72, das wäre als Stroke „Faden-Optik". Der `max(6, …)`-
        // Floor schützt Skeleton-Placeholder und potentielle 1×1-Tile-Rings.
        let stroke = HLRing.derivedStroke(forSide: 32)
        #expect(stroke == 6)
    }

    @Test("70.59 pt boundary ring exactly hits the 6 pt floor")
    func boundaryRing() {
        // side × 0.085 == 6 ⇒ side == 70.5882…  — direkt unter dieser Schwelle
        // greift der Floor, direkt darüber die Proportion.
        let belowBoundary = HLRing.derivedStroke(forSide: 70)
        let aboveBoundary = HLRing.derivedStroke(forSide: 72)
        #expect(belowBoundary == 6)
        #expect(abs(aboveBoundary - 6.12) < 0.01)
    }

    @Test("strokeRatio constant matches Withings 8.5 % reference")
    func strokeRatioConstant() {
        // Lock auf 8.5 % — bricht dieser Test, hat jemand die Proportion
        // angefasst ohne R2-Spec-Update.
        #expect(HLRing.strokeRatio == 0.085)
        #expect(HLRing.minStroke == 6)
    }
}
