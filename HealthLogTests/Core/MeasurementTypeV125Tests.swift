import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0158 — v1.25 clinical measurement types (`PAIN_NRS`, `GRIP_STRENGTH`,
/// `WAIST_CIRCUMFERENCE`, `WAIST_TO_HEIGHT`). Pins the wire↔domain contract,
/// the manual create-DTO arms, the descriptor/range coverage, and the
/// render-only posture of waist-to-height.
@Suite("MeasurementType — v1.25 clinical additions")
struct MeasurementTypeV125Tests {
    // MARK: - Wire ↔ MetricKind round-trip

    @Test("each new server type encodes to its SCREAMING_SNAKE wire form", arguments: [
        (ServerMeasurementType.painNRS, "PAIN_NRS"),
        (ServerMeasurementType.gripStrength, "GRIP_STRENGTH"),
        (ServerMeasurementType.waistCircumference, "WAIST_CIRCUMFERENCE"),
        (ServerMeasurementType.waistToHeight, "WAIST_TO_HEIGHT")
    ])
    func wireEncoding(pair: (ServerMeasurementType, String)) throws {
        let (type, wire) = pair
        let data = try JSONEncoder().encode(type)
        #expect(String(data: data, encoding: .utf8) == "\"\(wire)\"")
    }

    @Test("each new wire form decodes back to its server type", arguments: [
        ("PAIN_NRS", ServerMeasurementType.painNRS),
        ("GRIP_STRENGTH", ServerMeasurementType.gripStrength),
        ("WAIST_CIRCUMFERENCE", ServerMeasurementType.waistCircumference),
        ("WAIST_TO_HEIGHT", ServerMeasurementType.waistToHeight)
    ])
    func wireDecoding(pair: (String, ServerMeasurementType)) throws {
        let (wire, type) = pair
        let decoded = try JSONDecoder().decode(ServerMeasurementType.self, from: Data("\"\(wire)\"".utf8))
        #expect(decoded == type)
    }

    @Test("each new server type maps to its MetricKind", arguments: [
        (ServerMeasurementType.painNRS, MetricKind.painNRS),
        (ServerMeasurementType.gripStrength, MetricKind.gripStrength),
        (ServerMeasurementType.waistCircumference, MetricKind.waistCircumference),
        (ServerMeasurementType.waistToHeight, MetricKind.waistToHeight)
    ])
    func serverTypeMapsToKind(pair: (ServerMeasurementType, MetricKind)) {
        #expect(pair.0.metricKind == pair.1)
    }

    @Test("toDomain decodes a wire row to the right MetricKind", arguments: [
        (ServerMeasurementType.painNRS, MetricKind.painNRS),
        (ServerMeasurementType.gripStrength, MetricKind.gripStrength),
        (ServerMeasurementType.waistCircumference, MetricKind.waistCircumference),
        (ServerMeasurementType.waistToHeight, MetricKind.waistToHeight)
    ])
    func toDomainMapsKind(pair: (ServerMeasurementType, MetricKind)) {
        let wire = MeasurementWireDTO(
            id: "id-\(pair.0.rawValue)",
            type: pair.0,
            value: 5,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(wire.toDomain()?.kind == pair.1)
    }

    @Test("enum coverage — both enums carry every new case")
    func enumCoverage() {
        let serverRaws = Set(ServerMeasurementType.allCases.map(\.rawValue))
        for wire in ["PAIN_NRS", "GRIP_STRENGTH", "WAIST_CIRCUMFERENCE", "WAIST_TO_HEIGHT"] {
            #expect(serverRaws.contains(wire), "ServerMeasurementType missing \(wire)")
        }
        let kindRaws = Set(MetricKind.allCases.map(\.rawValue))
        for raw in ["painNRS", "gripStrength", "waistCircumference", "waistToHeight"] {
            #expect(kindRaws.contains(raw), "MetricKind missing \(raw)")
        }
    }

    // MARK: - Manual create-DTO arms

    @Test("manual kinds emit exactly one wire row", arguments: [
        (MetricKind.painNRS, ServerMeasurementType.painNRS),
        (MetricKind.gripStrength, ServerMeasurementType.gripStrength),
        (MetricKind.waistCircumference, ServerMeasurementType.waistCircumference)
    ])
    func manualKindsEmitWireRow(pair: (MetricKind, ServerMeasurementType)) {
        let measurement = Measurement(
            id: "m",
            kind: pair.0,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .scalar(7),
            source: .manual,
            externalUUID: "ext"
        )
        let dtos = measurement.toCreateDTOs()
        #expect(dtos.count == 1, "\(pair.0) must emit one wire row")
        #expect(dtos.first?.type == pair.1)
        #expect(dtos.first?.value == 7)
        #expect(dtos.first?.source == .manual)
    }

    @Test("waist-to-height is RENDER-ONLY — no manual wire row")
    func waistToHeightEmitsNoWireRow() {
        let measurement = Measurement(
            id: "wth",
            kind: .waistToHeight,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            value: .scalar(0.52),
            source: .manual,
            externalUUID: "ext"
        )
        #expect(measurement.toCreateDTOs().isEmpty, "waistToHeight must NOT emit a wire row")
    }

    // MARK: - Render-only display (waist-to-height)

    @Test("waist-to-height DECODES + DISPLAYS even though it has no capture path")
    func waistToHeightDecodesAndDisplays() throws {
        // Decode a server row.
        let wire = MeasurementWireDTO(
            id: "wth-1",
            type: .waistToHeight,
            value: 0.48,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let domain = try #require(wire.toDomain())
        #expect(domain.kind == .waistToHeight)
        #expect(domain.primaryValue == 0.48)
        // Display metadata present (tile / chart can render it).
        let descriptor = MetricKind.waistToHeight.descriptor
        #expect(descriptor.kind == .waistToHeight)
        #expect(!descriptor.sfSymbol.isEmpty)
        #expect(descriptor.sfSymbol != "questionmark.circle")
        #expect(!String(localized: descriptor.title).isEmpty)
        // But no manual range guard (no manual entry).
        #expect(MeasurementRanges.range(for: .waistToHeight) == nil)
    }

    // MARK: - Descriptor + range + polarity coverage

    @Test("every new kind has a descriptor with a real symbol + non-empty title", arguments: [
        MetricKind.painNRS, .gripStrength, .waistCircumference, .waistToHeight
    ])
    func descriptorCoverage(kind: MetricKind) {
        let d = MetricKindDescriptor.catalog[kind]
        #expect(d != nil, "missing descriptor for \(kind)")
        #expect(d?.sfSymbol.isEmpty == false)
        #expect(d?.sfSymbol != "questionmark.circle")
        #expect(!String(localized: kind.descriptor.title).isEmpty)
    }

    @Test("favourable directions mirror the server registry")
    func polarities() {
        #expect(MetricKind.painNRS.descriptor.trendPolarity == .lowerIsBetter)
        #expect(MetricKind.gripStrength.descriptor.trendPolarity == .higherIsBetter)
        #expect(MetricKind.waistCircumference.descriptor.trendPolarity == .lowerIsBetter)
        #expect(MetricKind.waistToHeight.descriptor.trendPolarity == .lowerIsBetter)
    }

    @Test("manual kinds carry the server sane bands")
    func ranges() {
        #expect(MeasurementRanges.range(for: .painNRS) == 0 ... 10)
        #expect(MeasurementRanges.range(for: .gripStrength) == 0 ... 120)
        #expect(MeasurementRanges.range(for: .waistCircumference) == 30 ... 250)
    }

    // MARK: - Dashboard widget-id round-trip

    @Test("each new kind round-trips through its dashboard widget id", arguments: [
        MetricKind.painNRS, .gripStrength, .waistCircumference, .waistToHeight
    ])
    func widgetIdRoundTrip(kind: MetricKind) {
        let id = DashboardWidgetId.id(forMetricKind: kind)
        #expect(id != nil)
        if let id {
            #expect(DashboardWidgetId.metricKind(forId: id) == kind)
        }
    }
}
