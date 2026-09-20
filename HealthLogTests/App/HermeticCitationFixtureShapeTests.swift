import Foundation
@testable import HealthLog
import Testing

/// **1.0.3 (App Review 1.4.1) — the citation fixtures, decoded the way the app
/// decodes them.**
///
/// `HermeticFixtures+Citations` exists so `MedicalSourcesReviewPathUITests` can
/// photograph the four citation surfaces that need account data behind them. A
/// fixture there is only worth anything if the app's OWN decoder accepts it,
/// and the cost of finding out the slow way is on the record: the
/// blood-pressure page carried an error banner and no ESH 2023 citation for a
/// whole gate run because `/api/measurements/series` — the route the chart
/// actually reads — was not served at all. That is a decode-shaped question and
/// it took three minutes of UI walking to ask.
///
/// This suite asks it in milliseconds. Every payload the overlay serves is
/// decoded through the REAL DTO the repository uses, with `JSONDecoder.hlDefault`
/// (the decoder every repository and replay path shares), and the fields the UI
/// test asserts on are checked by value — so a fixture that drifts from the
/// screenshots it is supposed to produce fails here first.
///
/// The suite reaches the same bytes the overlay serves: `CitationFixtures`
/// exposes its payloads, and ``coversEveryServedPayload`` fails if a route is
/// added to that list without a decode case below.
@Suite("Hermetic citation fixtures decode through the real DTOs")
struct HermeticCitationFixtureShapeTests {
    private static let decoder = JSONDecoder.hlDefault

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - Correlations

    @Test("correlations decode as CorrelationDiscoveryResponse, with the pair the walk photographs")
    func correlations() throws {
        let response = try Self.decode(
            CorrelationDiscoveryResponse.self,
            CitationFixtures.correlationsJSON
        )
        #expect(response.pairsTested == 31)
        #expect(response.fdrQ == 0.1)
        #expect(response.minPairs == 20)
        #expect(response.discovered.count == 2)

        // The card `05-insights-correlations-card` shows: r = 0.27, n = 140.
        let sleepPair = try #require(
            response.discovered.first { $0.behaviour == "SLEEP_DURATION" }
        )
        #expect(sleepPair.outcome == "BLOOD_PRESSURE_DIA")
        #expect(sleepPair.n == 140)
        #expect(sleepPair.r == 0.27)
        #expect(sleepPair.lagDays == 1)
        #expect(sleepPair.qValue == 0.08)
        // Below the FDR target the surface states, or the pair would not have
        // survived on a real server either.
        #expect(sleepPair.qValue <= response.fdrQ)
        #expect(sleepPair.n >= response.minPairs)
        // Server prose, rendered verbatim on the card — an empty string would
        // photograph as a card with a headline and nothing under it.
        #expect(!sleepPair.interpretation.isEmpty)
        // `BLOOD_PRESSURE_DIA` is NOT one of the curated channels, so the label
        // has to ride on the payload or the card renders a de-snaked token.
        #expect(sleepPair.outcomeLabel?.isEmpty == false)
        // Curated: the app's own localized table names it, and a server label
        // here would overrule nothing but add an English token to a German card.
        #expect(sleepPair.behaviourLabel == nil)

        let stepsPair = try #require(
            response.discovered.first { $0.behaviour == "STEPS" }
        )
        #expect(stepsPair.outcome == "RESTING_HEART_RATE")
        #expect(stepsPair.n == 126)
        #expect(stepsPair.r == -0.31)
        #expect(!stepsPair.interpretation.isEmpty)
    }

    // MARK: - Comprehensive digest

    /// `@MainActor` because the descriptor it builds is the render input of a
    /// SwiftUI `View`; the decode half needs no isolation.
    @MainActor
    @Test("comprehensive decodes as AIInsightResponse and yields a high-normal BP digest")
    func comprehensiveDigest() throws {
        let response = try Self.decode(
            AIInsightResponse.self,
            CitationFixtures.comprehensiveJSON
        )
        // `AIInsightResponse.init(from:)` parses the digest from the SAME root
        // with `try?` and collapses an empty one to nil — so a digest field that
        // fails to decode does not throw, it silently disappears, and with it the
        // whole blood-pressure status card. Assert the digest exists, not just
        // that the envelope parsed.
        let digest: ComprehensiveDigest = try #require(response.digest)
        #expect(digest.bpClassification == .highNormal)
        #expect(digest.bpPctInTarget == 46)
        #expect(digest.bpTargets?.sysLow == 120)
        #expect(digest.bpTargets?.sysHigh == 129)
        #expect(digest.bpTargets?.diaLow == 70)
        #expect(digest.bpTargets?.diaHigh == 79)

        // The card's headline is built from these two summaries; without both,
        // `InsightsMetricStatusDescriptor` renders no value.
        #expect(digest.summaries?["BLOOD_PRESSURE_SYS"]?.avg30 == 128)
        #expect(digest.summaries?["BLOOD_PRESSURE_DIA"]?.avg30 == 82)

        // The descriptor is the thing the screenshot is OF, so assert on it
        // rather than only on its inputs: `hasAnyContent` false means no card,
        // no ESH caption, and no `sources.bpClassification` to photograph.
        let descriptor = InsightsMetricStatusDescriptor.build(
            kind: .bloodPressure,
            digest: digest,
            target: nil,
            latestValue: nil
        )
        #expect(descriptor.hasAnyContent)
        #expect(descriptor.sourcesTopic == .bloodPressureClassification)
        #expect(descriptor.guidelineCaption?.isEmpty == false)
        #expect(descriptor.headlineValue == "128/82")
    }

    @Test("the AI provider config opens the consent gate the digest load sits behind")
    func aiProviderConfig() throws {
        let config = try Self.decode(AIProviderConfig.self, CitationFixtures.aiProviderJSON)
        // Not cosmetic: `InsightsStore.load()` is gated on
        // `AppContainer.makeAIConsentGate()`, which refuses outright when the
        // provider config is nil or reports no server AI — and then the digest
        // above is never fetched at all.
        #expect(config.aiAvailable == true)
        #expect(config.isServerAIAvailable)
        #expect(config.aiConsentTarget != .unavailable)
    }

    // MARK: - Blood-pressure series + list

    @Test("the BP series decodes as MeasurementSeries with paired systolic/diastolic points")
    func bloodPressureSeries() throws {
        let series = try Self.decode(MeasurementSeries.self, CitationFixtures.seriesJSON)
        #expect(series.kind == .bloodPressure)
        #expect(series.unit == "mmHg")
        #expect(series.points.count == 30)
        #expect(series.stats.count == 30)
        // Every point carries the diastolic half. A BP point without
        // `secondary` charts as "128/0" — the exact defect the BP-PAIR fix
        // exists for.
        #expect(series.points.allSatisfy { $0.secondary != nil })
        let latest = try #require(series.points.last)
        #expect(latest.value == 128)
        #expect(latest.secondary == 82)
    }

    @Test("the measurements list decodes as MeasurementListWireResponse, both BP halves")
    func measurementsList() throws {
        let list = try Self.decode(
            MeasurementListWireResponse.self,
            CitationFixtures.measurementsJSON
        )
        // 30 days × systolic + diastolic. The list decoder is element-wise
        // TOLERANT — a row it cannot read is dropped silently rather than
        // failing — so a count check is the only thing that catches a bad row.
        #expect(list.measurements.count == 60)
        #expect(list.measurements.filter { $0.type == .bloodPressureSystolic }.count == 30)
        #expect(list.measurements.filter { $0.type == .bloodPressureDiastolic }.count == 30)
        #expect(list.measurements.allSatisfy { $0.unit == "mmHg" })
    }

    // MARK: - Labs

    @Test("the hs-CRP biomarker and its result decode, at 2.1 mg/L against 0–3")
    func labs() throws {
        let catalogue = try Self.decode(
            ListBiomarkersResponse.self,
            CitationFixtures.biomarkersJSON
        )
        let marker = try #require(catalogue.biomarkers.first)
        #expect(marker.name == "hs-CRP")
        #expect(marker.unit == "mg/L")
        #expect(marker.lowerBound == 0)
        #expect(marker.upperBound == 3)

        let results = try Self.decode(ListLabResultsResponse.self, CitationFixtures.labsJSON)
        let result = try #require(results.results.first)
        #expect(result.analyte == "hs-CRP")
        #expect(result.value == 2.1)
        #expect(result.unit == "mg/L")
        #expect(result.referenceLow == 0)
        #expect(result.referenceHigh == 3)
        #expect(result.rangeStatus == .inRange)
        // Linked to the catalogue row, or the detail page resolves its range
        // from the reading alone and the editor stops being read-only.
        #expect(result.biomarkerId == marker.id)

        // The citation control lives INSIDE the explainer slot, so a name the
        // explainer catalogue cannot resolve renders no `sources.lab.hs-crp`
        // at all — which is the whole point of shot 09.
        #expect(BiomarkerExplainer.slug(forName: marker.name) == "hs-crp")
        #expect(BiomarkerExplainer.text(context: marker.context, name: marker.name) != nil)
    }

    // MARK: - Mental health

    @Test("the PHQ-9 submit response decodes as a mild result of 7, with no crisis set")
    func mentalHealthAssessment() throws {
        let response = try Self.decode(
            CreateAssessmentResponse.self,
            CitationFixtures.createAssessmentJSON
        )
        #expect(response.assessment.instrument == .phq9)
        #expect(response.assessment.totalScore == 7)
        #expect(response.assessment.severityBand == "mild")
        #expect(response.actionThreshold == 10)
        // Item 9 clear and no crisis set: the evidence shot must not carry a
        // crisis card, which would say something about the walk that is not true.
        #expect(response.assessment.item9Flagged == false)
        #expect(response.crisis == nil)
        // Below the server's own threshold, so the "consider a professional"
        // nudge stays down — the screenshot is about the disclaimer.
        #expect(
            response.assessment.instrument.needsFollowUp(
                forTotal: response.assessment.totalScore,
                threshold: response.actionThreshold
            ) == false
        )
    }

    // MARK: - Coverage

    @Test("every served payload is valid JSON and has a decode case above")
    func coversEveryServedPayload() throws {
        let served = CitationFixtures.servedPayloads
        // A floor, so a refactor that empties the list cannot pass by checking
        // nothing — the failure mode this repository has met five times.
        #expect(served.count == 8)
        for (route, json) in served {
            #expect(!json.isEmpty, "\(route) serves an empty body")
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
            #expect(object is [String: Any], "\(route) does not serve a JSON object")
        }
        let covered = Set([
            "/api/insights/correlations",
            "/api/insights/comprehensive",
            "/api/user/ai-provider",
            "/api/measurements",
            "/api/measurements/series",
            "/api/labs",
            "/api/biomarkers",
            "/api/mental-health/assessments"
        ])
        #expect(
            Set(served.map(\.route)) == covered,
            "a route was added to CitationFixtures without a decode case in this suite"
        )
    }
}
