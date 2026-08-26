import Foundation
@testable import HealthLog
import Testing

/// **CU-11 — leaf labels are a lookup, never a vocabulary.**
///
/// The point of this suite is the *last* case: an id nobody has ever seen still
/// renders as words. That is what makes it safe for the panel to be driven
/// entirely by `capabilities.share.leaves` — a leaf the server adds tomorrow
/// shows up on a build shipped today instead of vanishing behind a dotted key.
@Suite("ReportLeafDisplay")
struct ReportLeafDisplayTests {
    @Test("a measurement leaf reuses the metric's own localized title")
    func measurementLeafUsesMetricTitle() throws {
        let kind = try #require(ServerMeasurementType(rawValue: "WEIGHT")?.metricKind)
        let expected = String(localized: MetricKindDescriptor.descriptor(for: kind).title)
        #expect(ReportLeafDisplay.label(for: "WEIGHT") == expected)
        // Never the raw wire token.
        #expect(ReportLeafDisplay.label(for: "WEIGHT") != "WEIGHT")
    }

    @Test("a structured leaf resolves from the string catalog")
    func structuredLeafUsesCatalog() {
        let label = ReportLeafDisplay.label(for: "LAB_RESULTS")
        #expect(label != "LAB_RESULTS")
        #expect(label != "report.leaf.LAB_RESULTS")
        #expect(label.isEmpty == false)
    }

    @Test("an id this build has never heard of still reads as words")
    func unknownLeafIsHumanized() {
        #expect(ReportLeafDisplay.label(for: "SOME_FUTURE_LEAF") == "Some future leaf")
        #expect(ReportLeafDisplay.label(for: "SINGLE") == "Single")
    }
}
