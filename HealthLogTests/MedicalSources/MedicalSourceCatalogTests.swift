// HealthLogTests/MedicalSources/MedicalSourceCatalogTests.swift
import Foundation
@testable import HealthLog
import Testing

@Suite("MedicalSourceCatalog — registry contract")
struct MedicalSourceCatalogTests {
    @Test("every id resolves to exactly one https source")
    func everyIDResolves() {
        for id in MedicalSourceID.allCases {
            let s = MedicalSourceCatalog.source(id)
            #expect(s.id == id)
            #expect(s.url.scheme == "https", "\(id.rawValue) must be https")
            #expect(!s.name.isEmpty)
            #expect(s.year >= 1980 && s.year <= 2026)
        }
        #expect(Set(MedicalSourceCatalog.all.map(\.id)).count == MedicalSourceID.allCases.count)
    }

    @Test("server-mirrored ids are present verbatim")
    func serverIDsMirrored() {
        let server: Set = [
            "esh-2023-hypertension", "steps-saint-maurice-2020", "who-2020-physical-activity",
            "bts-2017-emergency-oxygen", "nice-ng115-copd", "ada-2024-glycemic", "ispad-2022-pediatric",
            "ace-body-fat-standards", "aasm-2015-adult-sleep", "watson-1980-tbw", "icrp-89-reference-man",
            "aha-2024-rhr", "statpearls-pulse-ox", "acc-aha-2017-bp", "esc-2024-bp",
            "statpearls-pulse-pressure", "statpearls-map", "esc-esh-2018-pwv", "fda-2024-pulse-ox",
            "jgim-2019-temperature", "rcp-2017-news2", "ala-respiratory-rate", "vat-imaging-threshold",
            "wilcox-2000-fertile-window", "acog-co651-2015", "phillips-2017-sri", "cdc-2024-sleep",
            "who-2000-bmi", "who-idf-2006-glucose", "esc-naspe-1996-hrv"
        ]
        let ios = Set(MedicalSourceID.allCases.map(\.rawValue))
        #expect(server.isSubset(of: ios), "missing: \(server.subtracting(ios))")
    }

    @Test("every surfaced topic has sources or a methodology text")
    func everyTopicIsNonEmpty() {
        for topic in MedicalSourceTopic.allSurfacedForTest {
            let hasSources = !MedicalSourceCatalog.sources(for: topic).isEmpty
            let hasMethod = MedicalSourceCatalog.methodologyKey(for: topic) != nil
            #expect(hasSources || hasMethod, "topic \(topic) resolves to nothing")
        }
    }

    @Test("caveat and methodology keys exist in the catalog (do not resolve to themselves)")
    func keysAreLocalized() {
        for s in MedicalSourceCatalog.all {
            let resolved = String(localized: String.LocalizationValue(s.caveatKey))
            #expect(resolved != s.caveatKey, "missing caveat string \(s.caveatKey)")
        }
        for topic in MedicalSourceTopic.allSurfacedForTest {
            if let key = MedicalSourceCatalog.methodologyKey(for: topic) {
                let resolved = String(localized: String.LocalizationValue(key))
                #expect(resolved != key, "missing methodology string \(key)")
            }
        }
    }

    @Test("metric mapping covers the metrics that render an explainer")
    func metricMappingCoversExplainedKinds() {
        let must: [MetricKind] = [
            .restingHeartRate, .hrv, .bloodPressure, .spo2, .respiratoryRate, .bodyTemperature,
            .glucose, .vo2Max, .weight, .bmi, .bodyFat, .steps, .sleep, .pulse,
            // BF4 / audit row 17 — kinds that used to fall through `default: []`.
            .boneMass, .timeInDaylight, .mood
        ]
        for kind in must {
            #expect(!MedicalSourceCatalog.sources(forMetric: kind).isEmpty, "\(kind.rawValue) has no sources")
        }
    }

    /// BF4 / audit row 17 — the kinds that stay empty do so on purpose. Locked
    /// so a later "fill every case" sweep has to argue with a test: the six
    /// device-event kinds cite the device that produced the alert, and the
    /// other two make no external clinical claim.
    @Test("the deliberately uncited metric kinds stay uncited")
    func deliberatelyEmptyMetricKinds() {
        let empty: [MetricKind] = [
            .painNRS, .unknown,
            .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
            .walkingSteadinessEvent, .breathingDisturbanceEvent, .audioExposureEvent
        ]
        for kind in empty {
            #expect(
                MedicalSourceCatalog.sources(forMetric: kind).isEmpty,
                "\(kind.rawValue) gained sources — decide whether that is intended and update the comment"
            )
        }
    }

    /// R25 / I2 — `sources.method.metricExplainer` promises "the references
    /// below", so `methodologyKey(for:)` must withhold it for exactly the eight
    /// kinds that resolve to no references. Without this the Sources sheet
    /// opened on those kinds shows a promise and an empty page.
    @Test("the eight uncited metric kinds resolve to no methodology key either")
    func uncitedMetricKindsHaveNoMethodology() {
        let empty: [MetricKind] = [
            .painNRS, .unknown,
            .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
            .walkingSteadinessEvent, .breathingDisturbanceEvent, .audioExposureEvent
        ]
        for kind in empty {
            #expect(
                MedicalSourceCatalog.methodologyKey(for: .metric(kind)) == nil,
                "\(kind.rawValue) would open a sheet promising references it has none of"
            )
            #expect(!HLSourcesLink.isRenderable(.metric(kind)), "\(kind.rawValue) would render a dead Sources control")
        }
        #expect(MedicalSourceCatalog.methodologyKey(for: .metric(.bloodPressure)) == "sources.method.metricExplainer")
    }

    /// A4.4 — the GLP-1 topics carry no static ids; everything the sheet shows
    /// for them comes from `dynamicSources(for:)`. Asserted here because the
    /// surfaces (`MDRGatedDrugLevelSection`, `TitrationLadderSection`) pass a
    /// `DrugID` straight through and a silent empty list would read as "no
    /// citation" rather than as a failure.
    @Test("every GLP-1 drug resolves to an EMA EPAR source on both dynamic topics")
    func glp1DynamicSourcesCoverEveryDrug() {
        for id in GLP1DrugCatalog.allDrugIDs {
            for topic in [MedicalSourceTopic.glp1Pharmacokinetics(id), .titration(id)] {
                let dynamic = MedicalSourceCatalog.dynamicSources(for: topic)
                #expect(
                    dynamic.contains { $0.url.host()?.contains("ema.europa.eu") == true },
                    "\(topic) has no ema.europa.eu source"
                )
                #expect(dynamic.allSatisfy { $0.url.scheme == "https" && !$0.name.isEmpty })
                #expect(HLSourcesLink.isRenderable(topic), "\(topic) would render no Sources button")
            }
        }
    }

    @Test("tirzepatide additionally cites the Schneck & Urva DOI")
    func tirzepatideCitesJournalDOI() {
        let dynamic = MedicalSourceCatalog.dynamicSources(for: .glp1Pharmacokinetics(.tirzepatide))
        #expect(
            dynamic.contains { $0.url.host()?.contains("doi.org") == true },
            "tirzepatide PK sources carry no doi.org entry"
        )
    }

    /// **1.0.3 (App Review 1.4.1, audit row 6).** `.aiAssistant` shipped with an
    /// empty reference list while its own methodology text told the reader the
    /// answers rest on published references — the sheet Apple was pointed at
    /// listed nothing. `everyTopicIsNonEmpty` above could not catch it: a
    /// methodology text alone satisfied it. This asserts the references.
    @Test("the assistant topic cites real references and offers the hub")
    func aiAssistantCitesSources() {
        let sources = MedicalSourceCatalog.sources(for: .aiAssistant)
        #expect(!sources.isEmpty, "the .aiAssistant sheet must list references")
        #expect(sources.allSatisfy { $0.url.scheme == "https" })
        let ids = Set(MedicalSourceCatalog.ids(for: .aiAssistant))
        #expect(ids.contains(.esh2023Hypertension))
        #expect(ids.contains(.ada2024Glycemic))
        #expect(ids.contains(.who2020PhysicalActivity))
        #expect(ids.contains(.aasm2015AdultSleep))
        #expect(ids.contains(.who2011Waist))
        #expect(ids.contains(.escEas2019Dyslipidaemia))
        // The hub row is the assistant's alone: it is the only surface that can
        // speak about any metric, so its own six are a floor, not the basis.
        #expect(MedicalSourceTopic.aiAssistant.showsHubLink)
        #expect(!MedicalSourceTopic.healthScore.showsHubLink)
        #expect(!MedicalSourceTopic.metric(.bloodPressure).showsHubLink)
    }

    /// The methodology sentence and the reference list have to agree. It used to
    /// say the answers were grounded in "the reference ranges on this page" —
    /// a page that then showed none.
    @Test("the assistant methodology text points at the references it now has")
    func aiAssistantMethodologyMatchesTheSheet() throws {
        let key = try #require(MedicalSourceCatalog.methodologyKey(for: .aiAssistant))
        let resolved = String(localized: String.LocalizationValue(key))
        #expect(resolved != key)
        #expect(!resolved.localizedCaseInsensitiveContains("reference ranges on this page"))
        #expect(!resolved.contains("Referenzbereiche dieser Seite"))
    }

    @Test("accessibility suffix is stable and identifier-safe")
    func accessibilitySuffix() {
        #expect(MedicalSourceTopic.correlations.accessibilitySuffix == "correlations")
        #expect(MedicalSourceTopic.metric(.bloodPressure).accessibilitySuffix == "metric.bloodPressure")
        #expect(MedicalSourceTopic.labBiomarker("hs-crp").accessibilitySuffix == "lab.hs-crp")
        #expect(MedicalSourceTopic.derivedScore("READINESS").accessibilitySuffix == "derived.READINESS")
    }
}
