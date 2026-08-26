import Foundation
@testable import HealthLog
import Testing

/// **v1.27.5 — RECOVERY_SCORE readiness-blend `components[]` breakdown.**
///
/// The server now ships an optional `components[]` on the RECOVERY_SCORE value
/// (the COMPUTED proxy IS the persisted readiness blend). When present iOS
/// renders the SAME factor-breakdown UI as READINESS / SLEEP_SCORE; when absent
/// (a watch-native recovery, no sub-scores) it stays provenance-only. This locks
/// both the decode and the DTO-aware archetype promotion.
@Suite("RECOVERY_SCORE components")
struct WellnessScoreRecoveryComponentsTests {
    private let decoder = JSONDecoder.hlDefault

    private func recovery(components: String?) throws -> DerivedMetricDTO {
        let comp = components.map { ",\"components\":\($0)" } ?? ""
        let json = Data(#"""
        {"metric":"RECOVERY_SCORE","status":"ok",
         "value":{"score":64,"band":"yellow"\#(comp)},
         "coverage":{"requiredInputs":5,"presentInputs":4,"historyDays":14,"missing":[]},
         "confidence":{"score":80,"band":"high"},
         "provenance":{"inputs":["RESTING_HEART_RATE","HEART_RATE_VARIABILITY"],
                       "source":"DAY","windowDays":14,"computedAt":"2026-07-08T06:00:00Z"},
         "reason":null}
        """#.utf8)
        return try decoder.decode(DerivedMetricDTO.self, from: json)
    }

    @Test("components decode into the unified contributor list")
    func componentsDecode() throws {
        let dto = try recovery(components: #"""
        [{"key":"rhr","value":80,"weight":0.3},
         {"key":"hrv","value":55,"weight":0.45},
         {"key":"sleep","value":70,"weight":0.25}]
        """#)
        // The `contributors` accessor unifies `components` (READINESS blend keys).
        #expect(dto.value?.contributors?.count == 3)
        let ranked = WellnessScorePresentation.rankedContributors(dto)
        #expect(ranked.count == 3)
        // Present-first, then descending weight (hrv 0.45 leads).
        #expect(ranked.first?.key == "hrv")
        // The blend keys reuse the readiness labels + deep-nav.
        #expect(ranked.first?.deepNavKind == .hrv)
    }

    @Test("with components → the score promotes to the factor-breakdown archetype")
    func promotesToBreakdown() throws {
        let dto = try recovery(components: #"[{"key":"rhr","value":80,"weight":1.0}]"#)
        #expect(WellnessScorePresentation.archetype(for: dto) == .scoreWithBreakdown)
    }

    @Test("without components (watch-native) → stays provenance-only")
    func hidesWhenAbsent() throws {
        let dto = try recovery(components: nil)
        #expect(dto.value?.contributors == nil)
        #expect(WellnessScorePresentation.rankedContributors(dto).isEmpty)
        #expect(WellnessScorePresentation.archetype(for: dto) == .scoreProvenanceOnly)
    }

    @Test("empty components array → no breakdown, provenance-only")
    func emptyComponentsHide() throws {
        let dto = try recovery(components: "[]")
        #expect(WellnessScorePresentation.rankedContributors(dto).isEmpty)
        #expect(WellnessScorePresentation.archetype(for: dto) == .scoreProvenanceOnly)
    }

    @Test("READINESS / SLEEP still break down; STRAIN still provenance-only")
    func otherArchetypesUnchanged() throws {
        for metric in ["READINESS", "SLEEP_SCORE"] {
            let json = Data(#"""
            {"metric":"\#(metric)","status":"ok",
             "value":{"score":72,"band":"green","components":[{"key":"hrv","value":60,"weight":1}]},
             "coverage":{"requiredInputs":1,"presentInputs":1,"historyDays":10,"missing":[]},
             "confidence":{"score":80,"band":"high"},
             "provenance":{"inputs":["X"],"source":"DAY","windowDays":14,"computedAt":"2026-07-08T06:00:00Z"},
             "reason":null}
            """#.utf8)
            let dto = try decoder.decode(DerivedMetricDTO.self, from: json)
            #expect(WellnessScorePresentation.archetype(for: dto) == .scoreWithBreakdown)
        }
        let strain = Data(#"""
        {"metric":"STRAIN_SCORE","status":"ok","value":{"score":40,"band":"yellow"},
         "coverage":{"requiredInputs":1,"presentInputs":1,"historyDays":10,"missing":[]},
         "confidence":{"score":80,"band":"high"},
         "provenance":{"inputs":["X"],"source":"DAY","windowDays":14,"computedAt":"2026-07-08T06:00:00Z"},
         "reason":null}
        """#.utf8)
        let strainDTO = try decoder.decode(DerivedMetricDTO.self, from: strain)
        #expect(WellnessScorePresentation.archetype(for: strainDTO) == .scoreProvenanceOnly)
    }
}
