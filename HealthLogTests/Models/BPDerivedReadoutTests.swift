@testable import HealthLog
import Testing

/// Pure-function tests for the BP pulse-pressure / mean-arterial-pressure
/// derivation (web v1.18.6 parity). Locks the arithmetic + the self-suppress
/// guards against the web reference (`blood-pressure/page.tsx`).
@Suite("BP derived readout (pulse pressure + MAP)")
struct BPDerivedReadoutTests {
    @Test("120/80 → PP 40, MAP 93")
    func textbook() {
        let r = BPDerivedReadout.derive(systolic: 120, diastolic: 80)
        // PP = 120 − 80 = 40. MAP = (120 + 160)/3 = 93.33 → 93.
        #expect(r?.pulsePressure == 40)
        #expect(r?.meanArterialPressure == 93)
    }

    @Test("Both MAP forms agree: (SYS+2·DIA)/3 == DIA + (SYS−DIA)/3")
    func mapFormsAgree() {
        let r = BPDerivedReadout.derive(systolic: 140, diastolic: 90)
        // (140 + 180)/3 = 106.67 → 107; 90 + 50/3 = 106.67 → 107.
        #expect(r?.pulsePressure == 50)
        #expect(r?.meanArterialPressure == 107)
    }

    @Test("Rounding matches web Math.round at the .5 boundary")
    func rounding() {
        // 130/85: PP = 45; MAP = (130 + 170)/3 = 100 exactly.
        let r = BPDerivedReadout.derive(systolic: 130, diastolic: 85)
        #expect(r?.pulsePressure == 45)
        #expect(r?.meanArterialPressure == 100)
    }

    @Test("Inverted reading (sys <= dia) self-suppresses")
    func inverted() {
        #expect(BPDerivedReadout.derive(systolic: 80, diastolic: 120) == nil)
        #expect(BPDerivedReadout.derive(systolic: 100, diastolic: 100) == nil)
    }

    @Test("Missing systolic or diastolic self-suppresses")
    func missing() {
        #expect(BPDerivedReadout.derive(systolic: 120, diastolic: nil) == nil)
        #expect(BPDerivedReadout.derive(systolic: nil, diastolic: 80) == nil)
        #expect(BPDerivedReadout.derive(systolic: nil, diastolic: nil) == nil)
    }

    @Test("Non-finite inputs self-suppress")
    func nonFinite() {
        #expect(BPDerivedReadout.derive(systolic: .nan, diastolic: 80) == nil)
        #expect(BPDerivedReadout.derive(systolic: 120, diastolic: .infinity) == nil)
    }
}
