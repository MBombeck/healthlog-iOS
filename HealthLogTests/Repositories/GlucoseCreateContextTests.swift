import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// `POST /api/measurements` requires a glucose context on a BLOOD_GLUCOSE row
/// (`createMeasurementSchema` refine; 422 without one). Every app path that
/// creates a reading goes through `Measurement.toCreateDTOs()`: the capture
/// sheet, Siri, the watch and the outbox replay of a stored `Measurement`.
@Suite("Glucose context on create: RANDOM when none is given")
struct GlucoseCreateContextTests {
    private static func body(_ context: GlucoseContext?) throws -> String {
        let reading = Measurement(
            id: "local-glu",
            kind: .glucose,
            recordedAt: Date(timeIntervalSince1970: 1_780_000_000),
            value: .scalar(110),
            glucoseContext: context
        )
        let dto = try #require(reading.toCreateDTOs().first)
        return try #require(String(data: JSONEncoder.hlDefault.encode(dto), encoding: .utf8))
    }

    @Test("A glucose reading without a context goes out as RANDOM")
    func missingContextIsRandom() throws {
        #expect(try Self.body(nil).contains(#""glucoseContext":"RANDOM""#))
    }

    @Test("A chosen context goes out unchanged", arguments: GlucoseContext.allCases)
    func chosenContextKept(context: GlucoseContext) throws {
        #expect(try Self.body(context).contains(#""glucoseContext":"\#(context.rawValue)""#))
    }

    @Test("An outbox entry an older build stored without context replays as RANDOM")
    func storedReadingReplaysWithContext() throws {
        let stored = Measurement(
            id: "local-glu-old",
            kind: .glucose,
            recordedAt: Date(timeIntervalSince1970: 1_780_000_000),
            value: .scalar(98)
        )
        let decoded = try JSONDecoder.hlDefault.decode(HealthLog.Measurement.self, from: JSONEncoder.hlDefault.encode(stored))
        let dto = try #require(decoded.toCreateDTOs().first)
        #expect(dto.glucoseContext == .random)
    }

    @Test("Other kinds never carry a context")
    func otherKindsUntouched() {
        let weight = Measurement(id: "w", kind: .weight, recordedAt: .now, value: .scalar(72))
        #expect(weight.toCreateDTOs().allSatisfy { $0.glucoseContext == nil })
    }

    @Test("The capture sheet offers no \"no context\": the picker lists exactly the server's four")
    func pickerChoices() {
        #expect(GlucoseContext.allCases.map(\.rawValue) == ["FASTING", "POSTPRANDIAL", "RANDOM", "BEDTIME"])
    }

    // MARK: - Siri

    @Test("Shortcuts saved with \"before meal\" still resolve, now to RANDOM")
    func savedShortcutStillResolves() {
        #expect(GlucoseContextAppEnum(rawValue: "beforeMeal") == .beforeMeal)
        #expect(GlucoseContextAppEnum.beforeMeal.domainValue == .random)
        #expect(GlucoseContextAppEnum.afterMeal.domainValue == .afterMeal)
        #expect(GlucoseContextAppEnum.unspecified.domainValue == nil, "the create body then sends RANDOM")
        #expect(GlucoseContextAppEnum.allCases.map(\.rawValue) == ["unspecified", "fasting", "beforeMeal", "afterMeal", "bedtime"])
        #expect(GlucoseContextAppEnum.caseDisplayRepresentations.count == GlucoseContextAppEnum.allCases.count)
    }
}

// swiftlint:enable force_unwrapping
