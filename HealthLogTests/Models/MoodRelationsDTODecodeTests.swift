// swiftlint:disable force_try

import Foundation
@testable import HealthLog
import Testing

/// v0.14.1 — decode + behaviour locks for the LIVE mood-"relations" slices
/// (`GET /api/mood/insights`, server v1.11.5). Validates the tolerant
/// `MoodRelationsResponse` against a realistic full `MoodAggregates` payload
/// (the route serialises the whole aggregate; iOS reads only `tagInfluence` +
/// `betterDays`), the confidence-gate empty state, and the store ranking.
@Suite("MoodRelations DTO + store")
struct MoodRelationsDTODecodeTests {
    private func decode(_ json: String) throws -> MoodRelationsResponse {
        try JSONDecoder.hlDefault.decode(MoodRelationsResponse.self, from: Data(json.utf8))
    }

    /// A realistic v1.11.5 `/api/mood/insights` payload — the FULL aggregate the
    /// route returns, including the many keys iOS computes client-side
    /// (`summary`, `heatmap`, `distribution`, `weekday`, `narratives`,
    /// `correlations`, …). The DTO must read ONLY the two relations slices and
    /// ignore the rest (tolerant + additive).
    private static let realisticPayload = #"""
    {
      "summary": {"points": 42, "mean": 3.6, "min": 1, "max": 5, "latest": 4,
                  "delta": 0.5, "inTargetPct": 61.2, "totalEntries": 58,
                  "totalSpanDays": 96, "newestEntryDaysAgo": 0},
      "heatmap": {"windowDays": 90, "cells": [{"date": "2026-06-01", "score": 4.0, "samples": 1}]},
      "distribution": [{"score": 1, "count": 2}, {"score": 5, "count": 9}],
      "weekday": [{"weekday": 0, "avgScore": 3.8, "count": 12}],
      "timeOfDay": {"reliable": true, "buckets": []},
      "stability": {"score": 72, "band": "steady"},
      "tags": [{"tag": "work", "count": 14, "avgScore": 3.1}],
      "structuredTags": [{"key": "worked_out", "categoryKey": "health",
                          "labelKey": "mood.tag.workedOut", "icon": "Dumbbell",
                          "count": 11, "avgScore": 4.2}],
      "tagInfluence": {
        "flat": [
          {"tag": "deadline", "labelKey": null, "categoryKey": null, "icon": null,
           "withDays": 6, "withoutDays": 40, "withAvg": 2.6, "withoutAvg": 3.7,
           "delta": -1.1, "pValue": 0.03, "confidence": "medium"}
        ],
        "structured": [
          {"tag": "worked_out", "labelKey": "mood.tag.workedOut", "categoryKey": "health",
           "icon": "Dumbbell", "withDays": 14, "withoutDays": 32, "withAvg": 4.5,
           "withoutAvg": 2.5, "delta": 2.0, "pValue": 0.001, "confidence": "high"},
          {"tag": "alcohol", "labelKey": "mood.tag.alcohol", "categoryKey": "health",
           "icon": "Wine", "withDays": 8, "withoutDays": 30, "withAvg": 2.9,
           "withoutAvg": 3.7, "delta": -0.8, "pValue": 0.04, "confidence": "low"}
        ]
      },
      "betterDays": [
        {"source": "tag", "key": "worked_out", "labelKey": "mood.tag.workedOut",
         "categoryKey": "health", "icon": "Dumbbell", "direction": "up", "n": 14,
         "confidence": "high", "delta": 2.0, "r": null},
        {"source": "metric", "key": "sleep", "labelKey": null, "categoryKey": null,
         "icon": null, "direction": "up", "n": 41, "confidence": "medium",
         "delta": null, "r": 0.34},
        {"source": "tag", "key": "alcohol", "labelKey": "mood.tag.alcohol",
         "categoryKey": "health", "icon": "Wine", "direction": "down", "n": 8,
         "confidence": "low", "delta": -0.8, "r": null}
      ],
      "factorCrosstab": [
        {"factor": "factor_work", "labelKey": "mood.tag.factorWork", "categoryKey": "factors",
         "icon": "Briefcase", "inverse": false, "metricKey": "sleepDuration", "display": "hours",
         "mode": "sameDay", "lowDays": 9, "highDays": 12, "lowAvg": 6.2, "highAvg": 7.4,
         "delta": -1.2, "pValue": 0.02, "qValue": 0.04, "confidence": "medium"},
        {"factor": "factor_sadness", "labelKey": "mood.tag.factorSadness", "categoryKey": "factors",
         "icon": "CloudRain", "inverse": true, "metricKey": "restingHeartRate", "display": "bpm",
         "mode": "nextDay", "lowDays": 7, "highDays": 10, "lowAvg": 64.0, "highAvg": 61.5,
         "delta": 2.5, "pValue": 0.01, "qValue": 0.02, "confidence": "high"}
      ],
      "narratives": [{"id": "x", "kind": "weekday", "text": "…", "priority": 1}],
      "correlations": {
        "sleep": {"result": {"r": 0.34, "strength": "moderat"}, "points": [], "n": 41}
      }
    }
    """#

    // MARK: - Tolerant decode against the full aggregate

    @Test("Decodes tagInfluence + betterDays from the full v1.11.5 aggregate, ignoring the rest")
    func decodesRelationsSlices() throws {
        let res = try decode(Self.realisticPayload)

        // tagInfluence: both axes populated with the exact server field names.
        #expect(res.tagInfluence.structured.count == 2)
        #expect(res.tagInfluence.flat.count == 1)

        let workedOut = try #require(res.tagInfluence.structured.first { $0.tag == "worked_out" })
        #expect(workedOut.labelKey == "mood.tag.workedOut")
        #expect(workedOut.categoryKey == "health")
        #expect(workedOut.icon == "Dumbbell")
        #expect(workedOut.withDays == 14)
        #expect(workedOut.withoutDays == 32)
        #expect(workedOut.withAvg == 4.5)
        #expect(workedOut.withoutAvg == 2.5)
        #expect(workedOut.delta == 2.0)
        #expect(workedOut.pValue == 0.001)
        #expect(workedOut.confidence == .high)
        #expect(workedOut.isPositive)
        #expect(workedOut.minGroupDays == 14)

        // flat row: labelKey/categoryKey/icon are null, tag is the free text.
        let deadline = try #require(res.tagInfluence.flat.first)
        #expect(deadline.tag == "deadline")
        #expect(deadline.labelKey == nil)
        #expect(deadline.delta == -1.1)
        #expect(!deadline.isPositive)
        #expect(deadline.confidence == .medium)

        // betterDays: tag + metric factors decode with the right nullable arms.
        #expect(res.betterDays.count == 3)
        let metric = try #require(res.betterDays.first { $0.source == .metric })
        #expect(metric.key == "sleep")
        #expect(metric.r == 0.34)
        #expect(metric.delta == nil)
        #expect(metric.direction == .up)
        #expect(metric.n == 41)

        let tagFactor = try #require(res.betterDays.first { $0.source == .tag && $0.key == "worked_out" })
        #expect(tagFactor.delta == 2.0)
        #expect(tagFactor.r == nil)
        #expect(tagFactor.isPositive)
    }

    @Test("Decodes factorCrosstab (rated-factor × metric) from the v1.14.0 aggregate")
    func decodesFactorCrosstab() throws {
        let res = try decode(Self.realisticPayload)
        #expect(res.factorCrosstab.count == 2)

        let work = try #require(res.factorCrosstab.first { $0.factor == "factor_work" })
        #expect(work.labelKey == "mood.tag.factorWork")
        #expect(work.categoryKey == "factors")
        #expect(work.icon == "Briefcase")
        #expect(!work.inverse)
        #expect(work.metricKey == "sleepDuration")
        #expect(work.display == "hours")
        #expect(work.mode == "sameDay")
        #expect(work.lowDays == 9)
        #expect(work.highDays == 12)
        #expect(work.lowAvg == 6.2)
        #expect(work.highAvg == 7.4)
        #expect(work.delta == -1.2)
        #expect(work.pValue == 0.02)
        #expect(work.qValue == 0.04)
        #expect(work.confidence == .medium)
        #expect(work.minGroupDays == 9)

        let sadness = try #require(res.factorCrosstab.first { $0.factor == "factor_sadness" })
        #expect(sadness.inverse)
        #expect(sadness.metricKey == "restingHeartRate")
        #expect(sadness.confidence == .high)
    }

    @Test("A pre-v1.14.0 payload (no factorCrosstab) decodes to empty crosstab")
    func missingFactorCrosstabDecodesEmpty() throws {
        let json = #"""
        {"tagInfluence": {"flat": [], "structured": []}, "betterDays": []}
        """#
        let res = try decode(json)
        #expect(res.factorCrosstab.isEmpty)
    }

    @MainActor
    @Test("Store sorts factorCrosstab by adjusted q-value (most significant first)")
    func storeSortsCrosstab() async throws {
        let payload = try decode(Self.realisticPayload)
        let repo = MoodRelationsRepository(api: StubAPIClient(payload: payload))
        let store = MoodRelationsStore(repo: repo)
        await store.load()
        // sadness q=0.02 before work q=0.04.
        #expect(store.factorCrosstab.map(\.factor) == ["factor_sadness", "factor_work"])
        #expect(store.hasFactorCrosstab)
        #expect(store.hasContent)
    }

    @Test("Unknown confidence band degrades to .low rather than throwing")
    func tolerantConfidence() throws {
        let json = #"""
        {"tagInfluence": {"flat": [
          {"tag": "x", "withDays": 6, "withoutDays": 7, "withAvg": 3, "withoutAvg": 3.5,
           "delta": -0.5, "pValue": 0.2, "confidence": "experimental"}
        ], "structured": []}, "betterDays": []}
        """#
        let res = try decode(json)
        #expect(res.tagInfluence.flat.first?.confidence == .low)
    }

    @Test("Unknown better-day source/direction degrade rather than throw")
    func tolerantSourceDirection() throws {
        let json = #"""
        {"tagInfluence": {"flat": [], "structured": []}, "betterDays": [
          {"source": "future", "key": "z", "direction": "sideways", "n": 9, "confidence": "low"}
        ]}
        """#
        let res = try decode(json)
        let factor = try #require(res.betterDays.first)
        #expect(factor.source == .tag) // unknown → conservative default
        #expect(factor.direction == .up)
    }

    // MARK: - Additive: a payload missing the relations slices decodes empty

    @Test("A pre-v1.11.5 payload (no relations keys) decodes to empty, never throws")
    func missingSlicesDecodeEmpty() throws {
        let json = #"""
        {"summary": {"points": 0}, "heatmap": {"windowDays": 30, "cells": []},
         "distribution": [], "weekday": [], "tags": [], "structuredTags": []}
        """#
        let res = try decode(json)
        #expect(res.tagInfluence.isEmpty)
        #expect(res.betterDays.isEmpty)
        #expect(res.isEmpty)
    }

    // MARK: - Store ranking + confidence-gate empty state

    /// Minimal stub returning a fixed payload for the relations GET.
    private final class StubAPIClient: APIClientProtocol, @unchecked Sendable {
        let payload: MoodRelationsResponse
        init(payload: MoodRelationsResponse) {
            self.payload = payload
        }

        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            guard let typed = payload as? T else { throw HLError.decoding("type mismatch") }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

    @MainActor
    @Test("Store ranks structured influence by |delta| desc and preserves server better-days order")
    func storeRanking() async throws {
        let payload = try decode(Self.realisticPayload)
        let repo = MoodRelationsRepository(api: StubAPIClient(payload: payload))
        let store = MoodRelationsStore(repo: repo)
        await store.load()

        // Structured influence sorted by |delta| desc: worked_out (2.0) before alcohol (0.8).
        #expect(store.structuredInfluence.map(\.tag) == ["worked_out", "alcohol"])
        // Better-days board preserves the server's cross-source ranking exactly.
        #expect(store.betterDays.map(\.key) == ["worked_out", "sleep", "alcohol"])
        #expect(store.hasContent)
        #expect(store.hasInfluence)
        #expect(store.hasBetterDays)
        #expect(store.hasSettledOnce)
    }

    @MainActor
    @Test("Confidence-gate: an empty (below-floor) payload settles with no content")
    func confidenceGateEmptyState() async {
        let empty = MoodRelationsResponse(tagInfluence: .empty, betterDays: [])
        let repo = MoodRelationsRepository(api: StubAPIClient(payload: empty))
        let store = MoodRelationsStore(repo: repo)

        // Before load: nothing settled, nothing shown (no fabricated correlation).
        #expect(!store.hasContent)
        #expect(!store.hasSettledOnce)

        await store.load()

        // After load: settled, still empty — the host shows the calm empty state.
        #expect(store.hasSettledOnce)
        #expect(!store.hasContent)
        #expect(!store.hasInfluence)
        #expect(!store.hasBetterDays)
    }
}
