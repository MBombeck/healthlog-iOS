import Foundation
@testable import HealthLog
import Testing

/// **v0.15.2 W-WATCH-COMPLICATIONS — watch-face complication glance mapping.**
///
/// The complications (`HealthScoreComplication`, `LatestMeasurementComplication`,
/// and the next-dose ring) read plain-data glances off the `WatchSnapshot`, so
/// the snapshot → glance map is unit-testable without a WidgetKit host. Mirrors
/// the `WatchSnapshotBuilder` test discipline (pure, no store / network).
@Suite("WatchComplicationGlance")
struct WatchComplicationGlanceTests {
    private let cal = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func score(_ value: Int, band: HealthScoreBand?) -> HealthScore {
        HealthScore(score: value, band: band, delta: nil)
    }

    private func weight(_ kg: Double) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: UUID().uuidString,
            kind: .weight,
            recordedAt: now,
            value: .scalar(kg),
            source: .manual
        )
    }

    /// Locale-robust 1-decimal expectation matching the descriptor formatter
    /// (`.number.precision(.fractionLength(1))`) — the simulator locale may use
    /// a comma decimal separator, so a hardcoded period would falsely fail.
    private func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    // MARK: - Health-score glance

    @Test("Score glance mirrors the server value + band verbatim")
    func scoreGlanceMirrors() {
        let glance = WatchSnapshot.HealthScoreGlance.make(from: score(82, band: .green))
        #expect(glance?.score == 82)
        #expect(glance?.band == "green")
        // 82/100 ring fraction.
        #expect(glance?.fraction == 0.82)
    }

    @Test("Score clamps to 0…100 and the fraction stays in 0…1")
    func scoreClamps() {
        let high = WatchSnapshot.HealthScoreGlance(score: 240, band: nil)
        #expect(high.score == 100)
        #expect(high.fraction == 1.0)

        let low = WatchSnapshot.HealthScoreGlance(score: -30, band: nil)
        #expect(low.score == 0)
        #expect(low.fraction == 0.0)
    }

    @Test("Absent score → nil glance (complication shows em-dash placeholder)")
    func scoreAbsent() {
        #expect(WatchSnapshot.HealthScoreGlance.make(from: nil) == nil)
    }

    @Test("Band signal resolves from the server band, falling back to thresholds")
    func bandSignalResolves() {
        // Server band wins.
        #expect(WatchSnapshot.HealthScoreGlance(score: 10, band: "green").signalBand == "green")
        #expect(WatchSnapshot.HealthScoreGlance(score: 90, band: "yellow").signalBand == "yellow")
        #expect(WatchSnapshot.HealthScoreGlance(score: 90, band: "red").signalBand == "red")
        // No band → numeric thresholds (≥70 green / ≥40 yellow / else red).
        #expect(WatchSnapshot.HealthScoreGlance(score: 70, band: nil).signalBand == "green")
        #expect(WatchSnapshot.HealthScoreGlance(score: 55, band: nil).signalBand == "yellow")
        #expect(WatchSnapshot.HealthScoreGlance(score: 12, band: nil).signalBand == "red")
    }

    // MARK: - Latest-measurement glance

    @Test("Latest-measurement glance carries title / value / unit / symbol")
    func measurementGlanceMaps() {
        let glance = WatchSnapshot.LatestMeasurement.make(from: weight(72.4))
        #expect(glance?.kindRaw == "weight")
        #expect(glance?.formattedValue == oneDecimal(72.4))
        #expect(glance?.unit == "kg")
        #expect(glance?.symbol.isEmpty == false)
        #expect(glance?.recordedAt == now)
    }

    @Test("Blood-pressure folds the systolic/diastolic pair into one value string")
    func measurementBloodPressure() {
        let bp = HealthLog.Measurement(
            id: "m-bp",
            kind: .bloodPressure,
            recordedAt: now,
            value: .bloodPressure(systolic: 128, diastolic: 82),
            source: .manual
        )
        let glance = WatchSnapshot.LatestMeasurement.make(from: bp)
        #expect(glance?.formattedValue == "128/82")
        #expect(glance?.unit == "mmHg")
    }

    @Test("Non-finite reading formats to an em-dash, not NaN")
    func measurementNonFinite() {
        let glance = WatchSnapshot.LatestMeasurement.make(from: weight(.nan))
        #expect(glance?.formattedValue == "—")
    }

    @Test("Absent measurement → nil glance")
    func measurementAbsent() {
        #expect(WatchSnapshot.LatestMeasurement.make(from: nil) == nil)
    }

    // MARK: - Builder folds the glances into the snapshot

    @Test("Builder folds the score + measurement glances into the snapshot")
    func builderFoldsGlances() {
        let snap = WatchSnapshot.make(
            medications: [],
            derivedIntakes: [],
            latestMood: nil,
            signedIn: true,
            healthScore: WatchSnapshot.HealthScoreGlance(score: 64, band: "yellow"),
            latestMeasurement: WatchSnapshot.LatestMeasurement.make(from: weight(70.1)),
            now: now,
            calendar: cal
        )
        #expect(snap.healthScore?.score == 64)
        #expect(snap.healthScore?.band == "yellow")
        #expect(snap.latestMeasurement?.formattedValue == oneDecimal(70.1))
    }

    @Test("Snapshot without glances leaves them nil (complications show placeholders)")
    func builderNilGlances() {
        let snap = WatchSnapshot.make(
            medications: [],
            derivedIntakes: [],
            latestMood: nil,
            signedIn: false,
            now: now,
            calendar: cal
        )
        #expect(snap.healthScore == nil)
        #expect(snap.latestMeasurement == nil)
    }

    // MARK: - Wire compat

    @Test("Glances survive an encode → decode round-trip")
    func glanceRoundTrip() throws {
        let snap = WatchSnapshot.make(
            medications: [],
            derivedIntakes: [],
            latestMood: nil,
            signedIn: true,
            healthScore: WatchSnapshot.HealthScoreGlance(score: 77, band: "green"),
            latestMeasurement: WatchSnapshot.LatestMeasurement.make(from: weight(81.5)),
            now: now,
            calendar: cal
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WatchSnapshot.self, from: encoder.encode(snap))
        #expect(decoded.healthScore?.score == 77)
        #expect(decoded.healthScore?.band == "green")
        #expect(decoded.latestMeasurement?.formattedValue == oneDecimal(81.5))
    }

    @Test("An old blob without the glance fields tolerant-decodes to nil glances")
    func legacyDecodeNilGlances() throws {
        let legacyJSON = """
        {
          "doses": [],
          "scheduledCount": 0,
          "takenCount": 0,
          "signedIn": true,
          "generatedAt": "2023-11-14T22:13:20Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap = try decoder.decode(WatchSnapshot.self, from: Data(legacyJSON.utf8))
        #expect(snap.healthScore == nil)
        #expect(snap.latestMeasurement == nil)
    }

    // MARK: - Deep-link routing (watch-side tab resolution)

    @Test("Deep links resolve to the matching watch tab")
    func deepLinkRouting() throws {
        func target(_ host: String) throws -> WatchDeepLinkTarget? {
            try WatchDeepLinkTarget(url: #require(URL(string: "healthlog://\(host)")))
        }
        #expect(try target("medications") == .medications)
        #expect(try target("nextDose") == .medications)
        #expect(try target("healthScore") == .medications)
        #expect(try target("measure") == .measure)
        #expect(try target("mood") == .mood)
        #expect(try target("unknown") == nil)
    }
}
