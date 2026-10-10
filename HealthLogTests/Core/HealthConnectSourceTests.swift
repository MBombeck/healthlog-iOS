import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Server v1.42.0: `HEALTH_CONNECT` joins every
/// `source` enum (measurements, workouts, source priority, list filters). Rows
/// come from the web Health Connect import only; the app never writes the
/// source (it is not in `WRITABLE_MEASUREMENT_SOURCES`).
///
/// Wire spelling from `docs/api/openapi.yaml` on `release/v1.42.0` (the
/// `sourceEq` filter enum of `GET /api/measurements` and every source-priority
/// ladder enum). Before this build the value decoded onto `.unknown`: no row
/// was lost, but it read as "Unknown source" and was offered as editable.
@Suite("HEALTH_CONNECT source (server v1.42)")
struct HealthConnectSourceTests {
    @Test("HEALTH_CONNECT round-trips verbatim and maps to its own domain case")
    func wireRoundTrip() throws {
        let decoded = try JSONDecoder().decode(ServerMeasurementSource.self, from: Data(#""HEALTH_CONNECT""#.utf8))
        #expect(decoded == .healthConnect)
        #expect(decoded.toDomain() == .healthConnect)
        #expect(MeasurementSource.healthConnect.wire == .healthConnect)
        let encoded = try String(data: JSONEncoder().encode(ServerMeasurementSource.healthConnect), encoding: .utf8)
        #expect(encoded == #""HEALTH_CONNECT""#)
    }

    @Test("a HEALTH_CONNECT row survives the list decode with its own source, not unknown")
    func listRowKeepsItsSource() throws {
        let json = """
        { "measurements": [
          { "id": "hc1", "type": "WEIGHT", "value": 80.4, "measuredAt": "2026-10-01T07:00:00Z", "source": "HEALTH_CONNECT" },
          { "id": "m1", "type": "WEIGHT", "value": 80.1, "measuredAt": "2026-10-02T07:00:00Z", "source": "MANUAL" }
        ] }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(MeasurementListWireResponse.self, from: Data(json.utf8))
        #expect(response.measurements.count == 2)
        let row = try #require(response.measurements.first { $0.id == "hc1" })
        #expect(row.source == .healthConnect)
    }

    @Test("a Health Connect value is read-only and never mirrored into Apple Health")
    func readOnlyAndNotMirrored() {
        let row = HealthLog.Measurement(
            id: "hc1",
            kind: .weight,
            recordedAt: Date(),
            value: .scalar(80),
            source: .healthConnect
        )
        #expect(row.isServerDerivedReadOnly)
        #expect(!MeasurementSource.healthConnect.isServerMirrorEligible)
        #expect(!MeasurementSource.serverMirrorEligible.contains(.healthConnect))
    }

    @MainActor
    @Test("the source label and icon name it, on every surface")
    func labelAndIcon() {
        #expect(SourcePriorityRow.displayLabel(forSource: "HEALTH_CONNECT") == "Health Connect")
        #expect(SourcePriorityRow.displayLabel(forSource: "HEALTH_CONNECT") != String(localized: "measurement.source.unknown"))
        #expect(SourcePriorityRow.iconName(forSource: "HEALTH_CONNECT") == "link.circle.fill")
        #expect(SourcePriorityRow.iconName(forSource: "HEALTH_CONNECT") != SourcePriorityRow.iconName(forSource: "SOMETHING_NEW"))
        // Workouts carry `source` as a raw string; the detail reads the same table.
        #expect(WorkoutDetailView.sourceLabel("HEALTH_CONNECT") == "Health Connect")
        #expect(SourceFilterChips.label(for: .healthConnect) == String(localized: "Health Connect"))
    }

    @Test("the measurement list offers a Health Connect filter chip once such a row is loaded")
    func filterChip() {
        let rows = [
            HealthLog.Measurement(id: "a", kind: .weight, recordedAt: Date(), value: .scalar(80), source: .manual),
            HealthLog.Measurement(id: "b", kind: .weight, recordedAt: Date(), value: .scalar(81), source: .healthConnect)
        ]
        let chips = MeasurementListFilter.availableSources(in: rows)
        #expect(chips.contains(.healthConnect))
        #expect(!chips.contains(.unknown))
    }
}
