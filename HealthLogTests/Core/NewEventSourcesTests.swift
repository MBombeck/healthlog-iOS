import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// W-NEW-EVENT-SOURCES (#23) — locks the two new server data-type surfaces that
/// landed with server v1.18.11:
///
///  1. **Withings ECG / AFib** → the EXISTING irregular-rhythm event type. The
///     server emits the SAME `IRREGULAR_RHYTHM_NOTIFICATION` event regardless of
///     which wearable produced it, so the only honest signal of WHICH device
///     decided is the row's `source` / `deviceType`. iOS now renders that
///     attribution (it was decoded but dropped before) — a Withings-sourced AFib
///     event must read "Withings" / its device model, never blank.
///  2. **Oura cardiovascular age** → `VASCULAR_AGE`. The kind was already
///     registered for Withings (meastype 155); these tests pin that the SAME
///     pipeline carries the metric end-to-end (wire decode → domain kind →
///     descriptor format/unit/category → Insights explainer) so an Oura-sourced
///     `VASCULAR_AGE` row lights up the existing first-class metric page.
///
/// iOS NEVER re-classifies a cardiac event — the server owns the verdict; iOS
/// renders the result + honest source. These tests are the drift sentinel.
@Suite("W-NEW-EVENT-SOURCES — Withings AFib attribution + Oura vascular age")
struct NewEventSourcesTests {
    // MARK: - Part 1 — Withings-sourced irregular-rhythm event attribution

    @Test("Withings-sourced AFib event decodes with its source + device")
    func withingsAFibEventDecodes() throws {
        // Same wire shape as APPLE_HEALTH (server emits the identical event type)
        // — only `source` / `deviceType` differ. Withings ScanWatch ECG → AFib.
        let body = Data(#"""
        {
          "id": "evt-w1",
          "type": "IRREGULAR_RHYTHM_NOTIFICATION",
          "classification": "IRREGULAR",
          "occurredAt": "2026-06-15T07:42:00Z",
          "source": "WITHINGS",
          "deviceType": "ScanWatch"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(RhythmEventsDTO.Event.self, from: body)
        #expect(event.type == "IRREGULAR_RHYTHM_NOTIFICATION")
        #expect(event.classification == "IRREGULAR")
        #expect(event.source == "WITHINGS")
        #expect(event.deviceType == "ScanWatch")
    }

    @Test("Withings source resolves to an honest attribution label (device wins)")
    func withingsSourceLabel() {
        // A concrete device model is the most honest attribution — it names the
        // actual producer of the verdict.
        #expect(InsightsRhythmEventsCard.sourceLabel(for: "WITHINGS", deviceType: "ScanWatch") == "ScanWatch")
        // No device model → fall back to the canonical friendly source label.
        let label = InsightsRhythmEventsCard.sourceLabel(for: "WITHINGS", deviceType: nil)
        #expect(label == SourcePriorityRow.displayLabel(forSource: "WITHINGS"))
        #expect(label == "Withings")
    }

    @Test("Apple Health source resolves to the canonical friendly label")
    func appleHealthSourceLabel() {
        #expect(InsightsRhythmEventsCard.sourceLabel(for: "APPLE_HEALTH", deviceType: nil) == "Apple Health")
        // Device model still wins when present.
        #expect(InsightsRhythmEventsCard.sourceLabel(for: "APPLE_HEALTH", deviceType: "Apple Watch") == "Apple Watch")
    }

    @Test("synthetic / absent sources carry no attribution (no blank qualifier)")
    func syntheticSourcesSuppressed() {
        // A device-flagged cardiac event never originates from a manual entry;
        // attributing one would mislead. Absent source → nil (no dangling "·").
        #expect(InsightsRhythmEventsCard.sourceLabel(for: "MANUAL", deviceType: nil) == nil)
        #expect(InsightsRhythmEventsCard.sourceLabel(for: "IMPORT", deviceType: nil) == nil)
        #expect(InsightsRhythmEventsCard.sourceLabel(for: nil, deviceType: nil) == nil)
        #expect(InsightsRhythmEventsCard.sourceLabel(for: "", deviceType: "") == nil)
        // But a device model on a manual/absent source is still honest.
        #expect(InsightsRhythmEventsCard.sourceLabel(for: "MANUAL", deviceType: "ScanWatch") == "ScanWatch")
    }

    @Test("VoiceOver label folds in the device attribution")
    func accessibilityLabelIncludesSource() {
        let label = InsightsRhythmEventsCard.accessibilityLabel(
            label: "Irregular rhythm notification",
            verdict: "Your device flagged a possible irregular rhythm.",
            source: "Withings"
        )
        #expect(label.contains("Irregular rhythm notification"))
        #expect(label.contains("Withings"))
        // No source → no trailing "Recorded by" fragment, still a clean label.
        let noSource = InsightsRhythmEventsCard.accessibilityLabel(
            label: "Irregular rhythm notification",
            verdict: nil,
            source: nil
        )
        #expect(noSource == "Irregular rhythm notification")
    }

    // MARK: - Part 2 — Oura / Withings VASCULAR_AGE first-class metric

    @Test("VASCULAR_AGE wire identifier decodes to the vascularAge domain kind")
    func vascularAgeWireRoundTrip() throws {
        let decoded = try JSONDecoder().decode(
            ServerMeasurementType.self,
            from: Data("\"VASCULAR_AGE\"".utf8)
        )
        #expect(decoded == .vascularAge)
        let encoded = try JSONEncoder().encode(ServerMeasurementType.vascularAge)
        #expect(String(data: encoded, encoding: .utf8) == "\"VASCULAR_AGE\"")
    }

    @Test("a VASCULAR_AGE measurement row maps to MetricKind.vascularAge")
    func vascularAgeToDomain() throws {
        // Mirrors a server row (Oura cardiovascular age = years), source-fixed.
        let wire = MeasurementWireDTO(
            id: "va-1",
            type: .vascularAge,
            value: 38,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: .withings
        )
        let domain = try #require(wire.toDomain())
        #expect(domain.kind == .vascularAge)
        #expect(domain.primaryValue == 38)
    }

    @Test("vascular age descriptor: integer years, lower-is-better, drill-down")
    func vascularAgeDescriptor() {
        let descriptor = MetricKind.vascularAge.descriptor
        #expect(descriptor.kind == .vascularAge)
        #expect(MetricKind.vascularAge.unit == "years")
        #expect(descriptor.formatStyle == .integer)
        #expect(descriptor.trendPolarity == .lowerIsBetter)
        #expect(descriptor.supportsDrillDown, "vascular age must open a chart-detail / Insights page")
        #expect(descriptor.sfSymbol != "questionmark.circle", "must not fall through to the fallback descriptor")
        #expect(!MetricKind.vascularAge.displayName.isEmpty)
    }

    @Test("vascular age formats as whole years (no decimals)")
    func vascularAgeFormatsInteger() {
        let metric = DashboardMetric(
            id: "vascularAge",
            kind: .vascularAge,
            title: "Vascular age",
            latestValue: 41.6,
            secondaryValue: nil,
            unit: "years",
            trend: .down,
            sparkline: [44, 42, 41.6],
            updatedAt: nil
        )
        let formatted = metric.formattedPrimary()
        // Integer style rounds to whole years; never "41.6".
        #expect(formatted.contains("42"), "Expected whole-year rounding, got \(formatted)")
        #expect(!formatted.contains("."), "Vascular age must render integer years, got \(formatted)")
    }

    @Test("vascular age slots into the heart Insights category")
    func vascularAgeCategory() {
        #expect(InsightsCategoryGroups.category(for: .vascularAge) == .heart)
    }

    @Test("vascular age carries an explainer that names it an estimate and says whose it is")
    func vascularAgeExplainerIsMDRCareful() throws {
        let copy = try #require(
            InsightsExplainer.resolve(for: .vascularAge),
            "vascular age must surface an explanatory paragraph (non-obvious metric)"
        )
        #expect(!copy.title.isEmpty)
        #expect(!copy.body.isEmpty)
        // MDR-careful framing, in either resolved locale. The test host resolves
        // the catalog to its active locale, so accept EN or DE.
        //
        // UI-Standard R17 (U1) — bis hierher verlangte dieser Test zusätzlich
        // den Satzteil „keine medizinische Diagnose". Der ist gefallen: er ist
        // der Pauschal-Schwanz, der auf sechs Metrikseiten nahezu wortgleich
        // stand und dessen Substanz am Ack-Sheet und in Einstellungen → Über
        // diese App lebt. Was die MDR-Vorsicht tatsächlich trägt, steht
        // weiterhin da und wird hier festgenagelt: es ist eine SCHÄTZUNG, sie
        // stammt vom GERÄT des Nutzers (Waage/Ring, nicht HealthLog), und sie
        // blickt zurück statt vorherzusagen.
        let body = copy.body.lowercased()
        #expect(
            body.contains("estimate") || body.contains("schätzung"),
            "explainer must frame vascular age as an estimate"
        )
        #expect(
            body.contains("scale or ring") || body.contains("waage oder dein ring"),
            "explainer must attribute the estimate to the user's device, not to HealthLog"
        )
        #expect(
            body.contains("past readings") || body.contains("vergangene werte"),
            "explainer must say it looks back rather than predicts"
        )
    }
}

// swiftlint:enable force_unwrapping
