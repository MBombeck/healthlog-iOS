import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.8.4 W-WALK — un-gates the two operator-requested gait metrics
/// (`walkingSpeed`, `walkingStepLength`) that the app has collected + uploaded
/// over the HK `hkIdentifier` batch path since v0.5.2 but the server used to
/// reject as `unmappable_identifier`. The server (v1.6.0) now maps
/// `HKQuantityTypeIdentifierWalkingSpeed` → Prisma `WALKING_SPEED` (m/s) and
/// `HKQuantityTypeIdentifierWalkingStepLength` → `WALKING_STEP_LENGTH` (m), so
/// the `HealthKitServerSupportConfig` gate is empty and the
/// `/api/measurements` list decodes the rows to Domain-Measurements.
///
/// Both kinds + their `MetricKindDescriptor` entries already shipped in v0.5.2
/// F2 (they rendered from the HK-local cache); this suite pins the W-WALK
/// additions — the empty server gate, the new `ServerMeasurementType` wire
/// cases, the `toDomain` mapping, and the unchanged display/series contract.
@Suite("MetricKind — v0.8.4 W-WALK gait un-gate")
struct MeasurementTypeWWalkTests {
    @Test("walkingSpeed domain raw key")
    func walkingSpeedRawKey() {
        #expect(MetricKind.walkingSpeed.rawValue == "walkingSpeed")
    }

    @Test("walkingStepLength domain raw key")
    func walkingStepLengthRawKey() {
        #expect(MetricKind.walkingStepLength.rawValue == "walkingStepLength")
    }

    @Test("walkingSpeed formats metres per second")
    func walkingSpeedUnit() {
        #expect(MetricKind.walkingSpeed.unit == "m/s")
    }

    @Test("walkingStepLength formats metres")
    func walkingStepLengthUnit() {
        #expect(MetricKind.walkingStepLength.unit == "m")
    }

    @Test("descriptor resolves without the unknown placeholder", arguments: [
        MetricKind.walkingSpeed,
        MetricKind.walkingStepLength
    ])
    func descriptorResolves(kind: MetricKind) {
        let descriptor = MetricKindDescriptor.catalog[kind]
        #expect(descriptor != nil, "MetricKindDescriptor.catalog missing entry for \(kind)")
        #expect(descriptor?.kind == kind)
        #expect(kind.descriptor.sfSymbol != "questionmark.circle", "Descriptor for \(kind) fell through to the fallback")
        #expect(kind.descriptor.supportsDrillDown, "\(kind) should support drill-down (chart detail)")
    }

    @Test("gait aggregates render at two-decimal precision (sub-metre granularity)", arguments: [
        MetricKind.walkingSpeed,
        MetricKind.walkingStepLength
    ])
    func twoDecimalFormatStyle(kind: MetricKind) {
        #expect(kind.descriptor.formatStyle == .decimal2)
    }

    @Test("walkingSpeed prefers higher polarity (faster gait is healthier)")
    func walkingSpeedPolarity() {
        #expect(MetricKind.walkingSpeed.descriptor.trendPolarity == .higherIsBetter)
    }

    @Test("display names are non-empty for both gait kinds", arguments: [
        MetricKind.walkingSpeed,
        MetricKind.walkingStepLength
    ])
    func displayNameNonEmpty(kind: MetricKind) {
        #expect(!kind.displayName.isEmpty)
    }

    @Test("gait aggregates are NOT cumulative (per-sample mean, not same-day sum)", arguments: [
        MetricKind.walkingSpeed,
        MetricKind.walkingStepLength
    ])
    func notCumulative(kind: MetricKind) {
        // Unlike steps / activity aggregates, gait speed + step length are
        // per-sample point readings the server aggregates as `mean`, so the
        // tile must NOT sum same-day rows.
        #expect(!kind.isCumulative, "\(kind) is a per-sample mean — must not be cumulative")
    }
}

/// Series-endpoint gate: the server (v1.6.0) persists walkingSpeed +
/// walkingStepLength as raw rows, but its `/api/measurements/series` zod
/// `kindEnum` does NOT list them yet (same as every other gait metric). Both
/// `DashboardStore` + `ChartDetailStore` must short-circuit so the chart
/// detail renders from the list page + HK cache instead of throwing on a 422.
@Suite("Series-endpoint gating — W-WALK")
struct SeriesGateWWalkTests {
    @Test("gait aggregates do NOT support series (server route still excludes them)", arguments: [
        MetricKind.walkingSpeed,
        MetricKind.walkingStepLength
    ])
    func gaitKindsAreNotSeries(kind: MetricKind) {
        #expect(
            !ChartDetailStore.kindSupportsSeries(kind),
            "\(kind) has no server series enum entry — gate must short-circuit"
        )
    }
}

/// Wire round-trip for the two W-WALK gait aggregates: each
/// `ServerMeasurementType` member encodes to the canonical Prisma form,
/// decodes back, and `toDomain()` maps the wire row to the right `MetricKind`
/// so the `/api/measurements` list page surfaces them instead of dropping them
/// via the tolerant decoder.
@Suite("ServerMeasurementType — W-WALK wire round-trip")
struct ServerMeasurementTypeWWalkTests {
    @Test("each gait wire type encodes to its Prisma SCREAMING_SNAKE form", arguments: [
        (ServerMeasurementType.walkingSpeed, "WALKING_SPEED"),
        (ServerMeasurementType.walkingStepLength, "WALKING_STEP_LENGTH")
    ])
    func encoding(pair: (ServerMeasurementType, String)) throws {
        let (type, expected) = pair
        let data = try JSONEncoder().encode(type)
        #expect(String(data: data, encoding: .utf8) == "\"\(expected)\"")
    }

    @Test("each gait wire form round-trips", arguments: [
        ("WALKING_SPEED", ServerMeasurementType.walkingSpeed),
        ("WALKING_STEP_LENGTH", ServerMeasurementType.walkingStepLength)
    ])
    func roundTrip(pair: (String, ServerMeasurementType)) throws {
        let (raw, expected) = pair
        let decoded = try JSONDecoder().decode(ServerMeasurementType.self, from: Data("\"\(raw)\"".utf8))
        #expect(decoded == expected)
    }

    @Test("toDomain maps each gait wire row to its MetricKind", arguments: [
        (ServerMeasurementType.walkingSpeed, MetricKind.walkingSpeed),
        (ServerMeasurementType.walkingStepLength, MetricKind.walkingStepLength)
    ])
    func toDomainMapping(pair: (ServerMeasurementType, MetricKind)) {
        let (wireType, expectedKind) = pair
        let wire = MeasurementWireDTO(
            id: "wwalk-1",
            type: wireType,
            value: 1.23,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(wire.toDomain()?.kind == expectedKind)
    }
}
