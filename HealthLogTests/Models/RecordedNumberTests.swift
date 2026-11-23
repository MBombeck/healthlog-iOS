import Foundation
@testable import HealthLog
import Testing

/// The cases of the server's `format-value.test.ts`, so a lab reading reads
/// the same in the app as on the web.
@Suite("Recorded number precision")
struct RecordedNumberTests {
    private static let german = Locale(identifier: "de_DE")
    private static let english = Locale(identifier: "en_US")

    private func de(_ value: Double, printed: Double? = nil) -> String {
        RecordedNumber.text(value, printed: printed, locale: Self.german)
    }

    private func en(_ value: Double, printed: Double? = nil) -> String {
        RecordedNumber.text(value, printed: printed, locale: Self.english)
    }

    @Test("Keeps every recorded digit and prints the locale's separator")
    func keepsRecordedDigits() {
        #expect(de(1.8) == "1,8")
        #expect(en(1.8) == "1.8")
        #expect(de(0.123456) == "0,123456")
        #expect(de(12.3456) == "12,3456")
        #expect(de(5) == "5")
        #expect(en(4.20) == "4.2")
    }

    @Test("Never shows a small nonzero reading as zero or shortened")
    func keepsSmallReadings() {
        #expect(de(0.004) == "0,004")
        #expect(en(0.012) == "0.012")
        #expect(de(0.035) == "0,035")
        #expect(en(0.034) == "0.034")
        #expect(en(0.0012) == "0.0012")
        #expect(en(0.00001) == "0.00001")
        #expect(en(-0.004) == "-0.004")
    }

    @Test("Drops binary floating-point noise, never a recorded digit")
    func dropsBinaryNoise() {
        #expect(en(0.1 + 0.2) == "0.3")
        #expect(en(1234.5678) == "1,234.5678")
        #expect(en(0) == "0")
    }

    @Test("Prints a converted reading with the precision its report printed")
    func convertedReadingFollowsPrintedFigure() {
        // 5.2 mmol/L of cholesterol converted to mg/dL.
        #expect(en(5.2 * 38.67, printed: 5.2) == "201")
        // A four-digit report figure keeps four significant digits.
        #expect(en(5.234 * 38.67, printed: 5.234) == "202.4")
        // Never fewer digits than the integer part.
        #expect(en(12.5 * 88.4, printed: 12.5) == "1,105")
    }

    @Test("The lab reading line uses the rule and keeps its unit")
    func labReadingLine() {
        #expect(LabValueDisplay.text(value: 0.004, valueText: nil, unit: "mIU/L", locale: Self.german) == "0,004 mIU/L")
        #expect(
            LabValueDisplay.text(value: 5.2 * 38.67, valueText: nil, unit: "mg/dL", printed: 5.2, locale: Self.english)
                == "201 mg/dL"
        )
        #expect(LabValueDisplay.text(value: nil, valueText: "negativ", unit: "", locale: Self.german) == "negativ")
    }
}
