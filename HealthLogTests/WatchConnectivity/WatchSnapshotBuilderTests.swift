import Foundation
@testable import HealthLog
import Testing

/// **v0.12 P2 — phone-side snapshot builder.** Deterministic map from the
/// app's medication universe + derived intakes + latest mood onto the thin
/// watch snapshot. Mirrors the `WidgetSnapshotMapping` test discipline (pure,
/// no store / network).
@Suite("WatchSnapshotBuilder")
struct WatchSnapshotBuilderTests {
    private let cal = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func med(_ id: String, _ name: String, dose: String = "", injection: Bool = false) -> Medication {
        Medication(
            id: id,
            name: name,
            dose: dose,
            schedule: MedicationSchedule(times: []),
            trackInjectionSites: injection
        )
    }

    private func intake(_ id: String, med: String, at: TimeInterval, status: IntakeStatus) -> MedicationIntake {
        MedicationIntake(
            id: id,
            medicationId: med,
            scheduledAt: Date(timeIntervalSince1970: at),
            takenAt: status == .taken ? Date(timeIntervalSince1970: at) : nil,
            status: status
        )
    }

    @Test("Maps doses with name / dose / injection + soonest-first")
    func mapsDoses() {
        let meds = [
            med("m1", "Lisinopril", dose: "5 mg"),
            med("m2", "Trulicity", dose: "2.5 mg", injection: true)
        ]
        let intakes = [
            intake("i2", med: "m2", at: 1_700_003_600, status: .pending),
            intake("i1", med: "m1", at: 1_700_000_000, status: .pending)
        ]

        let snap = WatchSnapshot.make(
            medications: meds,
            derivedIntakes: intakes,
            latestMood: nil,
            signedIn: true,
            now: now,
            calendar: cal
        )

        #expect(snap.doses.count == 2)
        // Soonest first.
        #expect(snap.doses.first?.id == "i1")
        #expect(snap.doses.first?.medicationName == "Lisinopril")
        #expect(snap.doses.first?.doseText == "5 mg")
        #expect(snap.doses.first?.isInjection == false)
        #expect(snap.doses.last?.medicationName == "Trulicity")
        #expect(snap.doses.last?.isInjection == true)
        #expect(snap.signedIn)
    }

    @Test("Compliance counts taken vs scheduled; taken/actionable flags")
    func complianceCounts() {
        let meds = [med("m1", "A"), med("m2", "B"), med("m3", "C")]
        let intakes = [
            intake("i1", med: "m1", at: 1_700_000_000, status: .taken),
            intake("i2", med: "m2", at: 1_700_001_000, status: .pending),
            intake("i3", med: "m3", at: 1_700_002_000, status: .skipped)
        ]

        let snap = WatchSnapshot.make(
            medications: meds,
            derivedIntakes: intakes,
            latestMood: nil,
            signedIn: true,
            now: now,
            calendar: cal
        )

        #expect(snap.scheduledCount == 3)
        #expect(snap.takenCount == 1)
        #expect(snap.complianceFraction == 1.0 / 3.0)

        let taken = snap.doses.first { $0.id == "i1" }
        #expect(taken?.isTaken == true)
        #expect(taken?.isActionable == false)

        let pending = snap.doses.first { $0.id == "i2" }
        #expect(pending?.isActionable == true)

        // Skipped is resolved → not actionable, not taken.
        let skipped = snap.doses.first { $0.id == "i3" }
        #expect(skipped?.isActionable == false)
        #expect(skipped?.isTaken == false)
    }

    @Test("Latest mood surfaces only when logged today")
    func moodTodayGating() {
        let meds = [med("m1", "A")]
        let intakes = [intake("i1", med: "m1", at: 1_700_000_000, status: .pending)]

        let todayMood = MoodEntry(id: "mood-1", recordedAt: now, score: 4)
        let snapToday = WatchSnapshot.make(
            medications: meds, derivedIntakes: intakes,
            latestMood: todayMood, signedIn: true, now: now, calendar: cal
        )
        #expect(snapToday.recentMoodScore == 4)

        let yesterday = now.addingTimeInterval(-60 * 60 * 24)
        let oldMood = MoodEntry(id: "mood-0", recordedAt: yesterday, score: 2)
        let snapOld = WatchSnapshot.make(
            medications: meds, derivedIntakes: intakes,
            latestMood: oldMood, signedIn: true, now: now, calendar: cal
        )
        #expect(snapOld.recentMoodScore == nil)
    }

    @Test("moodCountToday carries the day's mood-entry count for the wrist subhead")
    func moodCountTodaySurfaces() {
        let meds = [med("m1", "A")]
        let intakes = [intake("i1", med: "m1", at: 1_700_000_000, status: .pending)]
        let today = MoodEntry(id: "mood-1", recordedAt: now, score: 4)

        // Phone passes the count it derived from the store; the builder echoes it.
        let snap = WatchSnapshot.make(
            medications: meds, derivedIntakes: intakes,
            latestMood: today, moodCountToday: 3,
            signedIn: true, now: now, calendar: cal
        )
        #expect(snap.moodCountToday == 3)
        // The single-scalar hint still reflects the latest score.
        #expect(snap.recentMoodScore == 4)
    }

    @Test("moodCountToday defaults to 0 and clamps negatives")
    func moodCountTodayDefaultsAndClamps() {
        let snapDefault = WatchSnapshot.make(
            medications: [], derivedIntakes: [],
            latestMood: nil, signedIn: true, now: now, calendar: cal
        )
        #expect(snapDefault.moodCountToday == 0)

        let snapNegative = WatchSnapshot.make(
            medications: [], derivedIntakes: [],
            latestMood: nil, moodCountToday: -5,
            signedIn: true, now: now, calendar: cal
        )
        #expect(snapNegative.moodCountToday == 0)
    }

    @Test("An old blob without moodCountToday tolerant-decodes to 0")
    func moodCountTodayTolerantDecode() throws {
        // Simulate an older snapshot blob that predates the field entirely.
        let legacyJSON = """
        {
          "doses": [],
          "scheduledCount": 0,
          "takenCount": 0,
          "signedIn": true,
          "generatedAt": "2023-11-14T22:13:20Z"
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap = try decoder.decode(WatchSnapshot.self, from: data)
        #expect(snap.moodCountToday == 0)
        #expect(snap.signedIn == true)
    }

    @Test("moodCountToday survives an encode → decode round-trip")
    func moodCountTodayRoundTrip() throws {
        let snap = WatchSnapshot.make(
            medications: [], derivedIntakes: [],
            latestMood: MoodEntry(id: "m", recordedAt: now, score: 5),
            moodCountToday: 7, signedIn: true, now: now, calendar: cal
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WatchSnapshot.self, from: encoder.encode(snap))
        #expect(decoded.moodCountToday == 7)
    }

    @Test("Empty universe is a complete (1.0) ring, signed-out flag honoured")
    func emptyUniverse() {
        let snap = WatchSnapshot.make(
            medications: [], derivedIntakes: [],
            latestMood: nil, signedIn: false, now: now, calendar: cal
        )
        #expect(snap.doses.isEmpty)
        #expect(snap.scheduledCount == 0)
        #expect(snap.complianceFraction == 1.0)
        #expect(snap.signedIn == false)
    }
}
