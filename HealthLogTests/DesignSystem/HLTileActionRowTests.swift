// App-Target-Symbol (`HLTileActionRow`) — nicht in der SPM-Library.
#if !SWIFT_PACKAGE

    import CoreGraphics
    @testable import HealthLog
    import Testing

    /// **K1 — tile actions stack before a label breaks.**
    ///
    /// The case H2 photographed on the iPhone SE is the one this suite is
    /// named after: the two labels fit the card *by sum*, so an `HStack` (or
    /// `ViewThatFits` over one) keeps them side by side, and the longer label
    /// still breaks because each button only gets half.
    @Suite("K1 — HLTileActionRow")
    struct HLTileActionRowTests {
        @Test("Both labels fit their half: the row stays (large device, default size)")
        func fittingPairStaysARow() {
            // 17 Pro Max card: ~370 pt inside; „Genommen" 135, „Übersprungen" 155.
            #expect(HLTileActionRow.arrangement(idealWidths: [135, 155], spacing: 8, available: 370) == .row)
        }

        @Test("Fits by sum, not by half: stacks (the SE case H2 photographed)")
        func fitsBySumButNotByHalfStacks() {
            // SE card: ~311 pt inside. 135 + 8 + 155 = 298 fits, but each half
            // is 151.5 and „Übersprungen" needs 155.
            #expect(135 + 8 + 155 <= 311)
            #expect(HLTileActionRow.arrangement(idealWidths: [135, 155], spacing: 8, available: 311) == .column)
        }

        @Test("Accessibility sizes: stacks")
        func accessibilitySizeStacks() {
            #expect(HLTileActionRow.arrangement(idealWidths: [260, 330], spacing: 8, available: 370) == .column)
        }

        @Test("An ideal-size query and a single button are always a row")
        func idealAndSingleAreRows() {
            #expect(HLTileActionRow.arrangement(idealWidths: [135, 155], spacing: 8, available: nil) == .row)
            #expect(HLTileActionRow.arrangement(idealWidths: [400], spacing: 8, available: 300) == .row)
        }

        @Test("A rounding-error overflow does not flip the arrangement")
        func roundingSlack() {
            #expect(HLTileActionRow.arrangement(idealWidths: [100, 151.8], spacing: 8, available: 311) == .row)
        }
    }
#endif
