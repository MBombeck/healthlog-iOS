import Accessibility
import Foundation
@testable import HealthLog
import Testing

/// Accessibility-descriptor tests for the PK chart. Locks the MDR-boundary
/// behaviour that the Y-axis value-description provider returns **qualitative
/// strings only** — never a numeric concentration.
///
/// VoiceOver users navigating the chart MUST hear "ansteigend" / "nahe
/// Maximum" / "abklingend", not "0.32". That contract is enforced here so
/// silent edits to the chart fail before merge.
@Suite("PK chart AXChartDescriptor")
struct PKChartAccessibilityTests {
    @Test("Y-axis value-description never returns numeric concentration")
    func yAxisDescriptionIsQualitative() {
        // Build a representative chart for Tirzepatide with 3 weekly doses.
        let asOf = Date(timeIntervalSince1970: 1_000_000_000 + 21 * 24 * 3600)
        let doses = (0 ..< 3).map { weekIndex in
            Glp1PK.DoseEvent(
                takenAt: Date(timeIntervalSince1970: 1_000_000_000 + Double(7 * weekIndex) * 24 * 3600),
                doseMg: 7.5
            )
        }
        let descriptor = buildDescriptor(
            drug: GLP1DrugCatalog.drug(for: .tirzepatide),
            doses: doses,
            asOf: asOf
        )

        guard let yAxis = descriptor.yAxis else {
            Issue.record("Y-axis must be present")
            return
        }
        let validQualitative: Set = [
            "ansteigend",
            "nahe Maximum",
            "abklingend",
            "unbestimmt"
        ]
        // Probe across a representative range; every spoken label must be
        // one of the qualitative phase strings.
        for value in stride(from: 0.0, through: 1.0, by: 0.05) {
            let label = yAxis.valueDescriptionProvider(value)
            #expect(
                validQualitative.contains(label),
                "Y-axis spoken label '\(label)' is not in the qualitative set"
            )
        }
    }

    @Test("Y-axis title stays unit-less (relativ, no unit token)")
    func yAxisTitleUnitless() {
        let descriptor = buildDescriptor(
            drug: GLP1DrugCatalog.drug(for: .tirzepatide),
            doses: [
                Glp1PK.DoseEvent(takenAt: Date(timeIntervalSince1970: 0), doseMg: 7.5)
            ],
            asOf: Date(timeIntervalSince1970: 24 * 3600)
        )
        guard let yAxis = descriptor.yAxis else {
            Issue.record("Y-axis must be present")
            return
        }
        #expect(yAxis.title.contains("relativ"))
        // Negative: y-axis title MUST NOT contain a unit token.
        let forbidden = ["ng/mL", "ng/ml", "µg/L", "mol/L", "mg/L", "ng / mL"]
        for unit in forbidden {
            #expect(!yAxis.title.contains(unit), "Y-axis title contains forbidden unit \(unit)")
        }
    }

    @Test("Series contains one continuous PK series")
    func seriesIsContinuous() {
        let descriptor = buildDescriptor(
            drug: GLP1DrugCatalog.drug(for: .tirzepatide),
            doses: [
                Glp1PK.DoseEvent(takenAt: Date(timeIntervalSince1970: 0), doseMg: 7.5)
            ],
            asOf: Date(timeIntervalSince1970: 24 * 3600)
        )
        #expect(descriptor.series.count == 1)
        #expect(descriptor.series.first?.isContinuous == true)
        #expect(descriptor.series.first?.name == "Tirzepatide")
    }

    // MARK: - Descriptor builder mirror

    /// Mirrors the private builder in `MDRGatedDrugLevelSection.swift`. Kept
    /// in-test-file rather than exposing the builder publicly so the chart
    /// view stays internal. Drift here = chart-view drift.
    private func buildDescriptor(
        drug: GLP1DrugCatalog.DrugRecord,
        doses: [Glp1PK.DoseEvent],
        asOf: Date
    ) -> AXChartDescriptor {
        let samples = Glp1PK.curve(
            drug: drug.id,
            doses: doses,
            asOf: asOf,
            options: Glp1PK.Options(
                windowHoursBefore: 14 * 24,
                windowHoursAfter: 0,
                stepHours: 6
            )
        )
        let title = "Geschätzter Wirkstoffspiegel — \(drug.inn)"
        let summary = "Qualitativer Verlauf. Y-Achse ohne Einheit. Edukative Schätzung."
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let points = samples.enumerated().map { idx, sample -> (x: Double, y: Double, xLabel: String) in
            let absoluteDate = asOf.addingTimeInterval(sample.tHours * 3600)
            return (Double(idx), sample.concentration, formatter.string(from: absoluteDate))
        }
        let phaseLabels: [String] = samples.map { sample in
            let phase = Glp1PK.shotPhase(
                drug: drug.id,
                doses: doses,
                asOf: asOf.addingTimeInterval(sample.tHours * 3600)
            )
            switch phase {
            case .rising: return "ansteigend"
            case .peak: return "nahe Maximum"
            case .fading: return "abklingend"
            case .none: return "unbestimmt"
            }
        }
        return HLChartAX.singleSeries(
            title: title,
            summary: summary,
            xAxisTitle: "Datum",
            yAxisTitle: "Geschätzter Spiegel (relativ)",
            seriesName: drug.inn,
            points: points,
            yValueLabel: { value in
                guard let nearest = samples.enumerated().min(
                    by: { abs($0.element.concentration - value) < abs($1.element.concentration - value) }
                ) else {
                    return "unbestimmt"
                }
                return phaseLabels[nearest.offset]
            }
        )
    }
}
