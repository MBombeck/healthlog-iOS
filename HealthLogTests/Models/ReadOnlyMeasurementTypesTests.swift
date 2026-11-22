import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// The five server types the app shows without collecting them: blood ketones
/// (server v1.47.2), resting energy (v1.47.1) and the three room-climate
/// readings (v1.44). Spellings from `prisma/schema.prisma`, units from
/// `src/lib/measurements/unit-map.ts`, names from `messages/{de,en,nl}.json`
/// (`measurements.type*`).
@Suite("Read-only server types: ketones, resting energy, room climate")
struct ReadOnlyMeasurementTypesTests {
    static let page = """
    {
      "measurements": [
        { "id": "k1", "type": "BLOOD_KETONES", "value": 1.4, "unit": "mmol/L", "measuredAt": "2026-11-10T07:00:00Z", "source": "MANUAL" },
        { "id": "b1", "type": "BASAL_ENERGY_BURNED", "value": 1710, "unit": "kcal", "measuredAt": "2026-11-10T00:00:00Z", "source": "APPLE_HEALTH" },
        { "id": "c1", "type": "INDOOR_CO2", "value": 912, "unit": "ppm", "measuredAt": "2026-11-10T08:00:00Z", "source": "EXTERNAL" },
        { "id": "t1", "type": "INDOOR_TEMPERATURE", "value": 21.4, "unit": "celsius", "measuredAt": "2026-11-10T08:00:00Z", "source": "EXTERNAL" },
        { "id": "h1", "type": "INDOOR_HUMIDITY", "value": 47, "unit": "%", "measuredAt": "2026-11-10T08:00:00Z", "source": "EXTERNAL" }
      ],
      "meta": { "total": 5, "limit": 400, "offset": 0 }
    }
    """

    static let expectedKinds: [String: MetricKind] = [
        "k1": .bloodKetones,
        "b1": .basalEnergy,
        "c1": .indoorCO2,
        "t1": .indoorTemperature,
        "h1": .indoorHumidity
    ]

    static let kinds: [MetricKind] = [.bloodKetones, .basalEnergy, .indoorCO2, .indoorTemperature, .indoorHumidity]

    @Test("A server page with all five types decodes onto five named kinds")
    func decodesOntoNamedKinds() throws {
        let page = try JSONDecoder.hlDefault.decode(MeasurementListWireResponse.self, from: Data(Self.page.utf8))
        #expect(page.measurements.count == 5)
        for row in page.measurements {
            let expected = try #require(Self.expectedKinds[row.id])
            #expect(row.type != .unknown, "row \(row.id)")
            let domain = try #require(row.toDomain(), "row \(row.id)")
            #expect(domain.kind == expected, "row \(row.id)")
            #expect(!domain.kind.isUnknown, "row \(row.id)")
        }
        let ketones = try #require(page.measurements.first { $0.id == "k1" }?.toDomain())
        #expect(ketones.value.primaryComponent == 1.4)
        let temperature = try #require(page.measurements.first { $0.id == "t1" }?.toDomain())
        #expect(temperature.value.primaryComponent == 21.4)
    }

    @Test("Each wire token maps to its kind and back to the kind-scoped type key")
    func wireMapping() {
        #expect(ServerMeasurementType.bloodKetones.metricKind == .bloodKetones)
        #expect(ServerMeasurementType.basalEnergyBurned.metricKind == .basalEnergy)
        #expect(ServerMeasurementType.indoorCO2.metricKind == .indoorCO2)
        #expect(ServerMeasurementType.indoorTemperature.metricKind == .indoorTemperature)
        #expect(ServerMeasurementType.indoorHumidity.metricKind == .indoorHumidity)
        #expect(MetricKind.bloodKetones.availabilitySummaryKey == "BLOOD_KETONES")
        #expect(MetricKind.basalEnergy.availabilitySummaryKey == "BASAL_ENERGY_BURNED")
        #expect(MetricKind.indoorCO2.availabilitySummaryKey == "INDOOR_CO2")
        #expect(MetricKind.indoorTemperature.availabilitySummaryKey == "INDOOR_TEMPERATURE")
        #expect(MetricKind.indoorHumidity.availabilitySummaryKey == "INDOOR_HUMIDITY")
    }

    @Test("Units follow the server unit map")
    func units() {
        #expect(MetricKind.bloodKetones.unit == "mmol/L")
        #expect(MetricKind.basalEnergy.unit == "kcal")
        #expect(MetricKind.indoorCO2.unit == "ppm")
        #expect(MetricKind.indoorTemperature.unit == "°C")
        #expect(MetricKind.indoorHumidity.unit == "%")
        #expect(MetricKind.indoorTemperature.unitFamily == .temperature)
        #expect(MetricKind.basalEnergy.isCumulative)
    }

    @Test("Format: ketones and room temperature one decimal, resting energy and CO₂ whole")
    func formats() {
        #expect(MetricKind.bloodKetones.descriptor.formatStyle == .decimal1)
        #expect(MetricKind.indoorTemperature.descriptor.formatStyle == .decimal1)
        #expect(MetricKind.basalEnergy.descriptor.formatStyle == .groupedInteger)
        #expect(MetricKind.indoorCO2.descriptor.formatStyle == .groupedInteger)
        #expect(MetricKind.indoorHumidity.descriptor.formatStyle == .integer)
        let ketones = MetricValueFormatter.styled(1.44, style: MetricKind.bloodKetones.descriptor.formatStyle)
        #expect(ketones == "1,4" || ketones == "1.4")
        #expect(MetricValueFormatter.styled(47.4, style: MetricKind.indoorHumidity.descriptor.formatStyle) == "47")
    }

    @Test(
        "Names and units read in each language, with the server's wording",
        arguments: [
            ("de", ["Blutketone", "Ruheenergie", "CO₂ (innen)", "Raumtemperatur", "Luftfeuchtigkeit (innen)"]),
            ("en", ["Blood ketones", "Resting energy", "Indoor CO₂", "Indoor temperature", "Indoor humidity"]),
            ("nl", ["Bloedketonen", "Rustenergie", "CO₂ binnen", "Binnentemperatuur", "Luchtvochtigheid binnen"])
        ]
    )
    func localizedNamesAndUnits(language: String, names: [String]) {
        let locale = Locale(identifier: language)
        let units = ["mmol/L", "kcal", "ppm", "°C", "%"]
        for (index, kind) in Self.kinds.enumerated() {
            var title = kind.descriptor.title
            title.locale = locale
            #expect(String(localized: title) == names[index], "\(language) \(kind)")
            var unit = kind.descriptor.unitLabel
            unit.locale = locale
            #expect(String(localized: unit) == units[index], "\(language) \(kind)")
        }
    }

    @Test("Read-only: no manual range, kept out of the coach digest")
    func readOnlySurfaces() {
        for kind in Self.kinds {
            #expect(MeasurementRanges.range(for: kind) == nil, "\(kind)")
            #expect(kind.descriptor.sfSymbol != "questionmark.circle", "\(kind)")
            #expect(kind.descriptor.trendPolarity == .neutral, "\(kind)")
            #expect(kind.isModelFenced, "\(kind)")
            #expect(MetricKind.selectableCases.contains(kind), "\(kind)")
        }
        #expect(CategoryAssignmentMap.bundledFallback.categoryId(forRawType: "BLOOD_KETONES") == "metabolic")
        #expect(CategoryAssignmentMap.bundledFallback.categoryId(forRawType: "BASAL_ENERGY_BURNED") == "activity")
        #expect(CategoryAssignmentMap.bundledFallback.categoryId(forRawType: "INDOOR_CO2") == "environment")
    }
}
