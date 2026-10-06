// App-Target-Symbol (`SegmentFitProbe`) — nicht in der SPM-Library.
#if !SWIFT_PACKAGE

    import CoreGraphics
    @testable import HealthLog
    import Testing

    /// **K1 — segments only while no label is cut.** The widths are the ones
    /// measured on iOS 26.5 in the cycle capture sheet (17 Pro Max form row
    /// 359 pt, SE 295 pt; „Periode gestartet" 104 pt, „Schmierblutung" 95 pt at
    /// the segment font).
    @Suite("K1 — SegmentFitProbe")
    struct HLAdaptiveSegmentedPickerTests {
        @Test("Period row: segments on the large device, menu on the SE")
        func periodRow() {
            let required = SegmentFitProbe.requiredWidth(labelWidths: [96, 104, 98])
            #expect(required <= 359)
            #expect(required > 295)
        }

        @Test("Flow row: five equal segments cannot hold „Schmierblutung\" even on the large device")
        func flowRow() {
            let required = SegmentFitProbe.requiredWidth(labelWidths: [36, 95, 38, 38, 34])
            #expect(required > 359)
        }

        @Test("Equal segments: the widest label decides, not the sum")
        func widestDecides() {
            // Sum 241 would fit 300; five segments of the widest (95) do not.
            #expect(SegmentFitProbe.requiredWidth(labelWidths: [36, 95, 38, 38, 34]) > 300)
        }
    }
#endif
