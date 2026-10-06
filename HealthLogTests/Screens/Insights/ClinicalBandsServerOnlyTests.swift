import Foundation
@testable import HealthLog
import Testing

/// #115 · 1.3 — hard-coded clinical bands are gone. A band is drawn or named
/// only when the server sent it (BP target caption from `bpTargets` of
/// `GET /api/insights/comprehensive`); a fixed constant never stands in.
@Suite("Clinical bands — server-only (#115 1.3)")
struct ClinicalBandsServerOnlyTests {
    @Test("BP caption names the band the server sent")
    func bpCaptionFromServerBand() {
        let caption = InsightsMetricStatusDescriptor.bpTargetBandCaption(
            BPTargets(sysLow: 110, sysHigh: 135, diaLow: 65, diaHigh: 85)
        )
        #expect(caption?.contains("110") == true)
        #expect(caption?.contains("135") == true)
    }

    @Test("BP caption with a missing edge is omitted, never filled with 120–129 / 70–79")
    func bpCaptionWithoutFullBandIsOmitted() {
        #expect(InsightsMetricStatusDescriptor.bpTargetBandCaption(BPTargets()) == nil)
        #expect(InsightsMetricStatusDescriptor.bpTargetBandCaption(
            BPTargets(sysLow: 110, sysHigh: 135, diaLow: nil, diaHigh: 85)
        ) == nil)
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .bloodPressure,
            digest: ComprehensiveDigest(bpTargets: BPTargets()),
            target: nil,
            latestValue: nil
        )
        #expect(descriptor.targetBandCaption == nil)
    }

    @Test("charts draw no hard-coded clinical rule (BP 140/60, pulse 100/60, glucose 70/180 mg/dL, fever, SpO2)")
    func chartsDrawNoFixedClinicalRules() {
        for kind in [MetricKind.bloodPressure, .pulse, .glucose, .bodyTemperature, .spo2] {
            #expect(MetricChartContent.clinicalThresholds(for: kind).isEmpty, "fixed rule on \(kind)")
        }
    }
}
