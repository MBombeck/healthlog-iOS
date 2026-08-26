import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// W-B183 — DEFENSIVE glucose unit-at-source guard.
///
/// Server is moving toward "unit-at-source" (each measurement value carries
/// its own `unit`, targeted for server v1.17, NOT yet deployed). iOS hardcodes
/// mg/dL for the glucose domain (`MetricKind.glucose.unit == "mg/dL"`) and
/// every glucose surface interprets the domain scalar AS mg/dL. If the server
/// ever sent mmol/L for a glucose value, a naive read would misinterpret it by
/// the ~18× mg/dL↔mmol/L factor — a serious clinical-display bug.
///
/// This suite locks down the defensive contract in
/// `MeasurementWireDTO.glucoseMgdl(from:unit:)` + the glucose branch of
/// `toDomain()`:
///
/// - (a) ABSENT unit ⇒ today's mg/dL behaviour is UNCHANGED (verbatim
///       passthrough — the only case in production today).
/// - (b) EXPLICIT mmol/L ⇒ converted to mg/dL (×18.0182), no 18× misread.
/// - (c) UNKNOWN unit ⇒ SAFE: raw value returned UNSCALED, never a guessed
///       (and possibly 18× wrong) conversion.
@Suite("Glucose unit guard (W-B183)", .serialized)
struct GlucoseUnitGuardTests {
    /// IFCC factor mmol/L → mg/dL for glucose. Must match the production helper.
    private let mmolToMgdl = 18.0182

    private func glucoseWire(value: Double, unit: String?) -> MeasurementWireDTO {
        MeasurementWireDTO(
            id: "g1",
            type: .bloodGlucose,
            value: value,
            unit: unit,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - (a) Absent unit ⇒ today's mg/dL behaviour unchanged

    @Test("Absent unit passes the value through verbatim (production mg/dL path)")
    func absentUnitPassthrough_helper() {
        #expect(MeasurementWireDTO.glucoseMgdl(from: 95.0, unit: nil) == 95.0)
        #expect(MeasurementWireDTO.glucoseMgdl(from: 142.0, unit: nil) == 142.0)
    }

    @Test("Absent unit through toDomain yields the raw scalar (no scaling)")
    func absentUnitPassthrough_toDomain() throws {
        let domain = try #require(glucoseWire(value: 110.0, unit: nil).toDomain())
        #expect(domain.kind == .glucose)
        #expect(domain.primaryValue == 110.0)
        // The display unit stays the hardcoded mg/dL — value is already mg/dL.
        #expect(domain.kind.unit == "mg/dL")
    }

    @Test("Explicit mg/dL spellings pass through unchanged")
    func explicitMgdlPassthrough() {
        for unit in ["mg/dL", "mg/dl", "MG/DL", "mgdl", "mg dL"] {
            #expect(MeasurementWireDTO.glucoseMgdl(from: 100.0, unit: unit) == 100.0)
        }
    }

    // MARK: - (b) Explicit mmol/L ⇒ correct conversion, no 18× error

    @Test("Explicit mmol/L converts to mg/dL (×18.0182), no 18× misread")
    func mmolConvertsToMgdl_helper() {
        // 5.5 mmol/L is a normal fasting reading ≈ 99 mg/dL.
        let result = MeasurementWireDTO.glucoseMgdl(from: 5.5, unit: "mmol/L")
        #expect(abs(result - 5.5 * mmolToMgdl) < 0.0001)
        #expect(abs(result - 99.1001) < 0.01)
        // Crucially: NOT the raw 5.5 (which a hardcoded-mg/dL read would show as
        // an absurd "5.5 mg/dL"), and NOT a wrong divide.
        #expect(result > 90.0)
        #expect(result < 110.0)
    }

    @Test("mmol/L spelling variants all convert identically")
    func mmolSpellingVariants() {
        let expected = 7.0 * mmolToMgdl
        for unit in ["mmol/L", "mmol/l", "MMOL/L", "mmoll", "mmol", "mmol per L"] {
            let result = MeasurementWireDTO.glucoseMgdl(from: 7.0, unit: unit)
            #expect(abs(result - expected) < 0.0001)
        }
    }

    @Test("Explicit mmol/L through toDomain yields the converted mg/dL scalar")
    func mmolConvertsToMgdl_toDomain() throws {
        let domain = try #require(glucoseWire(value: 5.5, unit: "mmol/L").toDomain())
        #expect(domain.kind == .glucose)
        #expect(abs(domain.primaryValue - 5.5 * mmolToMgdl) < 0.0001)
    }

    // MARK: - (c) Unknown unit ⇒ safe (no wrong scaling)

    @Test("Unknown unit returns the raw value UNSCALED (never a guessed factor)")
    func unknownUnitSafePassthrough_helper() {
        for unit in ["g/L", "percent", "garbage", "µmol/L", ""] {
            // Whatever the server sends, we never apply an 18× factor on a unit
            // we don't recognise — we keep the raw number untouched.
            #expect(MeasurementWireDTO.glucoseMgdl(from: 5.5, unit: unit) == 5.5)
            #expect(MeasurementWireDTO.glucoseMgdl(from: 95.0, unit: unit) == 95.0)
        }
    }

    @Test("Unknown unit through toDomain never mis-scales by ~18×")
    func unknownUnitSafePassthrough_toDomain() throws {
        let raw = 95.0
        let domain = try #require(glucoseWire(value: raw, unit: "garbage").toDomain())
        #expect(domain.primaryValue == raw)
        // Hard guard against the clinical-display hazard: the value must NOT
        // have been multiplied or divided by the mmol↔mg/dL factor.
        #expect(domain.primaryValue != raw * mmolToMgdl)
        #expect(domain.primaryValue != raw / mmolToMgdl)
    }
}
