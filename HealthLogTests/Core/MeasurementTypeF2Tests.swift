import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.5.2 F2 HK-completeness — adds seven `MetricKind` cases:
/// three server-backed (`restingHeartRate`, `hrv`, `vo2Max`) and four
/// iOS-local (`walkingSpeed`, `walkingAsymmetry`, `walkingStepLength`,
/// `bmi`) until the server's `MeasurementType` enum catches up.
///
/// This suite pins:
///   * Raw-value contract for every new case — both the domain wire-key
///     and the server's SCREAMING_SNAKE_CASE form line up with the
///     server's `prisma/enums.ts` table where applicable.
///   * Display-name + unit return non-empty per case (defensive against
///     a future maintainer dropping a switch arm).
///   * The MetricKindDescriptor registry covers every new case.
///   * `MeasurementsRepository.seriesKindKey` returns the server-expected
///     camelCase key for the three server-backed kinds.
///   * `ChartDetailStore.kindSupportsSeries` returns the right gate
///     value: true for the server-backed three, false for the iOS-local
///     four (they'd 422 the server today).
///   * `DashboardWidgetId` round-trips every new MetricKind through its
///     widget id.
@Suite("MetricKind — v0.5.2 F2 HK-completeness additions")
struct MeasurementTypeF2Tests {
    @Test("restingHeartRate domain raw key")
    func restingHeartRateRawKey() {
        #expect(MetricKind.restingHeartRate.rawValue == "restingHeartRate")
    }

    @Test("hrv domain raw key matches server seriesKindKey form")
    func hrvRawKey() {
        #expect(MetricKind.hrv.rawValue == "heartRateVariability")
    }

    @Test("vo2Max domain raw key")
    func vo2MaxRawKey() {
        #expect(MetricKind.vo2Max.rawValue == "vo2Max")
    }

    @Test("walkingSpeed domain raw key")
    func walkingSpeedRawKey() {
        #expect(MetricKind.walkingSpeed.rawValue == "walkingSpeed")
    }

    @Test("walkingAsymmetry domain raw key spells out the percentage")
    func walkingAsymmetryRawKey() {
        // Matches the HKQuantityTypeIdentifier suffix Apple emits + the
        // form the server would expect once the enum lands.
        #expect(MetricKind.walkingAsymmetry.rawValue == "walkingAsymmetryPercentage")
    }

    @Test("walkingStepLength domain raw key")
    func walkingStepLengthRawKey() {
        #expect(MetricKind.walkingStepLength.rawValue == "walkingStepLength")
    }

    @Test("bmi domain raw key spells out body mass index")
    func bmiRawKey() {
        #expect(MetricKind.bmi.rawValue == "bodyMassIndex")
    }

    @Test("CaseIterable allCases includes every F2 addition")
    func allCasesIncludesF2Additions() {
        let raws = Set(MetricKind.allCases.map(\.rawValue))
        #expect(raws.contains("restingHeartRate"))
        #expect(raws.contains("heartRateVariability"))
        #expect(raws.contains("vo2Max"))
        #expect(raws.contains("walkingSpeed"))
        #expect(raws.contains("walkingAsymmetryPercentage"))
        #expect(raws.contains("walkingStepLength"))
        #expect(raws.contains("bodyMassIndex"))
    }

    @Test("display names + units are non-empty for every F2 addition", arguments: [
        MetricKind.restingHeartRate,
        MetricKind.hrv,
        MetricKind.vo2Max,
        MetricKind.walkingSpeed,
        MetricKind.walkingAsymmetry,
        MetricKind.walkingStepLength,
        MetricKind.bmi
    ])
    func displayNameAndUnit(kind: MetricKind) {
        #expect(!kind.displayName.isEmpty)
        #expect(!kind.unit.isEmpty)
    }

    @Test("descriptor registry has an entry for every F2 addition", arguments: [
        MetricKind.restingHeartRate,
        MetricKind.hrv,
        MetricKind.vo2Max,
        MetricKind.walkingSpeed,
        MetricKind.walkingAsymmetry,
        MetricKind.walkingStepLength,
        MetricKind.bmi
    ])
    func descriptorCoversEveryF2Kind(kind: MetricKind) {
        let descriptor = MetricKindDescriptor.catalog[kind]
        #expect(descriptor != nil, "MetricKindDescriptor.catalog missing entry for \(kind)")
        #expect(descriptor?.kind == kind)
        #expect(
            descriptor?.sfSymbol.isEmpty == false,
            "Descriptor for \(kind) ships an empty SF Symbol"
        )
    }

    @Test("descriptor for vo2Max prefers higher polarity (cardio-fitness improves with training)")
    func vo2MaxPolarity() {
        #expect(MetricKind.vo2Max.descriptor.trendPolarity == .higherIsBetter)
    }

    @Test("descriptor for restingHeartRate prefers lower polarity")
    func restingHRPolarity() {
        #expect(MetricKind.restingHeartRate.descriptor.trendPolarity == .lowerIsBetter)
    }

    @Test("descriptor for hrv prefers higher polarity (vagal-tone interpretation)")
    func hrvPolarity() {
        #expect(MetricKind.hrv.descriptor.trendPolarity == .higherIsBetter)
    }

    @Test("descriptor for walkingAsymmetry prefers lower polarity")
    func walkingAsymmetryPolarity() {
        #expect(MetricKind.walkingAsymmetry.descriptor.trendPolarity == .lowerIsBetter)
    }
}

/// Widget-id contract: every F2-added MetricKind must round-trip through
/// `DashboardWidgetId.id(forMetricKind:) → metricKind(forId:)`. Without this
/// the tile-strip drops the kind silently when synthesising missing tiles
/// from the layout.
@Suite("DashboardWidgetId — F2 round-trip")
struct DashboardWidgetIdF2Tests {
    @Test("every F2 MetricKind round-trips through its widget id", arguments: [
        MetricKind.restingHeartRate,
        MetricKind.hrv,
        MetricKind.vo2Max,
        MetricKind.walkingSpeed,
        MetricKind.walkingAsymmetry,
        MetricKind.walkingStepLength,
        MetricKind.bmi
    ])
    func roundTrip(kind: MetricKind) {
        let id = DashboardWidgetId.id(forMetricKind: kind)
        #expect(id != nil, "Missing widget id for \(kind)")
        if let id {
            #expect(
                DashboardWidgetId.metricKind(forId: id) == kind,
                "Round-trip failure for \(kind) (widget id \(id))"
            )
        }
    }

    @Test("default layout ships every F2 widget id tile-visible by default")
    func defaultLayoutShowsF2Tiles() {
        let layout = DashboardWidgetLayout.default
        let ids = [
            DashboardWidgetId.restingHeartRate,
            DashboardWidgetId.hrv,
            DashboardWidgetId.bodyTemperature,
            DashboardWidgetId.walkingSpeed,
            DashboardWidgetId.walkingAsymmetry,
            DashboardWidgetId.walkingStepLength,
            DashboardWidgetId.bmi
        ]
        for id in ids {
            let row = layout.widgets.first { $0.id == id }
            #expect(row?.effectiveTileVisible == true, "Widget \(id) must be tile-visible by default")
        }
    }
}

/// Series-endpoint gate: the three F2 server-backed kinds (RHR, HRV, VO₂ max)
/// must route through `/api/measurements/series` while the four iOS-local
/// kinds short-circuit. This locks the canonical list referenced by
/// `DashboardStore.kindSupportsSeries`, `ChartDetailStore.kindSupportsSeries`,
/// and `TrendsOverlayStore.availableMetrics`.
@Suite("Series-endpoint gating — F2")
struct SeriesGateF2Tests {
    @Test("server-backed F2 kinds support series", arguments: [
        MetricKind.restingHeartRate,
        MetricKind.hrv,
        MetricKind.vo2Max
    ])
    func serverBackedF2KindsAreSeries(kind: MetricKind) {
        #expect(
            ChartDetailStore.kindSupportsSeries(kind),
            "\(kind) is server-backed since v1.4.30; series endpoint must accept it"
        )
    }

    @Test("iOS-local F2 kinds do NOT support series (yet)", arguments: [
        MetricKind.walkingSpeed,
        MetricKind.walkingAsymmetry,
        MetricKind.walkingStepLength,
        MetricKind.bmi
    ])
    func iosLocalF2KindsAreNotSeries(kind: MetricKind) {
        #expect(
            !ChartDetailStore.kindSupportsSeries(kind),
            "\(kind) has no server enum yet — series gate must short-circuit"
        )
    }

    /// **v0.5.5.2 reconcile (W-DATA-FLOW-AUDIT BLOCKER #2, commit 877fb893):**
    /// although `kindSupportsSeries` still flags RHR / HRV / VO₂ max as
    /// server-backed, the server's `/api/measurements/series` zod `kindEnum`
    /// rejects all three with HTTP 400/422 (still true as of server v1.5.5 —
    /// the v0.8.0 server-sync did NOT add them to the series enum). Toggling
    /// one in the Trends overlay threw inside `withThrowingTaskGroup` and
    /// aborted every other in-flight fetch → operator-perceived "Trends
    /// doesn't work". They were therefore deliberately trimmed out of
    /// `availableMetrics` (canonical: `TrendsOverlayStoreTests`). This test
    /// pins that exclusion so the F2 surface stays consistent with the
    /// overlay's server-safe chip row.
    @Test("server-rejected F2 kinds stay OUT of TrendsOverlayStore.availableMetrics")
    func availableMetricsExcludesServerRejectedF2Kinds() {
        let metrics = Set(TrendsOverlayStore.availableMetrics)
        // RHR / HRV / VO₂ max: server series enum still rejects them (v1.5.5).
        #expect(!metrics.contains(.restingHeartRate))
        #expect(!metrics.contains(.hrv))
        #expect(!metrics.contains(.vo2Max))
        // iOS-local kinds stay out too — no series, no overlay coverage.
        #expect(!metrics.contains(.walkingSpeed))
        #expect(!metrics.contains(.walkingAsymmetry))
        #expect(!metrics.contains(.walkingStepLength))
        #expect(!metrics.contains(.bmi))
    }
}

/// Wire round-trip for the three server-backed F2 additions: their
/// `ServerMeasurementType` enum members encode to the canonical Prisma
/// `RESTING_HEART_RATE` / `HEART_RATE_VARIABILITY` / `VO2_MAX` form, and
/// decoding the same wire form round-trips back. Without this, a server
/// payload containing one of the three throws `dataCorrupted` in the
/// summary or measurements decoders.
@Suite("ServerMeasurementType — F2 wire round-trip")
struct ServerMeasurementTypeF2Tests {
    @Test("restingHeartRate encodes as RESTING_HEART_RATE")
    func rhrEncoding() throws {
        let data = try JSONEncoder().encode(ServerMeasurementType.restingHeartRate)
        #expect(String(data: data, encoding: .utf8) == "\"RESTING_HEART_RATE\"")
    }

    @Test("heartRateVariability encodes as HEART_RATE_VARIABILITY")
    func hrvEncoding() throws {
        let data = try JSONEncoder().encode(ServerMeasurementType.heartRateVariability)
        #expect(String(data: data, encoding: .utf8) == "\"HEART_RATE_VARIABILITY\"")
    }

    @Test("vo2Max encodes as VO2_MAX")
    func vo2MaxEncoding() throws {
        let data = try JSONEncoder().encode(ServerMeasurementType.vo2Max)
        #expect(String(data: data, encoding: .utf8) == "\"VO2_MAX\"")
    }

    @Test("RESTING_HEART_RATE wire-form round-trips")
    func rhrRoundTrip() throws {
        let data = Data("\"RESTING_HEART_RATE\"".utf8)
        let decoded = try JSONDecoder().decode(ServerMeasurementType.self, from: data)
        #expect(decoded == .restingHeartRate)
    }

    @Test("HEART_RATE_VARIABILITY wire-form round-trips")
    func hrvRoundTrip() throws {
        let data = Data("\"HEART_RATE_VARIABILITY\"".utf8)
        let decoded = try JSONDecoder().decode(ServerMeasurementType.self, from: data)
        #expect(decoded == .heartRateVariability)
    }

    @Test("VO2_MAX wire-form round-trips")
    func vo2MaxRoundTrip() throws {
        let data = Data("\"VO2_MAX\"".utf8)
        let decoded = try JSONDecoder().decode(ServerMeasurementType.self, from: data)
        #expect(decoded == .vo2Max)
    }

    @Test("toDomain maps RESTING_HEART_RATE wire to MetricKind.restingHeartRate")
    func rhrToDomain() {
        let wire = MeasurementWireDTO(
            id: "rhr-1",
            type: .restingHeartRate,
            value: 58,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(wire.toDomain()?.kind == .restingHeartRate)
    }

    @Test("toDomain maps HEART_RATE_VARIABILITY wire to MetricKind.hrv")
    func hrvToDomain() {
        let wire = MeasurementWireDTO(
            id: "hrv-1",
            type: .heartRateVariability,
            value: 42,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(wire.toDomain()?.kind == .hrv)
    }

    @Test("toDomain maps VO2_MAX wire to MetricKind.vo2Max")
    func vo2MaxToDomain() {
        let wire = MeasurementWireDTO(
            id: "vo2-1",
            type: .vo2Max,
            value: 44.7,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(wire.toDomain()?.kind == .vo2Max)
    }

    @Test("toCreateDTOs emits a single wire row for each F2 server-backed kind", arguments: [
        (MetricKind.restingHeartRate, ServerMeasurementType.restingHeartRate),
        (MetricKind.hrv, ServerMeasurementType.heartRateVariability),
        (MetricKind.vo2Max, ServerMeasurementType.vo2Max)
    ])
    func toCreateDTOsForServerBackedF2(pair: (MetricKind, ServerMeasurementType)) {
        let (kind, wireType) = pair
        let measurement = Measurement(
            id: "mtest",
            kind: kind,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .scalar(50),
            source: .appleHealth,
            externalUUID: "ext"
        )
        let dtos = measurement.toCreateDTOs()
        #expect(dtos.count == 1, "Expected 1 wire row for \(kind), got \(dtos.count)")
        #expect(dtos.first?.type == wireType, "Wire row type for \(kind) drifted off \(wireType)")
    }

    @Test("toCreateDTOs emits zero wire rows for iOS-local F2 kinds", arguments: [
        MetricKind.walkingSpeed,
        MetricKind.walkingAsymmetry,
        MetricKind.walkingStepLength,
        MetricKind.bmi
    ])
    func toCreateDTOsForIosLocalF2(kind: MetricKind) {
        let measurement = Measurement(
            id: "mtest",
            kind: kind,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .scalar(1),
            source: .appleHealth,
            externalUUID: "ext"
        )
        #expect(
            measurement.toCreateDTOs().isEmpty,
            "iOS-local kind \(kind) must NOT emit a wire row — no server enum yet"
        )
    }

    /// v1.25 (GH iOS #38) — regression guard: a manually-entered respiratory rate
    /// used to fall through `toCreateDTOs()`'s `default: []` (silent no-op save).
    /// It must now emit exactly one `RESPIRATORY_RATE` wire row carrying the value.
    @Test("toCreateDTOs persists a manual respiratoryRate (was a silent no-op)")
    func respiratoryRateCreatesWireRow() {
        let measurement = Measurement(
            id: "rr-1",
            kind: .respiratoryRate,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .scalar(16),
            source: .manual,
            externalUUID: "ext-rr"
        )
        let dtos = measurement.toCreateDTOs()
        #expect(dtos.count == 1, "respiratoryRate must emit one wire row, got \(dtos.count)")
        #expect(dtos.first?.type == .respiratoryRate)
        #expect(dtos.first?.value == 16)
        #expect(dtos.first?.source == .manual)
        #expect(dtos.first?.externalId == "ext-rr")
    }
}
