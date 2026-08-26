import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.8.3 W-D — surfaces the four "collected-but-undisplayed" activity
/// aggregates the app already syncs to the server but never rendered:
/// `activeEnergy`, `flightsClimbed`, `distanceWalkingRunning`,
/// `timeInDaylight` (R6 metric-coverage audit). All four are server-
/// persisted as raw `MeasurementType` rows, so the `/api/measurements`
/// list page decodes them; the `/api/measurements/series` +
/// `/api/dashboard/summary` routes don't emit them yet, so the series
/// gate stays `false` and they read off the list page + HK cache.
///
/// This suite pins:
///   * Raw-value contract for each new `MetricKind` case.
///   * `CaseIterable.allCases` includes every new case.
///   * `displayName` resolves (non-empty) + `unit` is the expected HK unit.
///   * The `MetricKindDescriptor` registry covers each new case + carries
///     the expected `formatStyle` / `trendPolarity`.
///   * `isCumulative` is `true` (per-day aggregates, same-day-sum tiles).
///   * `kindSupportsSeries` is `false` (server series route 422s them today).
///   * `ServerMeasurementType` wire round-trips to the Prisma SCREAMING_SNAKE
///     form + `toDomain()` maps each wire row to the right `MetricKind`.
@Suite("MetricKind — v0.8.3 W-D activity aggregates")
struct MeasurementTypeWDActivityTests {
    @Test("activeEnergy domain raw key")
    func activeEnergyRawKey() {
        #expect(MetricKind.activeEnergy.rawValue == "activeEnergyBurned")
    }

    @Test("flightsClimbed domain raw key")
    func flightsClimbedRawKey() {
        #expect(MetricKind.flightsClimbed.rawValue == "flightsClimbed")
    }

    @Test("distanceWalkingRunning domain raw key")
    func distanceWalkingRunningRawKey() {
        #expect(MetricKind.distanceWalkingRunning.rawValue == "distanceWalkingRunning")
    }

    @Test("timeInDaylight domain raw key")
    func timeInDaylightRawKey() {
        #expect(MetricKind.timeInDaylight.rawValue == "timeInDaylight")
    }

    @Test("CaseIterable allCases includes every W-D addition")
    func allCasesIncludesWDAdditions() {
        let raws = Set(MetricKind.allCases.map(\.rawValue))
        #expect(raws.contains("activeEnergyBurned"))
        #expect(raws.contains("flightsClimbed"))
        #expect(raws.contains("distanceWalkingRunning"))
        #expect(raws.contains("timeInDaylight"))
    }

    @Test("display names are non-empty for every W-D addition", arguments: [
        MetricKind.activeEnergy,
        MetricKind.flightsClimbed,
        MetricKind.distanceWalkingRunning,
        MetricKind.timeInDaylight
    ])
    func displayNameNonEmpty(kind: MetricKind) {
        #expect(!kind.displayName.isEmpty)
    }

    @Test("each W-D addition formats its expected HK unit", arguments: [
        (MetricKind.activeEnergy, "kcal"),
        (MetricKind.distanceWalkingRunning, "m"),
        (MetricKind.timeInDaylight, "min")
    ])
    func unitMatchesHKUnit(pair: (MetricKind, String)) {
        let (kind, expected) = pair
        #expect(kind.unit == expected, "Unit for \(kind) drifted off \(expected)")
    }

    @Test("flightsClimbed is a unit-less count")
    func flightsClimbedUnitIsEmpty() {
        // Apple Health surfaces flights as a bare integer; the descriptor's
        // unitLabel carries the localized "Flights" word, but the wire unit
        // (`MetricKind.unit`) is empty like steps.
        #expect(MetricKind.flightsClimbed.unit.isEmpty)
    }

    @Test("descriptor registry has an entry for every W-D addition", arguments: [
        MetricKind.activeEnergy,
        MetricKind.flightsClimbed,
        MetricKind.distanceWalkingRunning,
        MetricKind.timeInDaylight
    ])
    func descriptorCoversEveryWDKind(kind: MetricKind) {
        let descriptor = MetricKindDescriptor.catalog[kind]
        #expect(descriptor != nil, "MetricKindDescriptor.catalog missing entry for \(kind)")
        #expect(descriptor?.kind == kind)
        #expect(
            descriptor?.sfSymbol.isEmpty == false,
            "Descriptor for \(kind) ships an empty SF Symbol"
        )
    }

    @Test("descriptor resolves without falling back to the unknown placeholder", arguments: [
        MetricKind.activeEnergy,
        MetricKind.flightsClimbed,
        MetricKind.distanceWalkingRunning,
        MetricKind.timeInDaylight
    ])
    func descriptorNeverFallsBack(kind: MetricKind) {
        #expect(
            kind.descriptor.sfSymbol != "questionmark.circle",
            "Descriptor for \(kind) fell through to the fallback"
        )
        #expect(kind.descriptor.supportsDrillDown, "\(kind) should support drill-down (chart detail)")
    }

    @Test("activeEnergy + distance group their integers (large daily totals)")
    func cumulativeFormatStyles() {
        #expect(MetricKind.activeEnergy.descriptor.formatStyle == .groupedInteger)
        #expect(MetricKind.distanceWalkingRunning.descriptor.formatStyle == .groupedInteger)
    }

    @Test("flights + daylight render as plain integers")
    func plainIntegerFormatStyles() {
        #expect(MetricKind.flightsClimbed.descriptor.formatStyle == .integer)
        #expect(MetricKind.timeInDaylight.descriptor.formatStyle == .integer)
    }

    @Test("all W-D aggregates prefer higher polarity (more activity is good)", arguments: [
        MetricKind.activeEnergy,
        MetricKind.flightsClimbed,
        MetricKind.distanceWalkingRunning,
        MetricKind.timeInDaylight
    ])
    func higherIsBetterPolarity(kind: MetricKind) {
        #expect(kind.descriptor.trendPolarity == .higherIsBetter)
    }

    @Test("W-D aggregates are per-day cumulative (same-day-sum tile)", arguments: [
        MetricKind.activeEnergy,
        MetricKind.flightsClimbed,
        MetricKind.distanceWalkingRunning,
        MetricKind.timeInDaylight
    ])
    func cumulativeFlag(kind: MetricKind) {
        #expect(kind.isCumulative, "\(kind) is a per-day HK aggregate — must be cumulative")
    }
}

/// Series-endpoint gate: the four W-D aggregates persist server-side but the
/// `/api/measurements/series` zod `kindEnum` rejects them (still true as of
/// server v1.5.5). Both `DashboardStore` + `ChartDetailStore` must short-
/// circuit so the chart detail renders from the list page + HK cache rather
/// than throwing on a 422.
@Suite("Series-endpoint gating — W-D")
struct SeriesGateWDActivityTests {
    @Test("W-D aggregates do NOT support series (server route 422s them)", arguments: [
        MetricKind.activeEnergy,
        MetricKind.flightsClimbed,
        MetricKind.distanceWalkingRunning,
        MetricKind.timeInDaylight
    ])
    func wdKindsAreNotSeries(kind: MetricKind) {
        #expect(
            !ChartDetailStore.kindSupportsSeries(kind),
            "\(kind) has no server series enum entry — gate must short-circuit"
        )
    }
}

/// Wire round-trip for the four W-D aggregates: each `ServerMeasurementType`
/// member encodes to the canonical Prisma form, decodes back, and `toDomain()`
/// maps the wire row to the right `MetricKind` so the `/api/measurements` list
/// page surfaces them instead of dropping them via the tolerant decoder.
@Suite("ServerMeasurementType — W-D wire round-trip")
struct ServerMeasurementTypeWDActivityTests {
    @Test("each W-D wire type encodes to its Prisma SCREAMING_SNAKE form", arguments: [
        (ServerMeasurementType.activeEnergyBurned, "ACTIVE_ENERGY_BURNED"),
        (ServerMeasurementType.flightsClimbed, "FLIGHTS_CLIMBED"),
        (ServerMeasurementType.walkingRunningDistance, "WALKING_RUNNING_DISTANCE"),
        (ServerMeasurementType.timeInDaylight, "TIME_IN_DAYLIGHT")
    ])
    func encoding(pair: (ServerMeasurementType, String)) throws {
        let (type, expected) = pair
        let data = try JSONEncoder().encode(type)
        #expect(String(data: data, encoding: .utf8) == "\"\(expected)\"")
    }

    @Test("each W-D wire form round-trips", arguments: [
        ("ACTIVE_ENERGY_BURNED", ServerMeasurementType.activeEnergyBurned),
        ("FLIGHTS_CLIMBED", ServerMeasurementType.flightsClimbed),
        ("WALKING_RUNNING_DISTANCE", ServerMeasurementType.walkingRunningDistance),
        ("TIME_IN_DAYLIGHT", ServerMeasurementType.timeInDaylight)
    ])
    func roundTrip(pair: (String, ServerMeasurementType)) throws {
        let (raw, expected) = pair
        let decoded = try JSONDecoder().decode(ServerMeasurementType.self, from: Data("\"\(raw)\"".utf8))
        #expect(decoded == expected)
    }

    @Test("toDomain maps each W-D wire row to its MetricKind", arguments: [
        (ServerMeasurementType.activeEnergyBurned, MetricKind.activeEnergy),
        (ServerMeasurementType.flightsClimbed, MetricKind.flightsClimbed),
        (ServerMeasurementType.walkingRunningDistance, MetricKind.distanceWalkingRunning),
        (ServerMeasurementType.timeInDaylight, MetricKind.timeInDaylight)
    ])
    func toDomainMapping(pair: (ServerMeasurementType, MetricKind)) {
        let (wireType, expectedKind) = pair
        let wire = MeasurementWireDTO(
            id: "wd-1",
            type: wireType,
            value: 123,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(wire.toDomain()?.kind == expectedKind)
    }
}
