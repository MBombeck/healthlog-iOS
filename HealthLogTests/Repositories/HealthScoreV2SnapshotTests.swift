import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **CU-31 — the Health Score v2 wire, end to end through the real `APIClient`.**
///
/// Two things are pinned here.
///
/// 1. **Source.** Server v1.34.0 replaced the score engine: the flat, client-
///    shaped `{ score, band, delta, … }` DTO now rides `GET /api/dashboard/snapshot`,
///    while `/api/analytics.healthScore` became the server's internal
///    `HealthScoreReport` (`{ composite, pillars, weightGoal, … }` — no
///    top-level `score`). The repository must read the snapshot.
/// 2. **Ring semantics (GH #42).** `MED_COMPLIANCE` carries today's dose
///    progress plus the `{ taken, scheduled }` tally, its band is green or
///    yellow but never red, and a day with nothing scheduled produces NO ring
///    at all. Every number is rendered as the server sent it — the client
///    derives none of them.
///
/// Real `APIClient` + `MockURLProtocol` (never a mock server), `.serialized`
/// because the protocol handler is global.
@Suite("Health Score v2 — snapshot wire", .serialized)
struct HealthScoreV2SnapshotTests {
    // MARK: - Harness

    private func makeAPIClient() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.17.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// A live-shaped snapshot envelope: the v2 score with all eleven keys plus
    /// the three resolvable hero rings.
    private static let fullSnapshotJSON = #"""
    {
      "data": {
        "briefingState": "ready",
        "briefingStale": false,
        "healthScore": {
          "score": 71,
          "band": "yellow",
          "delta": null,
          "confidence": { "score": 82, "band": "medium" },
          "composition": ["BLOOD_PRESSURE","ACTIVITY","SLEEP","WELLBEING"],
          "deltaReason": "algorithm_changed",
          "scoreVersion": 2,
          "bandSetter": "SLEEP",
          "restMode": { "active": true, "since": "2026-07-24T06:00:00.000Z", "episodeCount": 2 },
          "tension": { "band": "yellow", "positive": ["hrv"], "negative": ["rhr"] },
          "returnToBand": { "metricType": "RESTING_HEART_RATE", "daysInside": 3 }
        },
        "scoreRings": [
          { "id": "READINESS", "score": 63, "band": "yellow" },
          { "id": "MED_COMPLIANCE", "score": 42, "band": "yellow", "doses": { "taken": 1, "scheduled": 3 } }
        ]
      }
    }
    """#

    /// The minimal envelope an older / colder server can produce: the three
    /// contractual score fields and nothing else.
    private static let minimalSnapshotJSON = #"""
    { "data": { "healthScore": { "score": 58, "band": "yellow", "delta": 3 } } }
    """#

    // MARK: - Source

    @Test("the score is read off GET /api/dashboard/snapshot")
    func readsFromSnapshotRoute() async throws {
        let api = makeAPIClient()
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { request in
            capturedPath = request.url?.path
            return (Self.ok(request), Data(Self.fullSnapshotJSON.utf8))
        }

        let score = try await AnalyticsRepository(api: api).healthScore()

        #expect(capturedPath == "/api/dashboard/snapshot")
        #expect(score.score == 71)
        #expect(score.deltaReason == .algorithmChanged)
        #expect(score.bandSetter == .sleep)
        #expect(score.confidence?.band == .medium)
        #expect(score.composition == [.bloodPressure, .activity, .sleep, .wellbeing])
    }

    @Test("the minimal envelope decodes with the three contractual fields only")
    func minimalEnvelopeDecodes() async throws {
        let api = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Data(Self.minimalSnapshotJSON.utf8))
        }

        let score = try await AnalyticsRepository(api: api).healthScore()
        #expect(score.score == 58)
        #expect(score.delta == 3)
        #expect(score.confidence == nil)
        #expect(score.composition == nil)
        #expect(score.deltaReason == nil)
    }

    /// `healthScore: null` (cold rollup coverage) is an honest "not yet" — a
    /// named empty state, never a zero score painted on the tile.
    @Test("a null healthScore surfaces the honest empty state, not a zero")
    func nullScoreIsAnEmptyState() async {
        let api = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Data(#"{"data":{"healthScore":null,"briefingState":"ready"}}"#.utf8))
        }

        await #expect(throws: HLError.self) {
            _ = try await AnalyticsRepository(api: api).healthScore()
        }
    }

    /// The score must never take the snapshot down with it: a shape this
    /// client cannot read degrades to `nil` while the rest of the slot decodes.
    @Test("an unreadable healthScore degrades to nil without failing the snapshot")
    func malformedScoreDoesNotPoisonTheSnapshot() throws {
        let json = Data(#"""
        {
          "briefingState": "ready",
          "healthScore": { "band": "green" },
          "scoreRings": [{ "id": "READINESS", "score": 70, "band": "green" }]
        }
        """#.utf8)
        let slot = try JSONDecoder.hlDefault.decode(DashboardSnapshotBriefing.self, from: json)
        // `score` is required — the object is unreadable, so it drops.
        #expect(slot.healthScore == nil)
        // …and everything else on the slot survives.
        #expect(slot.scoreRings.map(\.id) == [.readiness])
        #expect(slot.briefingState == .ready)
    }

    // MARK: - Ring semantics (GH #42) — no client recompute

    /// The proof that nothing is recomputed on device: the fixture's dose tally
    /// (1 of 3 ≈ 33 %) deliberately disagrees with the server's `score` of 42.
    /// The client must paint 42 — the server's number — and show "1/3" as the
    /// label. Any client-side `taken / scheduled` arithmetic would produce 33.
    @Test("MED_COMPLIANCE renders the server score, never a recomputed dose ratio")
    func medComplianceIsNeverRecomputed() async throws {
        let api = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Data(Self.fullSnapshotJSON.utf8))
        }

        let slot = try #require(await DashboardRepository(api: api).snapshotBriefing())
        let meds = try #require(slot.scoreRings.first { $0.id == .medCompliance })

        #expect(meds.score == 42)
        #expect(meds.doses == DashboardScoreRing.Doses(taken: 1, scheduled: 3))
        // The label is the tally; the arc is the server score.
        #expect(meds.dosesCaption == "1/3")
        #expect(abs(meds.fraction - 0.42) < 0.0001)
        // Not the ratio a client-side recompute would have produced.
        #expect(meds.score != Int((1.0 / 3.0 * 100).rounded()))
    }

    /// Nothing scheduled today → the server omits the ring entirely. Absence is
    /// "no doses planned", which is not the same statement as 0 % adherence, so
    /// the client must not synthesise a zero ring.
    @Test("no doses scheduled → no MED_COMPLIANCE ring at all, never a 0% one")
    func absentRingIsNotZero() throws {
        let json = Data(#"""
        {
          "briefingState": "ready",
          "scoreRings": [{ "id": "SLEEP_SCORE", "score": 81, "band": "green" }]
        }
        """#.utf8)
        let slot = try JSONDecoder.hlDefault.decode(DashboardSnapshotBriefing.self, from: json)
        #expect(slot.scoreRings.contains { $0.id == .medCompliance } == false)
        // Rendering reads the array — an absent ring simply has no row.
        let rows = DashboardHeroRingReconciler.reconcile(snapshotRings: slot.scoreRings, derived: [])
        #expect(rows.contains { $0.id == .medCompliance } == false)
    }

    /// The dose ring is a progress reading, not an adherence judgement: the
    /// server emits green when the day is done and yellow while doses remain.
    /// Red is unreachable by construction, so no surface may map it.
    @Test("MED_COMPLIANCE bands are green or yellow only", arguments: [
        ("{\"taken\":3,\"scheduled\":3}", 100, "green"),
        ("{\"taken\":0,\"scheduled\":2}", 0, "yellow"),
        ("{\"taken\":1,\"scheduled\":2}", 50, "yellow")
    ])
    func medComplianceBandsNeverRed(doses: String, score: Int, band: String) throws {
        let json = Data(#"""
        {
          "briefingState": "ready",
          "scoreRings": [{ "id": "MED_COMPLIANCE", "score": \#(score), "band": "\#(band)", "doses": \#(doses) }]
        }
        """#.utf8)
        let slot = try JSONDecoder.hlDefault.decode(DashboardSnapshotBriefing.self, from: json)
        let ring = try #require(slot.scoreRings.first)
        #expect(ring.band != "red")
        #expect(ring.score == score)
        // A zero-progress morning is yellow, not a red failure.
        if score == 0 { #expect(ring.band == "yellow") }
    }

    /// The derived rings keep the snapshot value only until the live derived
    /// source lands; either way the number comes from a server, never from an
    /// on-device blend.
    @Test("derived rings adopt the live server value and never a local computation")
    func derivedRingsUseServerValues() {
        let ring = DashboardScoreRing(id: .recovery, score: 55, band: "yellow")
        let live = DerivedMetricDTO(
            metric: "RECOVERY_SCORE",
            status: "ok",
            value: DerivedMetricDTO.Value(score: 61, band: "yellow"),
            coverage: DerivedMetricDTO.Coverage(
                requiredInputs: 5, presentInputs: 4, historyDays: 14, missing: []
            ),
            confidence: DerivedMetricDTO.Confidence(score: 80, band: "high"),
            provenance: DerivedMetricDTO.Provenance(
                inputs: ["RESTING_HEART_RATE"], source: "DAY", windowDays: 14, computedAt: .now
            ),
            reason: nil
        )
        let rows = DashboardHeroRingReconciler.reconcile(snapshotRings: [ring], derived: [live])
        #expect(rows.first?.displayScore == 61)
        #expect(rows.first?.source == .live)

        // Without the live read the snapshot value stands — still a server number.
        let cold = DashboardHeroRingReconciler.reconcile(snapshotRings: [ring], derived: [])
        #expect(cold.first?.displayScore == 55)
        #expect(cold.first?.source == .snapshot)
    }
}

// swiftlint:enable force_unwrapping
