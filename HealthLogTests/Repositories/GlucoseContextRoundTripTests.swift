import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping force_try

/// T-2 Glucose-context picker. Pre-T-2 die Domain-`Measurement`-Struktur
/// trug keinen `glucoseContext` — der Server-Wire-Wert wurde in
/// `MeasurementWireDTO.toDomain()` silently dropped, sodass Chart-
/// Grouper + Edit-Sheets nie wussten, ob ein Glucose-Reading nüchtern,
/// vor/nach einer Mahlzeit oder zur Schlafenszeit gemessen wurde.
///
/// Diese Suite lockt den Round-Trip fest:
///
/// - `GlucoseContext`-Enum hat vier wire-stabile Cases (FASTING,
///   BEFORE_MEAL, AFTER_MEAL, BEDTIME) und ein lokalisierbares Display.
/// - `MeasurementWireDTO.toDomain()` hydriert `glucoseContext` aufs
///   Domain-Model.
/// - `Measurement.toCreateDTOs()` propagiert `glucoseContext` auf die
///   Wire-Create-DTO, wenn `kind == .glucose`.
/// - JSON-Codable-Round-Trip (Wire → Domain → Wire) erhält den Wert.
@Suite("GlucoseContext round-trip (T-2)", .serialized)
struct GlucoseContextRoundTripTests {
    // MARK: - 1. Enum cases are stable + wire-mapped

    @Test("GlucoseContext maps to the documented server wire values")
    func enumWireMapping() {
        #expect(GlucoseContext.fasting.rawValue == "FASTING")
        #expect(GlucoseContext.beforeMeal.rawValue == "BEFORE_MEAL")
        #expect(GlucoseContext.afterMeal.rawValue == "AFTER_MEAL")
        #expect(GlucoseContext.bedtime.rawValue == "BEDTIME")
    }

    @Test("GlucoseContext is CaseIterable so picker UIs can ForEach over it")
    func caseIterable() {
        let all = GlucoseContext.allCases
        #expect(all.count == 4)
        #expect(Set(all) == Set([.fasting, .beforeMeal, .afterMeal, .bedtime]))
    }

    @Test("GlucoseContext.Identifiable matches rawValue")
    func identifiable() {
        for context in GlucoseContext.allCases {
            #expect(context.id == context.rawValue)
        }
    }

    // MARK: - 2. JSON round-trip

    @Test("GlucoseContext encodes + decodes back to the same case (JSON)")
    func jsonRoundTrip() throws {
        for original in GlucoseContext.allCases {
            let data = try JSONEncoder.hlDefault.encode(original)
            let decoded = try JSONDecoder.hlDefault.decode(GlucoseContext.self, from: data)
            #expect(decoded == original)
            // Wire is a bare string — JSON output should be a quoted SCREAMING_SNAKE.
            let str = try #require(String(data: data, encoding: .utf8))
            #expect(str == "\"\(original.rawValue)\"")
        }
    }

    // MARK: - 3. Wire DTO → Domain hydration

    @Test("MeasurementWireDTO.toDomain() carries glucoseContext through")
    func wireToDomainHydratesContext() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let wire = MeasurementWireDTO(
            id: "srv-glu-1",
            userId: "u1",
            type: .bloodGlucose,
            value: 95,
            measuredAt: now,
            notes: "fasted 12h",
            source: .manual,
            glucoseContext: .fasting,
            externalId: nil,
            createdAt: now,
            updatedAt: now
        )
        let domain = try #require(wire.toDomain())
        #expect(domain.kind == .glucose)
        #expect(domain.glucoseContext == .fasting)
        #expect(domain.primaryValue == 95)
    }

    @Test("Domain hydration leaves glucoseContext nil when server omits it")
    func wireToDomainNilContext() throws {
        let wire = MeasurementWireDTO(
            id: "srv-glu-2",
            type: .bloodGlucose,
            value: 110,
            measuredAt: .now
        )
        let domain = try #require(wire.toDomain())
        #expect(domain.glucoseContext == nil)
    }

    @Test("Non-glucose measurements never carry a context")
    func nonGlucoseStaysContextless() throws {
        let weightWire = MeasurementWireDTO(
            id: "srv-w-1",
            type: .weight,
            value: 72.4,
            measuredAt: .now
        )
        #expect(try #require(weightWire.toDomain()).glucoseContext == nil)
    }

    // MARK: - 4. Domain → Create DTO propagation

    @Test("Measurement.toCreateDTOs() propagates glucoseContext for glucose rows")
    func domainToCreateDTOPropagatesContext() throws {
        let measurement = Measurement(
            id: "local-1",
            kind: .glucose,
            recordedAt: .now,
            value: .scalar(120),
            note: nil,
            source: .manual,
            glucoseContext: .afterMeal
        )
        let dtos = measurement.toCreateDTOs()
        #expect(dtos.count == 1)
        let dto = try #require(dtos.first)
        #expect(dto.type == .bloodGlucose)
        #expect(dto.value == 120)
        #expect(dto.glucoseContext == .afterMeal)
    }

    @Test("CreateDTO without glucoseContext stays nil on the wire")
    func createDTONilContextIsNilOnWire() throws {
        let measurement = Measurement(
            id: "local-2",
            kind: .glucose,
            recordedAt: .now,
            value: .scalar(98),
            note: nil,
            source: .manual,
            glucoseContext: nil
        )
        let dto = try #require(measurement.toCreateDTOs().first)
        #expect(dto.glucoseContext == nil)
        // Verify the JSON omits the key when nil, so the server applies its
        // own default + we keep the wire surface minimal.
        let json = try JSONEncoder.hlDefault.encode(dto)
        let str = try #require(String(data: json, encoding: .utf8))
        #expect(!str.contains("glucoseContext"), "nil context should not emit a key — server default applies")
    }

    @Test("BP measurements never emit a glucoseContext key in their create DTOs")
    func bpCreateDTOsCarryNoContext() {
        let bp = Measurement(
            id: "local-bp-1",
            kind: .bloodPressure,
            recordedAt: .now,
            value: .bloodPressure(systolic: 120, diastolic: 80),
            source: .manual,
            glucoseContext: nil
        )
        let dtos = bp.toCreateDTOs()
        #expect(dtos.count == 2)
        for dto in dtos {
            #expect(dto.glucoseContext == nil)
        }
    }

    // MARK: - 5. Full Wire → Domain → CreateDTO round-trip

    @Test("Wire → Domain → CreateDTO preserves glucoseContext end-to-end")
    func endToEndRoundTrip() throws {
        for context in GlucoseContext.allCases {
            let wire = MeasurementWireDTO(
                id: "srv-glu-rt-\(context.rawValue)",
                type: .bloodGlucose,
                value: 100,
                measuredAt: .now,
                glucoseContext: context
            )
            let domain = try #require(wire.toDomain())
            #expect(domain.glucoseContext == context)
            let backDTO = try #require(domain.toCreateDTOs().first)
            #expect(backDTO.glucoseContext == context)
        }
    }
}

// swiftlint:enable force_unwrapping force_try
