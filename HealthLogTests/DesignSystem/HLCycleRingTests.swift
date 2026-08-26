@testable import HealthLog
import Testing

/// Pure geometry/helper tests for `HLCycleRing` — day→angle mapping and
/// segment→arc mapping. No rendering / no SwiftUI host (the helpers are
/// `nonisolated static` precisely so they verify in a plain Swift-Testing suite).
@Suite("HLCycleRing geometry")
struct HLCycleRingTests {
    // MARK: - dayToAngle

    @Test("Day 1 sits at the very top (mid of the first bin)")
    func dayOneNearTop() {
        // Day 1 occupies [0, 1/28); its centre is at 0.5/28 of 360°.
        let angle = HLCycleRing.dayToAngle(day: 1, cycleLength: 28)
        #expect(abs(angle - (0.5 / 28.0 * 360.0)) < 0.0001)
    }

    @Test("Mid-cycle day lands roughly opposite the top")
    func midCycleOpposite() {
        // Day 14 of 28: centre = 13.5/28 ≈ 0.482 → ~173.6°, just shy of 180°.
        let angle = HLCycleRing.dayToAngle(day: 14, cycleLength: 28)
        #expect(angle > 165 && angle < 180)
    }

    @Test("Last day lands near a full turn but below 360°")
    func lastDayBelowFullTurn() {
        let angle = HLCycleRing.dayToAngle(day: 28, cycleLength: 28)
        #expect(angle > 350 && angle < 360)
    }

    @Test("Day below 1 clamps to day 1")
    func dayClampsLow() {
        let angle = HLCycleRing.dayToAngle(day: 0, cycleLength: 28)
        let day1 = HLCycleRing.dayToAngle(day: 1, cycleLength: 28)
        #expect(angle == day1)
    }

    @Test("Day above length clamps to the last day")
    func dayClampsHigh() {
        let angle = HLCycleRing.dayToAngle(day: 99, cycleLength: 28)
        let last = HLCycleRing.dayToAngle(day: 28, cycleLength: 28)
        #expect(angle == last)
    }

    @Test("Zero/negative cycle length is treated as length 1 without crashing")
    func degenerateLength() {
        let angle = HLCycleRing.dayToAngle(day: 1, cycleLength: 0)
        #expect(abs(angle - 180.0) < 0.0001) // single bin → centre at 0.5 → 180°
    }

    // MARK: - dayRangeToArc

    @Test("Full-cycle range maps to the whole circle 0...1")
    func fullCycleArc() {
        let arc = HLCycleRing.dayRangeToArc(range: 1 ... 28, cycleLength: 28)
        #expect(abs(arc.start - 0) < 0.0001)
        #expect(abs(arc.end - 1) < 0.0001)
    }

    @Test("Menstrual 1...5 of 28 maps to [0, 5/28)")
    func menstrualArc() {
        let arc = HLCycleRing.dayRangeToArc(range: 1 ... 5, cycleLength: 28)
        #expect(abs(arc.start - 0) < 0.0001)
        #expect(abs(arc.end - (5.0 / 28.0)) < 0.0001)
    }

    @Test("Adjacent segments tile without gap or overlap")
    func segmentsTile() {
        let a = HLCycleRing.dayRangeToArc(range: 1 ... 5, cycleLength: 28)
        let b = HLCycleRing.dayRangeToArc(range: 6 ... 12, cycleLength: 28)
        // The end of segment a equals the start of segment b (no seam).
        #expect(abs(a.end - b.start) < 0.0001)
    }

    @Test("Range is clamped into the cycle bounds")
    func arcClamps() {
        let arc = HLCycleRing.dayRangeToArc(range: 25 ... 99, cycleLength: 28)
        #expect(abs(arc.start - (24.0 / 28.0)) < 0.0001)
        #expect(abs(arc.end - 1.0) < 0.0001)
    }

    @Test("Inverted range collapses to a valid ordered arc")
    func invertedRange() {
        // lowerBound clamps, then upperBound is forced >= lo.
        let arc = HLCycleRing.dayRangeToArc(range: 10 ... 10, cycleLength: 28)
        #expect(arc.end >= arc.start)
        #expect(abs(arc.start - (9.0 / 28.0)) < 0.0001)
        #expect(abs(arc.end - (10.0 / 28.0)) < 0.0001)
    }

    // MARK: - Model invariants

    @Test("Model clamps dayOfCycle into 1...cycleLength")
    func modelClampsDay() {
        let over = HLCycleRing.Model(
            cycleLengthDays: 28, dayOfCycle: 99, segments: [],
            centerTitle: "", centerSubtitle: ""
        )
        #expect(over.dayOfCycle == 28)

        let under = HLCycleRing.Model(
            cycleLengthDays: 28, dayOfCycle: 0, segments: [],
            centerTitle: "", centerSubtitle: ""
        )
        #expect(under.dayOfCycle == 1)
    }
}

// MARK: - Glow math

/// Pure tests for the additive-glow helpers (`HLCycleRingGlowMath`) — the
/// breathing curve, lerp, and the marker anchor vector. No SwiftUI host.
@Suite("HLCycleRing glow math")
struct HLCycleRingGlowMathTests {
    @Test("Breath at t=0 sits at the visual mean (0.5) — the Reduce-Motion still")
    func breathMeanAtZero() {
        #expect(abs(HLCycleRingGlowMath.breath(0) - 0.5) < 0.0001)
    }

    @Test("Breath stays within 0...1 across a full period")
    func breathBounded() {
        for step in 0 ... 100 {
            let t = Double(step) / 100.0 * 5.5
            let b = HLCycleRingGlowMath.breath(t)
            #expect(b >= 0 && b <= 1)
        }
    }

    @Test("Breath peaks at a quarter period and troughs at three-quarters")
    func breathPhase() {
        let period = 5.5
        #expect(abs(HLCycleRingGlowMath.breath(period / 4, period: period) - 1.0) < 0.0001)
        #expect(abs(HLCycleRingGlowMath.breath(3 * period / 4, period: period) - 0.0) < 0.0001)
    }

    @Test("Lerp endpoints and midpoint")
    func lerpBasics() {
        #expect(abs(HLCycleRingGlowMath.lerp(0.16, 0.30, 0) - 0.16) < 0.0001)
        #expect(abs(HLCycleRingGlowMath.lerp(0.16, 0.30, 1) - 0.30) < 0.0001)
        #expect(abs(HLCycleRingGlowMath.lerp(0.16, 0.30, 0.5) - 0.23) < 0.0001)
    }

    @Test("Marker unit vector for day 1 points straight up (12 o'clock)")
    func markerDayOnePointsUp() {
        // Day 1 sits just past the top; the vector is near (0, -1).
        let v = HLCycleRingGlowMath.markerUnitVector(day: 1, cycleLength: 28)
        #expect(v.dy < 0) // upward in screen space
        #expect(abs(v.dx) < 0.2) // near the vertical axis
    }

    @Test("Marker unit vector is a unit vector (length 1)")
    func markerUnitLength() {
        let v = HLCycleRingGlowMath.markerUnitVector(day: 14, cycleLength: 28)
        let len = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        #expect(abs(len - 1.0) < 0.0001)
    }

    @Test("Marker near mid-cycle points roughly downward")
    func markerMidCyclePointsDown() {
        let v = HLCycleRingGlowMath.markerUnitVector(day: 14, cycleLength: 28)
        #expect(v.dy > 0) // bottom half of the dial
    }
}
