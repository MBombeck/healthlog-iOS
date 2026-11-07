import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// #162 (server v1.47.0, public #1333): Garmin joins the measurement
/// `source` enum, and four `MeasurementType`s arrive with it: `BODY_BATTERY`
/// and `STRESS_LEVEL` (source `GARMIN`), `TRAINING_READINESS` and
/// `ACUTE_TRAINING_LOAD` (source `EXTERNAL`, written by a `measurements:write`
/// bridge). Spellings, units and bands from `docs/api/openapi.yaml`,
/// `src/lib/measurements/unit-map.ts` and `value-ranges.ts` on the server branch
/// `feat/v147-garmin`.
///
/// The first suite is written against raw values on purpose, so it compiles
/// before the typed cases exist and proves the gap: on the base, every Garmin
/// row decoded onto the `unknown` arms.
@Suite("Garmin contract (server v1.47, #162)")
struct GarminContractTests {
    /// One `/api/measurements` page: the four new types, Garmin on an existing
    /// type, a source and a type newer than this build, and a plain manual row.
    static let mixedPage = """
    {
      "measurements": [
        { "id": "bb", "type": "BODY_BATTERY", "value": 88, "unit": "score", "measuredAt": "2026-11-01T06:00:00Z", "source": "GARMIN" },
        { "id": "sl", "type": "STRESS_LEVEL", "value": 31, "unit": "score", "measuredAt": "2026-11-01T06:00:00Z", "source": "GARMIN" },
        { "id": "tr", "type": "TRAINING_READINESS", "value": 72, "unit": "score", "measuredAt": "2026-11-01T06:00:00Z", "source": "EXTERNAL" },
        { "id": "atl", "type": "ACUTE_TRAINING_LOAD", "value": 412, "unit": "load", "measuredAt": "2026-11-01T06:00:00Z", "source": "EXTERNAL" },
        { "id": "st", "type": "ACTIVITY_STEPS", "value": 9120, "measuredAt": "2026-11-01T06:00:00Z", "source": "GARMIN" },
        { "id": "fu", "type": "SOME_FUTURE_TYPE", "value": 3, "measuredAt": "2026-11-01T06:00:00Z", "source": "SOME_FUTURE_SOURCE" },
        { "id": "m1", "type": "WEIGHT", "value": 80.1, "measuredAt": "2026-11-01T07:00:00Z", "source": "MANUAL" }
      ],
      "meta": { "total": 7, "limit": 400, "offset": 0 }
    }
    """

    static func decodePage() throws -> MeasurementListWireResponse {
        try JSONDecoder.hlDefault.decode(MeasurementListWireResponse.self, from: Data(mixedPage.utf8))
    }

    @Test("an unknown source and an unknown type cost no row of the page")
    func unknownValuesKeepEveryRow() throws {
        let page = try Self.decodePage()
        #expect(page.measurements.map(\.id) == ["bb", "sl", "tr", "atl", "st", "fu", "m1"])
        let future = try #require(page.measurements.first { $0.id == "fu" })
        #expect(future.type.rawValue == "__UNKNOWN__")
        #expect(future.source?.rawValue == "__UNKNOWN__")
        let domain = try #require(future.toDomain())
        #expect(domain.kind.isUnknown)
        #expect(domain.source.rawValue == "unknown")
        #expect(page.measurements.first { $0.id == "m1" }?.toDomain()?.kind == .weight)
    }

    @Test("GARMIN decodes as its own source, not as unknown")
    func garminSourceIsNamed() throws {
        let page = try Self.decodePage()
        for id in ["bb", "sl", "st"] {
            let row = try #require(page.measurements.first { $0.id == id })
            #expect(row.source?.rawValue == "GARMIN", "row \(id)")
            #expect(row.toDomain()?.source.rawValue == "garmin", "row \(id)")
        }
    }

    @Test("the four new types decode onto their own kinds, not onto unknown")
    func newTypesAreNamed() throws {
        let page = try Self.decodePage()
        let expected = [
            "bb": ("BODY_BATTERY", "bodyBattery"),
            "sl": ("STRESS_LEVEL", "stressLevel"),
            "tr": ("TRAINING_READINESS", "trainingReadiness"),
            "atl": ("ACUTE_TRAINING_LOAD", "acuteTrainingLoad")
        ]
        for (id, names) in expected {
            let row = try #require(page.measurements.first { $0.id == id })
            #expect(row.type.rawValue == names.0, "row \(id)")
            let domain = try #require(row.toDomain(), "row \(id)")
            #expect(domain.kind.rawValue == names.1, "row \(id)")
            #expect(!domain.kind.isUnknown, "row \(id)")
        }
        // The bridged scores keep EXTERNAL; only Garmin's own rows say Garmin.
        #expect(page.measurements.first { $0.id == "tr" }?.toDomain()?.source == .external)
    }

    @MainActor
    @Test("Garmin reads as Garmin wherever a source token is labelled")
    func garminLabelByToken() {
        #expect(SourcePriorityRow.displayLabel(forSource: "GARMIN") == "Garmin")
        #expect(SourcePriorityRow.iconName(forSource: "GARMIN") != SourcePriorityRow.iconName(forSource: "SOME_FUTURE_SOURCE"))
        // Garmin activities arrive as workouts, whose `source` is a raw string.
        #expect(WorkoutDetailView.sourceLabel("GARMIN") == "Garmin")
    }
}

/// #162 — the typed half: what the app does with Garmin once it can name it.
@Suite("Garmin source and types, typed (server v1.47, #162)")
struct GarminTypedTests {
    static let garminKinds: [MetricKind] = [.bodyBattery, .stressLevel, .trainingReadiness, .acuteTrainingLoad]

    @Test("GARMIN round-trips verbatim and maps to its own domain case")
    func sourceWireRoundTrip() throws {
        let decoded = try JSONDecoder().decode(ServerMeasurementSource.self, from: Data(#""GARMIN""#.utf8))
        #expect(decoded == .garmin)
        #expect(decoded.toDomain() == .garmin)
        #expect(MeasurementSource.garmin.wire == .garmin)
        let encoded = try String(data: JSONEncoder().encode(ServerMeasurementSource.garmin), encoding: .utf8)
        #expect(encoded == #""GARMIN""#)
    }

    @Test("the four wire types map one to one, never onto a neighbour")
    func typeMapping() {
        #expect(ServerMeasurementType.bodyBattery.metricKind == .bodyBattery)
        #expect(ServerMeasurementType.stressLevel.metricKind == .stressLevel)
        #expect(ServerMeasurementType.trainingReadiness.metricKind == .trainingReadiness)
        #expect(ServerMeasurementType.acuteTrainingLoad.metricKind == .acuteTrainingLoad)
        // STRESS_LEVEL is not the computed STRESS_SCORE, Body Battery not recovery.
        #expect(MetricKind.stressLevel != .stressScore)
        #expect(MetricKind.bodyBattery.availabilitySummaryKey == "BODY_BATTERY")
        #expect(MetricKind.stressLevel.availabilitySummaryKey == "STRESS_LEVEL")
        #expect(MetricKind.trainingReadiness.availabilitySummaryKey == "TRAINING_READINESS")
        #expect(MetricKind.acuteTrainingLoad.availabilitySummaryKey == "ACUTE_TRAINING_LOAD")
    }

    @Test("Garmin values are read-only, never mirrored, and have no manual entry")
    func readOnlyNoHealthKit() {
        let row = HealthLog.Measurement(id: "g1", kind: .bodyBattery, recordedAt: Date(), value: .scalar(88), source: .garmin)
        #expect(row.isServerDerivedReadOnly)
        #expect(!MeasurementSource.garmin.isServerMirrorEligible)
        #expect(!MeasurementSource.serverMirrorEligible.contains(.garmin))
        for kind in Self.garminKinds {
            #expect(MeasurementRanges.range(for: kind) == nil, "\(kind)")
            #expect(!kind.isUnknown, "\(kind)")
        }
    }

    @Test("the descriptors carry unit, polarity and format like the WHOOP scores")
    func descriptors() {
        for kind in Self.garminKinds {
            let descriptor = MetricKindDescriptor.descriptor(for: kind)
            #expect(descriptor.kind == kind)
            #expect(descriptor.sfSymbol != "questionmark.circle", "\(kind) has a catalogue entry")
            #expect(kind.unit.isEmpty, "\(kind) is a unitless score or load")
            #expect(descriptor.supportsDrillDown)
        }
        #expect(MetricKindDescriptor.descriptor(for: .bodyBattery).trendPolarity == .higherIsBetter)
        #expect(MetricKindDescriptor.descriptor(for: .trainingReadiness).trendPolarity == .higherIsBetter)
        #expect(MetricKindDescriptor.descriptor(for: .stressLevel).trendPolarity == .lowerIsBetter)
        #expect(MetricKindDescriptor.descriptor(for: .acuteTrainingLoad).trendPolarity == .neutral)
        #expect(MetricKindDescriptor.descriptor(for: .bodyBattery).formatStyle == .integer)
        #expect(CategoryAssignmentMap.bundledFallback.categoryId(forRawType: "BODY_BATTERY") == "scores")
        #expect(CategoryAssignmentMap.bundledFallback.categoryId(forRawType: "ACUTE_TRAINING_LOAD") == "scores")
    }

    @MainActor
    @Test("Garmin is labelled and has its own glyph on every source surface")
    func labelAndIcon() {
        #expect(SourceFilterChips.label(for: .garmin) == String(localized: "Garmin"))
        #expect(SourcePriorityRow.iconName(forSource: "GARMIN") == "watch.analog")
        let rows = [
            HealthLog.Measurement(id: "a", kind: .weight, recordedAt: Date(), value: .scalar(80), source: .manual),
            HealthLog.Measurement(id: "b", kind: .bodyBattery, recordedAt: Date(), value: .scalar(81), source: .garmin)
        ]
        let chips = MeasurementListFilter.availableSources(in: rows)
        #expect(chips.contains(.garmin))
        #expect(!chips.contains(.unknown))
    }

    @Test("an older server never summarises the Garmin types, so the recovery list shows none")
    func recoveryFamilyWithoutGarmin() {
        let stat = RecoverySummariesEnvelope.Stat(count: 10, latest: 60, mean: 58, avg30: 55)
        let family = RecoveryInsightsRepository.buildFamily(from: ["RECOVERY_SCORE": stat, "DAY_STRAIN": stat])
        #expect(family.items.map(\.id) == ["RECOVERY_SCORE", "DAY_STRAIN"])
    }

    @Test("a v1.47 server that summarises them puts them in the recovery list, in the web's order")
    func recoveryFamilyWithGarmin() {
        let stat = RecoverySummariesEnvelope.Stat(count: 10, latest: 60, mean: 58, avg30: 55)
        let summaries = [
            "RECOVERY_SCORE": stat, "BODY_BATTERY": stat, "STRESS_LEVEL": stat,
            "TRAINING_READINESS": stat, "ACUTE_TRAINING_LOAD": stat, "CARDIO_LOAD": stat
        ]
        let family = RecoveryInsightsRepository.buildFamily(from: summaries)
        #expect(family.items.map(\.id) == [
            "RECOVERY_SCORE", "BODY_BATTERY", "TRAINING_READINESS", "STRESS_LEVEL", "CARDIO_LOAD", "ACUTE_TRAINING_LOAD"
        ])
        let layout = RecoveryPageLayout(family: family)
        #expect(layout.rows.map(\.kind).contains(.bodyBattery))
    }
}
