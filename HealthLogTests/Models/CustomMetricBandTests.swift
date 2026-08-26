import Foundation
@testable import HealthLog
import Testing

/// **Target-band logic, display formatting and the client-side editor guards.**
///
/// The target window is the USER'S OWN "good range", charted as a neutral band.
/// Both bounds are independently optional and, per the labs doctrine this
/// mirrors, bounds are INCLUSIVE. These tests pin the classification at every
/// boundary and for every combination of present/absent bounds — the exact spot
/// where an off-by-one reads as "you missed your goal" when the user hit it.
@Suite("Custom metric — target band + formatting")
struct CustomMetricBandTests {
    private static func metric(
        low: Double? = nil,
        high: Double? = nil,
        unit: String = "kg",
        decimals: Int? = nil
    ) -> CustomMetricDTO {
        CustomMetricDTO(id: "cm-1", name: "Griffkraft", unit: unit, targetLow: low, targetHigh: high, decimals: decimals)
    }

    // MARK: - Two-sided window

    @Test("A value inside a two-sided window is inBand")
    func insideTwoSidedWindow() {
        #expect(Self.metric(low: 40, high: 60).bandStatus(for: 50) == .inBand)
    }

    @Test("Bounds are INCLUSIVE — a value exactly on either bound is inBand")
    func boundsAreInclusive() {
        let m = Self.metric(low: 40, high: 60)
        #expect(m.bandStatus(for: 40) == .inBand, "a value on the low bound has met the goal, not missed it")
        #expect(m.bandStatus(for: 60) == .inBand, "a value on the high bound is still within the window")
    }

    @Test("Values outside a two-sided window classify below / above")
    func outsideTwoSidedWindow() {
        let m = Self.metric(low: 40, high: 60)
        #expect(m.bandStatus(for: 39.9) == .below)
        #expect(m.bandStatus(for: 60.1) == .above)
    }

    // MARK: - One-sided windows

    @Test("A low-only window treats anything at or above the bound as inBand")
    func lowOnlyWindow() {
        let m = Self.metric(low: 40, high: nil)
        #expect(m.bandStatus(for: 39.9) == .below)
        #expect(m.bandStatus(for: 40) == .inBand)
        #expect(m.bandStatus(for: 10000) == .inBand, "with no upper bound there is no such thing as too high")
    }

    @Test("A high-only window treats anything at or below the bound as inBand")
    func highOnlyWindow() {
        let m = Self.metric(low: nil, high: 60)
        #expect(m.bandStatus(for: 60.1) == .above)
        #expect(m.bandStatus(for: 60) == .inBand)
        #expect(m.bandStatus(for: -50) == .inBand, "with no lower bound there is no such thing as too low")
    }

    // MARK: - Degenerate cases

    @Test("No bound at all resolves to unknown")
    func noBandIsUnknown() {
        let m = Self.metric()
        #expect(m.bandStatus(for: 50) == .unknown)
        #expect(m.hasTargetBand == false)
    }

    @Test("An absent reading is unknown regardless of the band")
    func absentValueIsUnknown() {
        #expect(Self.metric(low: 40, high: 60).bandStatus(for: nil) == .unknown)
    }

    @Test("A non-finite reading is unknown rather than misclassified")
    func nonFiniteValueIsUnknown() {
        let m = Self.metric(low: 40, high: 60)
        #expect(m.bandStatus(for: .nan) == .unknown)
        #expect(m.bandStatus(for: .infinity) == .unknown)
    }

    @Test("An inverted legacy window resolves to unknown, never to both below and above")
    func invertedWindowIsUnknown() {
        // Neither the client nor the server can create this, but a legacy row
        // could carry it. Reporting a value as simultaneously below and above
        // would be worse than admitting we cannot classify it.
        let m = Self.metric(low: 60, high: 40)
        #expect(m.bandStatus(for: 50) == .unknown)
        #expect(m.bandStatus(for: 10) == .unknown)
    }

    @Test("A zero-width window admits exactly its single value")
    func zeroWidthWindow() {
        let m = Self.metric(low: 50, high: 50)
        #expect(m.bandStatus(for: 50) == .inBand)
        #expect(m.bandStatus(for: 49.9) == .below)
        #expect(m.bandStatus(for: 50.1) == .above)
    }

    // MARK: - Entry classification

    @Test("An entry classifies against the metric's CURRENT window")
    func entryClassifiesAgainstLiveWindow() {
        // The band is a live property of the definition (unlike `unit`, which is
        // snapshotted per row), so moving your own goalposts re-classifies the
        // whole history — which is what the user means by editing it.
        let entry = CustomMetricEntryDTO(
            id: "e-1", customMetricId: "cm-1", value: 50, unit: "kg",
            measuredAt: "2026-07-02T07:30:00.000Z"
        )
        #expect(entry.bandStatus(in: Self.metric(low: 40, high: 60)) == .inBand)
        #expect(entry.bandStatus(in: Self.metric(low: 55, high: 60)) == .below)
    }

    @Test("latestBandStatus reads the embedded latest value")
    func latestBandStatusUsesLatest() {
        let metric = CustomMetricDTO(
            id: "cm-1", name: "A", unit: "kg", targetLow: 40, targetHigh: 60,
            latest: CustomMetricLatestDTO(value: 70, unit: "kg", measuredAt: "2026-07-02T07:30:00.000Z"),
            entryCount: 1
        )
        #expect(metric.latestBandStatus == .above)
    }

    // MARK: - Display formatting

    @Test("An absent reading renders the em-dash placeholder, never a zero")
    func absentRendersPlaceholder() {
        #expect(CustomMetricFormat.text(value: nil, unit: "kg", decimals: nil) == CustomMetricFormat.absentPlaceholder)
    }

    @Test("A reading renders with its unit; a blank unit renders the bare number")
    func unitRendering() {
        let withUnit = CustomMetricFormat.text(value: 47, unit: "kg", decimals: 0)
        #expect(withUnit.hasSuffix(" kg"))
        let withoutUnit = CustomMetricFormat.text(value: 47, unit: "", decimals: 0)
        #expect(!withoutUnit.contains(" "), "a blank unit must not leave a trailing space")
    }

    @Test("decimals: 0 renders no fraction; a positive decimals renders one")
    func decimalsHonoured() {
        // Asserted structurally rather than against a literal string — the
        // decimal separator is locale-dependent and the test must not be.
        let zero = CustomMetricFormat.number(1.23456, decimals: 0)
        #expect(zero.count == 1, "0 decimals on 1.23456 must render a single digit")
        let two = CustomMetricFormat.number(1.23456, decimals: 2)
        #expect(two.count == 4, "2 decimals renders digit + separator + 2 digits")
    }

    @Test("An out-of-range decimals is clamped rather than trusted")
    func decimalsClamped() {
        // The server caps `decimals` at 0...6; a rogue stored value must not
        // make Foundation throw or render 400 digits.
        let high = CustomMetricFormat.number(1.5, decimals: 99)
        #expect(high.count <= 10)
        let negative = CustomMetricFormat.number(1.5, decimals: -3)
        #expect(negative.count == 1, "a negative decimals clamps to 0")
    }

    @Test("The latest value renders with the ENTRY's unit, not the definition's")
    func latestUsesSnapshottedUnit() {
        // The unit is historical truth per row: renaming the metric's unit must
        // not relabel a value that was logged under the old one.
        let metric = CustomMetricDTO(
            id: "cm-1", name: "A", unit: "lbs", decimals: 0,
            latest: CustomMetricLatestDTO(value: 47, unit: "kg", measuredAt: "2026-07-02T07:30:00.000Z"),
            entryCount: 1
        )
        #expect(metric.latestDisplayValue.hasSuffix(" kg"))
    }

    @Test("targetBandDescription reflects which bounds are present")
    func bandDescriptionShape() {
        #expect(Self.metric(low: 40, high: 60, decimals: 0).targetBandDescription?.contains("–") == true)
        #expect(Self.metric(low: 40, decimals: 0).targetBandDescription?.hasPrefix("≥") == true)
        #expect(Self.metric(high: 60, decimals: 0).targetBandDescription?.hasPrefix("≤") == true)
        #expect(Self.metric().targetBandDescription == nil)
    }

    // MARK: - Editor validation

    @Test("A valid definition passes validation")
    func validationAccepts() {
        let failure = CustomMetricValidation.validate(
            name: "Griffkraft", unit: "kg", targetLow: 40, targetHigh: 60, decimals: 1, description: nil
        )
        #expect(failure == nil)
    }

    @Test("Blank or whitespace-only name and unit are rejected")
    func validationRejectsEmptyIdentity() {
        #expect(CustomMetricValidation.validate(
            name: "   ", unit: "kg", targetLow: nil, targetHigh: nil, decimals: nil, description: nil
        ) == .nameEmpty)
        #expect(CustomMetricValidation.validate(
            name: "A", unit: "  ", targetLow: nil, targetHigh: nil, decimals: nil, description: nil
        ) == .unitEmpty)
    }

    @Test("Over-long name and unit are rejected at the server's own limits")
    func validationRejectsOverLongIdentity() {
        #expect(CustomMetricValidation.validate(
            name: String(repeating: "a", count: 121), unit: "kg",
            targetLow: nil, targetHigh: nil, decimals: nil, description: nil
        ) == .nameTooLong)
        #expect(CustomMetricValidation.validate(
            name: "A", unit: String(repeating: "k", count: 41),
            targetLow: nil, targetHigh: nil, decimals: nil, description: nil
        ) == .unitTooLong)
    }

    @Test("An inverted target band is caught before the round-trip")
    func validationRejectsInvertedBand() {
        #expect(CustomMetricValidation.validate(
            name: "A", unit: "kg", targetLow: 60, targetHigh: 40, decimals: nil, description: nil
        ) == .invertedTargetBand)
    }

    @Test("Equal bounds are accepted — a zero-width window is legal")
    func validationAcceptsEqualBounds() {
        #expect(CustomMetricValidation.validate(
            name: "A", unit: "kg", targetLow: 50, targetHigh: 50, decimals: nil, description: nil
        ) == nil)
    }

    @Test("decimals outside 0...6 is rejected")
    func validationRejectsBadDecimals() {
        #expect(CustomMetricValidation.validate(
            name: "A", unit: "kg", targetLow: nil, targetHigh: nil, decimals: 7, description: nil
        ) == .decimalsOutOfRange)
        #expect(CustomMetricValidation.validate(
            name: "A", unit: "kg", targetLow: nil, targetHigh: nil, decimals: -1, description: nil
        ) == .decimalsOutOfRange)
    }

    @Test("A one-sided band passes validation")
    func validationAcceptsOneSidedBand() {
        #expect(CustomMetricValidation.validate(
            name: "A", unit: "kg", targetLow: 40, targetHigh: nil, decimals: nil, description: nil
        ) == nil)
    }
}
