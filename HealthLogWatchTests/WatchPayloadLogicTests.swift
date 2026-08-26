import Foundation
import Testing

/// **H4 — watch-target logic tests (audit-v0162).**
///
/// The shared `WatchPayload` contract is compiled into the watch app, its
/// complication, AND the phone app. The phone side of the contract is tested in
/// `HealthLogTests`; this exercises the same pure logic AS COMPILED FOR watchOS
/// (source membership), where the watch app + complication actually run it: the
/// tolerant decode, the complication glance derivations (health-score band,
/// compliance fraction), the optimistic mood-count delta, deep-link routing, and
/// the plist-safe transport round-trip.
@Suite("WatchPayload logic (watchOS)")
struct WatchPayloadLogicTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Tolerant decode

    @Test("an empty/partial blob decodes to the neutral empty state, never a trap")
    func tolerantDecodeOfPartialBlob() throws {
        let snapshot = try decoder.decode(WatchSnapshot.self, from: Data("{}".utf8))
        #expect(snapshot.doses.isEmpty)
        #expect(snapshot.scheduledCount == 0)
        #expect(snapshot.takenCount == 0)
        #expect(snapshot.recentMoodScore == nil)
        #expect(snapshot.moodCountToday == 0)
        #expect(snapshot.signedIn == false)
        #expect(snapshot.healthScore == nil)
        #expect(snapshot.latestMeasurement == nil)
        #expect(snapshot.generatedAt == .distantPast)
    }

    @Test("the legacy `canLog` key is honoured over `signedIn` on decode")
    func decodePrefersCanLogKey() throws {
        let json = Data(#"{ "signedIn": false, "canLog": true }"#.utf8)
        let snapshot = try decoder.decode(WatchSnapshot.self, from: json)
        #expect(snapshot.signedIn == true)
    }

    // MARK: - Cleared (logout) shape

    @Test("the placeholder is `isCleared`; a data-carrying snapshot is not")
    func clearedShapeDetection() {
        #expect(WatchSnapshot.placeholder.isCleared)

        let withData = WatchSnapshot(
            doses: [],
            scheduledCount: 0,
            takenCount: 0,
            recentMoodScore: 3,
            signedIn: false,
            generatedAt: .distantPast
        )
        #expect(!withData.isCleared, "a lingering mood score means the snapshot still carries PHI")
    }

    // MARK: - Health-score complication glance

    @Test("health-score signal band prefers the server band, else derives from thresholds")
    func healthScoreSignalBand() {
        // Server band wins verbatim.
        #expect(WatchSnapshot.HealthScoreGlance(score: 10, band: "green").signalBand == "green")
        // No band → numeric thresholds (>=70 green / >=40 yellow / else red).
        #expect(WatchSnapshot.HealthScoreGlance(score: 85, band: nil).signalBand == "green")
        #expect(WatchSnapshot.HealthScoreGlance(score: 55, band: nil).signalBand == "yellow")
        #expect(WatchSnapshot.HealthScoreGlance(score: 20, band: nil).signalBand == "red")
        // An unknown band string is ignored → derived from thresholds.
        #expect(WatchSnapshot.HealthScoreGlance(score: 90, band: "chartreuse").signalBand == "green")
    }

    @Test("health-score clamps to 0…100 and reports a 0…1 fraction")
    func healthScoreClampsAndFraction() {
        #expect(WatchSnapshot.HealthScoreGlance(score: 150, band: nil).score == 100)
        #expect(WatchSnapshot.HealthScoreGlance(score: -10, band: nil).score == 0)
        #expect(WatchSnapshot.HealthScoreGlance(score: 50, band: nil).fraction == 0.5)
    }

    // MARK: - Compliance fraction

    @Test("compliance fraction clamps, and an empty day reads as complete (1.0)")
    func complianceFraction() {
        func snap(scheduled: Int, taken: Int) -> WatchSnapshot {
            WatchSnapshot(
                doses: [],
                scheduledCount: scheduled,
                takenCount: taken,
                recentMoodScore: nil,
                signedIn: true,
                generatedAt: .distantPast
            )
        }
        #expect(snap(scheduled: 0, taken: 0).complianceFraction == 1)
        #expect(snap(scheduled: 4, taken: 1).complianceFraction == 0.25)
        // Over-taken (server drift) clamps to 1, never > 1.
        #expect(snap(scheduled: 2, taken: 5).complianceFraction == 1)
    }

    // MARK: - Optimistic mood-count delta

    @Test("displayed mood count adds only the wrist taps a snapshot doesn't yet reflect")
    func moodCountDelta() {
        let generatedAt = Date(timeIntervalSince1970: 1000)
        let older = Date(timeIntervalSince1970: 900) // already reflected
        let newer1 = Date(timeIntervalSince1970: 1100)
        let newer2 = Date(timeIntervalSince1970: 1200)

        let count = WatchMoodCount.displayedCount(
            snapshotCount: 2,
            pendingTaps: [older, newer1, newer2],
            snapshotGeneratedAt: generatedAt
        )
        // 2 authoritative + 2 unreflected taps (the older one is dropped).
        #expect(count == 4)

        let unreflected = WatchMoodCount.unreflectedTaps(
            pendingTaps: [older, newer1, newer2],
            snapshotGeneratedAt: generatedAt
        )
        #expect(unreflected.count == 2)
    }

    // MARK: - Deep-link routing

    @Test("complication deep-link hosts map onto the correct wrist tab")
    func deepLinkTargetMapping() {
        func target(_ host: String) -> WatchDeepLinkTarget? {
            guard let url = URL(string: "healthlog://\(host)") else { return nil }
            return WatchDeepLinkTarget(url: url)
        }
        #expect(target("medications") == .medications)
        #expect(target("nextDose") == .medications)
        #expect(target("healthScore") == .medications)
        #expect(target("mood") == .mood)
        #expect(target("measure") == .measure)
        #expect(target("measurement") == .measure)
        #expect(target("log") == .measure)
        #expect(target("bogus") == nil)
    }

    // MARK: - Transport round-trip

    @Test("WatchTransport encodes a snapshot into a plist-safe blob and decodes it back")
    func transportSnapshotRoundTrips() {
        let t = Date(timeIntervalSince1970: 1_733_400_000)
        let snapshot = WatchSnapshot(
            doses: [],
            scheduledCount: 3,
            takenCount: 2,
            recentMoodScore: 5,
            moodCountToday: 2,
            signedIn: true,
            generatedAt: t
        )
        let encoded = WatchTransport.encode(snapshot: snapshot)
        #expect(encoded[WatchTransport.snapshotKey] != nil)

        let decoded = WatchTransport.decodeSnapshot(encoded)
        #expect(decoded == snapshot)
    }

    @Test("WatchTransport round-trips a mark-intake action and an ack")
    func transportActionAndAckRoundTrip() {
        let action = WatchAction.markIntake(intakeId: "synth:7", status: .taken, at: Date(timeIntervalSince1970: 1_733_400_000))
        let decodedAction = WatchTransport.decodeAction(WatchTransport.encode(action: action))
        #expect(decodedAction?.id == action.id)
        #expect(decodedAction?.kind == action.kind)

        let ack = WatchAck(id: action.id, outcome: .saved, at: Date(timeIntervalSince1970: 1_733_400_000))
        let decodedAck = WatchTransport.decodeAck(WatchTransport.encode(ack: ack))
        #expect(decodedAck == ack)
    }
}
