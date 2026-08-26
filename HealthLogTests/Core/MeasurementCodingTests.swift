import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

@Suite("MeasurementValue Coding")
struct MeasurementValueCodingTests {
    @Test("Scalar encodes to scalar key")
    func scalarRoundTrip() throws {
        let value = MeasurementValue.scalar(72.4)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(MeasurementValue.self, from: data)
        #expect(decoded == .scalar(72.4))
    }

    @Test("Blood pressure encodes to systolic+diastolic keys")
    func bpRoundTrip() throws {
        let value = MeasurementValue.bloodPressure(systolic: 120, diastolic: 80)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(MeasurementValue.self, from: data)
        #expect(decoded == .bloodPressure(systolic: 120, diastolic: 80))
    }

    @Test("Decoding empty payload throws")
    func emptyThrows() {
        let json = Data("{}".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MeasurementValue.self, from: json)
        }
    }

    @Test("Severity respects critical bounds")
    func severity() {
        let m = Measurement(
            id: "1",
            kind: .bloodPressure,
            recordedAt: .now,
            value: .bloodPressure(systolic: 180, diastolic: 100)
        )
        let range = EffectiveRange(
            kind: .bloodPressure,
            warnLow: 90, warnHigh: 140,
            criticalLow: 70, criticalHigh: 170
        )
        #expect(m.severity(against: range) == .critical)
    }

    @Test("Severity returns ok without range")
    func severityOk() {
        let m = Measurement(id: "1", kind: .weight, recordedAt: .now, value: .scalar(72.4))
        #expect(m.severity(against: nil) == .ok)
    }
}
