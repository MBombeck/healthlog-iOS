import Foundation
@testable import HealthLog
import Testing
import UIKit

/// Exhaustiveness contract — every `MetricKind` case must appear in
/// `MetricKindDescriptor.catalog`. If you add a new case to `MetricKind`
/// without adding a descriptor here, this test fails — the dashboard would
/// otherwise fall through to the neutral fallback descriptor and the new
/// tile would render with `questionmark.circle`.
@Suite("MetricKindDescriptor registry")
struct MetricKindDescriptorRegistryTests {
    @Test("every MetricKind case has a descriptor")
    func everyCaseHasDescriptor() {
        for kind in MetricKind.allCases {
            let descriptor = MetricKindDescriptor.catalog[kind]
            #expect(descriptor != nil, "MetricKind.\(kind) missing from MetricKindDescriptor.catalog")
            #expect(descriptor?.kind == kind)
        }
    }

    @Test("descriptors all carry a non-empty SF Symbol")
    func sfSymbolsNonEmpty() {
        for descriptor in MetricKindDescriptor.catalog.values {
            #expect(!descriptor.sfSymbol.isEmpty, "Empty symbol for \(descriptor.kind)")
        }
    }

    @Test("descriptor lookup is total — never returns fallback for known kinds")
    func descriptorLookupNeverFallsBack() {
        for kind in MetricKind.allCases {
            let descriptor = kind.descriptor
            #expect(
                descriptor.sfSymbol != "questionmark.circle",
                "Descriptor for \(kind) accidentally fell through to fallback"
            )
        }
    }

    @Test("BP descriptor uses dualValue render hint")
    func bloodPressureDualValue() {
        let descriptor = MetricKind.bloodPressure.descriptor
        #expect(descriptor.renderHint == .dualValue)
        #expect(descriptor.formatStyle == .bloodPressureCompound)
    }

    @Test("sleep descriptor uses sleepDuration render hint")
    func sleepUsesDurationHint() {
        let descriptor = MetricKind.sleep.descriptor
        #expect(descriptor.renderHint == .sleepDuration)
        #expect(descriptor.formatStyle == .durationHM)
    }

    @Test("steps descriptor groups integers")
    func stepsGroupedInteger() {
        let descriptor = MetricKind.steps.descriptor
        #expect(descriptor.formatStyle == .groupedInteger)
        #expect(descriptor.trendPolarity == .higherIsBetter)
    }

    @Test("formattedPrimary handles nil latestValue gracefully")
    func formattedPrimaryNil() {
        let metric = DashboardMetric(
            id: "weight",
            kind: .weight,
            title: "Gewicht",
            latestValue: nil,
            secondaryValue: nil,
            unit: "kg",
            trend: .unknown,
            sparkline: [],
            updatedAt: nil
        )
        #expect(metric.formattedPrimary() == "—")
    }

    @Test("formattedPrimary renders weight with 1 decimal")
    func formattedPrimaryWeight() {
        let metric = DashboardMetric(
            id: "weight",
            kind: .weight,
            title: "Gewicht",
            latestValue: 72.345,
            secondaryValue: nil,
            unit: "kg",
            trend: .down,
            sparkline: [73, 72.5, 72.3],
            updatedAt: nil
        )
        let formatted = metric.formattedPrimary()
        // Locale-dependent grouping — assert the digit core.
        #expect(formatted.contains("72"), "Expected weight formatting to contain 72, got \(formatted)")
    }

    @Test("formattedPrimary renders BP as sys/dia")
    func formattedPrimaryBloodPressure() {
        let metric = DashboardMetric(
            id: "bp",
            kind: .bloodPressure,
            title: "Blutdruck",
            latestValue: 124.6,
            secondaryValue: 81.2,
            unit: "mmHg",
            trend: .flat,
            sparkline: [120, 122, 124],
            updatedAt: nil
        )
        #expect(metric.formattedPrimary() == "125/81")
    }

    @Test("formattedPrimary renders steps grouped")
    func formattedPrimarySteps() {
        let metric = DashboardMetric(
            id: "steps",
            kind: .steps,
            title: "Schritte",
            latestValue: 8534,
            secondaryValue: nil,
            unit: "Schritte",
            trend: .up,
            sparkline: [6000, 7000, 8534],
            updatedAt: nil
        )
        let formatted = metric.formattedPrimary()
        #expect(formatted.contains("8"), "Steps formatter dropped digits: \(formatted)")
    }

    @Test("formattedPrimary renders sleep as Xh Ym")
    func formattedPrimarySleep() {
        let metric = DashboardMetric(
            id: "sleep",
            kind: .sleep,
            title: "Schlaf",
            latestValue: 7.5, // 7h 30m
            secondaryValue: nil,
            unit: "h",
            trend: .flat,
            sparkline: [7.0, 7.25, 7.5],
            updatedAt: nil
        )
        let formatted = metric.formattedPrimary()
        #expect(formatted.contains("7"), "Sleep formatter dropped hours: \(formatted)")
        #expect(formatted.contains("30"), "Sleep formatter dropped minutes: \(formatted)")
    }

    // MARK: - W-CRASHGUARD — non-finite / out-of-range server values render the

    // em-dash placeholder instead of trapping `Int(...)`.

    private func metric(kind: MetricKind, latest: Double?, secondary: Double? = nil) -> DashboardMetric {
        DashboardMetric(
            id: kind.rawValue,
            kind: kind,
            title: kind.rawValue,
            latestValue: latest,
            secondaryValue: secondary,
            unit: "",
            trend: .unknown,
            sparkline: [],
            updatedAt: nil
        )
    }

    @Test("formattedPrimary em-dashes a non-finite grouped-integer value")
    func formattedPrimaryNonFiniteSteps() {
        #expect(metric(kind: .steps, latest: .infinity).formattedPrimary() == "—")
        #expect(metric(kind: .steps, latest: .nan).formattedPrimary() == "—")
    }

    @Test("formattedPrimary em-dashes an out-of-range grouped-integer value")
    func formattedPrimaryOutOfRangeSteps() {
        // `1e30` is finite but far out of `Int.range` — the old
        // `Int(latest.rounded())` trapped here.
        #expect(metric(kind: .steps, latest: 1e30).formattedPrimary() == "—")
    }

    @Test("formattedPrimary em-dashes an out-of-range BP compound operand")
    func formattedPrimaryOutOfRangeBP() {
        #expect(metric(kind: .bloodPressure, latest: 1e30, secondary: 80).formattedPrimary() == "—")
        #expect(metric(kind: .bloodPressure, latest: 120, secondary: .infinity).formattedPrimary() == "—")
    }

    @Test("Dashboard.displayValue em-dashes a non-finite / out-of-range BP pair")
    func displayValueGuardsBP() {
        #expect(metric(kind: .bloodPressure, latest: .infinity, secondary: 80).displayValue == "—")
        #expect(metric(kind: .bloodPressure, latest: 1e30, secondary: 80).displayValue == "—")
        #expect(metric(kind: .bloodPressure, latest: 124, secondary: 81).displayValue == "124/81")
    }

    // MARK: - Theme-2.0 final (T2-5 deletion, 2026-05-16)

    //
    // Pre-Theme-2.0 each descriptor's `tint` resolved to a Dracula family hue
    // (red Vitals / orange Activity / cyan Body / purple Sleep / grey Other).
    // Operator Theme-2.0 verdict killed family-tinting entirely ("muss einfach
    // mehr clean aussehen"). T2-1 redefined `HLColor.dashboardCategory*` to
    // resolve to `HLSurface.secondary`, T2-2 swept the descriptor registry
    // onto the new token directly, and T2-5 deleted the legacy alias
    // namespace. This test locks the consumer-side invariant: every
    // production descriptor's `tint` field resolves to the operator-locked
    // mono surface, so a partial rollback that re-introduces a family hue
    // (or any non-surface colour) fails the build.

    @Test("Theme-2.0 final: descriptor tints collapse to mono surface")
    @MainActor
    func descriptorTintsCollapseToMonoSurface() {
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let allCategoryKinds: [MetricKind] = [
            .weight, .bloodPressure, .pulse, .bodyFat,
            .steps,
            .bodyWater, .boneMass,
            .sleep,
            .glucose, .bodyTemperature, .spo2,
            // v0.5.2 F2 HK-completeness additions
            .restingHeartRate, .hrv, .vo2Max,
            .walkingSpeed, .walkingAsymmetry, .walkingStepLength, .bmi,
            // v0.7.0 HK adopt-and-stream additions
            .walkingDoubleSupport, .respiratoryRate,
            .audioExposureEnvironment, .audioExposureHeadphone,
            // v0.8.3 W-D render-backlog activity aggregates
            .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight,
            // v0.11 W21 web-parity body-composition + cardio additions
            .fatFreeMass, .leanBodyMass, .muscleMass, .skinTemperature,
            .pulseWaveVelocity, .vascularAge, .visceralFat, .walkingHeartRate,
            // v0.11 reconcile (F3) — 9th W21 type
            .fatMass,
            // v0.13.1 IC — v1.10.0 additive HealthKit signals (all mono).
            .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
            .breathingDisturbances, .cardioRecovery, .wristTemperature,
            // v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23).
            .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation
        ]
        for kind in allCategoryKinds {
            #expect(
                TokensRegressionTests.resolvedHex(of: kind.descriptor.tint, traits: lightTraits) == 0xFAF8F5,
                "Light-mode tint for \(kind) drifted off Theme-2.0 mono surface"
            )
            #expect(
                TokensRegressionTests.resolvedHex(of: kind.descriptor.tint, traits: darkTraits) == 0x1A1B1F,
                "Dark-mode tint for \(kind) drifted off Theme-2.0 mono surface"
            )
        }
    }
}

// MARK: - W-B189 (#23) — v1.17.1 source-fixed render-only signals

/// Locks in the four v1.17.1 `MeasurementType` additions: they must decode from
/// both the domain `MetricKind` raw value AND the server wire `type`, carry
/// non-empty display metadata, and — for `bodyTemperatureDeviation` — format as
/// a SIGNED offset (never an absolute temperature).
@Suite("W-B189 source-fixed v1.17.1 measurement types")
struct SourceFixedV1171MeasurementTypeTests {
    private static let newKinds: [MetricKind] = [
        .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation
    ]

    @Test("each new MetricKind decodes from its raw value")
    func metricKindRawValueDecodes() {
        let expected: [(String, MetricKind)] = [
            ("ansCharge", .ansCharge),
            ("cardioLoad", .cardioLoad),
            ("sleepScore", .sleepScore),
            ("bodyTemperatureDeviation", .bodyTemperatureDeviation)
        ]
        for (raw, kind) in expected {
            #expect(MetricKind(rawValue: raw) == kind, "raw \(raw) did not decode to \(kind)")
        }
    }

    @Test("each new server wire type decodes + maps to its MetricKind")
    func serverWireTypeDecodesAndMaps() {
        // (wire string, server enum, expected domain kind). Pair the two
        // identifiers via a dictionary so SwiftLint's `large_tuple` rule never
        // sees a 3-member tuple.
        let serverTypes: [String: ServerMeasurementType] = [
            "ANS_CHARGE": .ansCharge,
            "CARDIO_LOAD": .cardioLoad,
            "SLEEP_SCORE": .sleepScore,
            "BODY_TEMPERATURE_DEVIATION": .bodyTemperatureDeviation
        ]
        let kinds: [ServerMeasurementType: MetricKind] = [
            .ansCharge: .ansCharge,
            .cardioLoad: .cardioLoad,
            .sleepScore: .sleepScore,
            .bodyTemperatureDeviation: .bodyTemperatureDeviation
        ]
        for (wire, serverType) in serverTypes {
            #expect(ServerMeasurementType(rawValue: wire) == serverType, "wire \(wire) did not decode")
            let dto = MeasurementWireDTO(
                id: "id-\(wire)",
                type: serverType,
                value: 1,
                measuredAt: Date(timeIntervalSince1970: 0)
            )
            #expect(dto.toDomain()?.kind == kinds[serverType], "wire \(wire) mapped to wrong kind")
        }
    }

    @Test("a row with an unknown future type is dropped, not rejected (tolerant decode)")
    func unknownTypeTolerated() throws {
        let json = """
        {"measurements":[
          {"id":"a","type":"ANS_CHARGE","value":3.2,"measuredAt":"1970-01-01T00:00:00Z"},
          {"id":"b","type":"SOME_FUTURE_TYPE_2099","value":9,"measuredAt":"1970-01-01T00:00:00Z"}
        ]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let resp = try decoder.decode(MeasurementListWireResponse.self, from: Data(json.utf8))
        #expect(resp.measurements.count == 1, "tolerant decoder should keep the known row, drop the unknown")
        #expect(resp.measurements.first?.type == .ansCharge)
    }

    @Test("each new kind has non-empty display metadata")
    func displayMetadataNonEmpty() {
        for kind in Self.newKinds {
            let d = kind.descriptor
            #expect(d.kind == kind)
            #expect(!d.sfSymbol.isEmpty, "\(kind) has empty SF symbol")
            #expect(d.sfSymbol != "questionmark.circle", "\(kind) fell through to fallback descriptor")
            #expect(!String(localized: d.title).isEmpty, "\(kind) has empty title")
        }
    }

    @Test("body-temperature deviation is a distinct kind, never the absolute body temperature")
    func deviationIsDistinctFromAbsolute() {
        #expect(MetricKind.bodyTemperatureDeviation != MetricKind.bodyTemperature)
        // Wire mapping must NOT collapse the deviation into the absolute bucket.
        let dev = MeasurementWireDTO(
            id: "dev", type: .bodyTemperatureDeviation, value: 0.3, measuredAt: Date()
        )
        #expect(dev.toDomain()?.kind == .bodyTemperatureDeviation)
        // It carries °C as a label but a "deviation from baseline" secondary hint.
        let d = MetricKind.bodyTemperatureDeviation.descriptor
        #expect(d.formatStyle == .signedDecimal1)
        #expect(d.secondaryHint != nil, "deviation must carry a baseline label")
    }

    /// Locale-normalised: the magnitude's decimal separator is locale-dependent
    /// (`.` en, `,` de) by design — the formatter is `.number`-locale-aware so a
    /// German user sees `+0,3`. We normalise `,` → `.` before comparing so the
    /// test asserts the SIGN + the MAGNITUDE, not the host locale's separator.
    private func normSep(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: ".")
    }

    @Test("signed-deviation formatting carries an explicit sign, never an absolute reading")
    func signedDeviationFormatting() {
        // +0.3 → "+0.3"
        #expect(normSep(MetricKindDescriptor.formatSignedDecimal1(0.3)) == "+0.3")
        // −0.2 → "−0.2" (Unicode MINUS SIGN U+2212)
        #expect(normSep(MetricKindDescriptor.formatSignedDecimal1(-0.2)) == "\u{2212}0.2")
        // 0.0 → "0.0" (no sign)
        #expect(normSep(MetricKindDescriptor.formatSignedDecimal1(0.0)) == "0.0")
        // rounds magnitude to 1 fraction digit
        #expect(normSep(MetricKindDescriptor.formatSignedDecimal1(0.34)) == "+0.3")
        #expect(normSep(MetricKindDescriptor.formatSignedDecimal1(-0.04)) == "0.0")
        // The negative case must carry the Unicode MINUS SIGN, not a hyphen.
        #expect(MetricKindDescriptor.formatSignedDecimal1(-0.2).hasPrefix("\u{2212}"))
        // It must NEVER read as an absolute body temperature (37.x).
        let formatted = MetricKindDescriptor.formatSignedDecimal1(0.3)
        #expect(!formatted.contains("37"), "deviation must not render as an absolute temperature")
    }

    @Test("formattedPrimary routes the deviation through the signed formatter")
    func dashboardMetricSignedDeviation() {
        let positive = DashboardMetric(
            id: "btd", kind: .bodyTemperatureDeviation, title: "Temp deviation",
            latestValue: 0.3, secondaryValue: nil, unit: "°C",
            trend: .flat, sparkline: [], updatedAt: nil
        )
        #expect(normSep(positive.formattedPrimary()) == "+0.3")
        let negative = DashboardMetric(
            id: "btd", kind: .bodyTemperatureDeviation, title: "Temp deviation",
            latestValue: -0.2, secondaryValue: nil, unit: "°C",
            trend: .flat, sparkline: [], updatedAt: nil
        )
        #expect(normSep(negative.formattedPrimary()) == "\u{2212}0.2")
    }
}
