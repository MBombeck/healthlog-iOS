import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.8.4 WWIDGET-2** — pins the widget snapshot mechanism: the pure
/// medications→`WidgetSnapshot` mapping (the timeline data the next-dose +
/// compliance widgets render), the App Group store round-trip, and the
/// `ComplianceSummary.fraction` contract.
@Suite("WidgetSnapshot — mapping + persistence")
struct WidgetSnapshotTests {
    /// Fixed reference clock: 2026-05-29 08:00 local.
    private var now: Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 5
        comps.day = 29
        comps.hour = 8
        comps.minute = 0
        return Calendar.current.date(from: comps)!
    }

    private func med(
        id: String = "med-1",
        name: String = "Vitamin D",
        dose: String = "1000 IE",
        times: [TimeOfDay],
        active: Bool = true,
        notificationsEnabled: Bool = true
    ) -> Medication {
        Medication(
            id: id,
            name: name,
            dose: dose,
            schedule: MedicationSchedule(times: times),
            notificationsEnabled: notificationsEnabled,
            active: active
        )
    }

    private func intake(
        medicationId: String = "med-1",
        hour: Int,
        minute: Int = 0,
        status: IntakeStatus
    ) -> MedicationIntake {
        let scheduled = Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: now
        )!
        return MedicationIntake(
            id: "\(medicationId)-\(hour)",
            medicationId: medicationId,
            scheduledAt: scheduled,
            takenAt: status == .taken ? now : nil,
            status: status
        )
    }

    // MARK: - Mapping: next dose

    @Test("Surfaces the soonest due dose in the next-dose snapshot")
    func mapsNextDose() {
        // Dose at 09:00, now 08:00 → inside the lead window, not taken.
        let medication = med(times: [TimeOfDay(hour: 9, minute: 0)])
        let derived = [intake(hour: 9, status: .pending)]
        let snapshot = WidgetSnapshot.make(
            medications: [medication],
            derivedIntakes: derived,
            now: now
        )
        #expect(snapshot.nextDose?.medicationId == "med-1")
        #expect(snapshot.nextDose?.medicationName == "Vitamin D")
        #expect(snapshot.nextDose?.doseText == "1000 IE")
    }

    @Test("No next dose when nothing is due in-window")
    func mapsNoNextDose() {
        // Only dose was at 06:00 and is already taken → nothing to surface.
        let medication = med(times: [TimeOfDay(hour: 6, minute: 0)])
        let derived = [intake(hour: 6, status: .taken)]
        let snapshot = WidgetSnapshot.make(
            medications: [medication],
            derivedIntakes: derived,
            now: now
        )
        #expect(snapshot.nextDose == nil)
    }

    // MARK: - Mapping: compliance

    @Test("Compliance counts taken over total scheduled for today")
    func mapsCompliance() {
        let medication = med(times: [
            TimeOfDay(hour: 6, minute: 0),
            TimeOfDay(hour: 9, minute: 0),
            TimeOfDay(hour: 21, minute: 0)
        ])
        let derived = [
            intake(hour: 6, status: .taken),
            intake(hour: 9, status: .pending),
            intake(hour: 21, status: .pending)
        ]
        let snapshot = WidgetSnapshot.make(
            medications: [medication],
            derivedIntakes: derived,
            now: now
        )
        #expect(snapshot.compliance.scheduled == 3)
        #expect(snapshot.compliance.taken == 1)
        #expect(abs(snapshot.compliance.fraction - 1.0 / 3.0) < 0.0001)
    }

    @Test("Empty schedule reads as a complete ring (no alarming zero)")
    func emptyComplianceIsComplete() {
        let summary = WidgetSnapshot.ComplianceSummary(scheduled: 0, taken: 0)
        #expect(summary.fraction == 1)
    }

    // MARK: - W-B183 — server-ledger compliance drives the ring

    @Test("ringFraction tracks the SERVER ledger percent, not the today count")
    func ringFractionPrefersServerPercent() {
        // Today: 1 of 4 taken (fraction 0.25) — but the server ledger says 80%.
        // The ring must paint the server value, not the client today count.
        let summary = WidgetSnapshot.ComplianceSummary(
            scheduled: 4,
            taken: 1,
            serverCompliancePercent: 80
        )
        #expect(abs(summary.ringFraction - 0.8) < 0.0001)
        // The literal x/y count label still reflects today.
        #expect(summary.taken == 1)
        #expect(summary.scheduled == 4)
        // The fallback fraction stays the today count (unused while server set).
        #expect(abs(summary.fraction - 0.25) < 0.0001)
    }

    @Test("ringFraction falls back to the today count when no server value")
    func ringFractionFallsBackWithoutServer() {
        let summary = WidgetSnapshot.ComplianceSummary(scheduled: 4, taken: 1)
        #expect(summary.serverCompliancePercent == nil)
        #expect(abs(summary.ringFraction - 0.25) < 0.0001)
    }

    @Test("ringFraction clamps a server percent into 0...1")
    func ringFractionClampsServerPercent() {
        #expect(WidgetSnapshot.ComplianceSummary(scheduled: 2, taken: 0, serverCompliancePercent: 140).ringFraction == 1)
        #expect(WidgetSnapshot.ComplianceSummary(scheduled: 2, taken: 0, serverCompliancePercent: -5).ringFraction == 0)
    }

    @Test("The server compliance percent round-trips through the store")
    func serverCompliancePercentRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-compliance-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetSnapshotStore(url: url)

        let original = WidgetSnapshot(
            nextDose: nil,
            compliance: .init(scheduled: 5, taken: 2, serverCompliancePercent: 73),
            generatedAt: now
        )
        try store.write(original)
        let restored = try #require(store.read())
        #expect(restored == original)
        #expect(restored.compliance.serverCompliancePercent == 73)
        // The widget's painted ring value equals the server value.
        #expect(abs(restored.compliance.ringFraction - 0.73) < 0.0001)
    }

    @Test("make() carries the server compliance percent into the snapshot")
    func makeCarriesServerPercent() {
        let medication = med(times: [TimeOfDay(hour: 9, minute: 0)])
        let derived = [intake(hour: 9, status: .pending)]
        let snapshot = WidgetSnapshot.make(
            medications: [medication],
            derivedIntakes: derived,
            serverCompliancePercent: 91,
            now: now
        )
        #expect(snapshot.compliance.serverCompliancePercent == 91)
        #expect(abs(snapshot.compliance.ringFraction - 0.91) < 0.0001)
    }

    @Test("A legacy snapshot (no serverCompliancePercent) decodes nil + falls back")
    func legacyComplianceDecodesNilServerPercent() throws {
        let legacy = """
        {"compliance":{"scheduled":4,"taken":1},"generatedAt":"2026-05-29T08:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.compliance.serverCompliancePercent == nil)
        #expect(abs(snapshot.compliance.ringFraction - 0.25) < 0.0001)
    }

    // MARK: - W-B183 — canonical time format carried in the snapshot

    @Test("The time-format raw value round-trips through the store")
    func timeFormatRawRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeformat-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetSnapshotStore(url: url)

        let original = WidgetSnapshot(
            nextDose: nil,
            compliance: .init(scheduled: 0, taken: 0),
            timeFormatRaw: HLTimeFormat.twentyFourHour.rawValue,
            generatedAt: now
        )
        try store.write(original)
        let restored = try #require(store.read())
        #expect(restored.timeFormatRaw == "H24")
        // The widget resolves it back to the canonical formatter and renders the
        // SAME clock string the app's `HLTimeFormat` produces.
        let resolved = HLTimeFormat(rawValue: restored.timeFormatRaw) ?? .auto
        #expect(resolved == .twentyFourHour)
        #expect(resolved.formatTime(now) == HLTimeFormat.twentyFourHour.formatTime(now))
    }

    @Test("A legacy snapshot (no timeFormatRaw) decodes as AUTO")
    func legacySnapshotDecodesAutoTimeFormat() throws {
        let legacy = """
        {"compliance":{"scheduled":2,"taken":1},"generatedAt":"2026-05-29T08:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.timeFormatRaw == "AUTO")
        #expect(HLTimeFormat(rawValue: snapshot.timeFormatRaw) == .auto)
    }

    @Test("Fraction clamps to 0...1 even with over-count")
    func fractionClamps() {
        #expect(WidgetSnapshot.ComplianceSummary(scheduled: 2, taken: 5).fraction == 1)
        #expect(WidgetSnapshot.ComplianceSummary(scheduled: 4, taken: 0).fraction == 0)
    }

    // MARK: - App Group store round-trip

    @Test("Snapshot survives a write → read round-trip")
    func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = WidgetSnapshotStore(url: url)
        let original = WidgetSnapshot(
            nextDose: WidgetSnapshot.NextDose(
                medicationId: "med-1",
                medicationName: "Vitamin D",
                doseText: "1000 IE",
                scheduledAt: now
            ),
            compliance: WidgetSnapshot.ComplianceSummary(scheduled: 3, taken: 1),
            generatedAt: now
        )

        try store.write(original)
        let restored = store.read()

        #expect(restored == original)
    }

    @Test("Reading a missing file returns nil, not a crash")
    func readMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let store = WidgetSnapshotStore(url: url)
        #expect(store.read() == nil)
    }

    @Test("A nil container URL makes write a no-op and read nil")
    func nilContainerIsSafe() throws {
        let store = WidgetSnapshotStore(url: nil)
        try store.write(.placeholder) // must not throw
        #expect(store.read() == nil)
    }

    // MARK: - Timeline refresh policy

    @Test("Next-dose reload anchors on a future scheduled time")
    func nextDoseReloadAnchorsOnFuture() {
        // Dose 20 min out, inside the 30-min backstop → reload at the dose.
        let scheduled = now.addingTimeInterval(20 * 60)
        let reload = WidgetTimelinePolicy.nextDoseReload(after: now, scheduledAt: scheduled)
        #expect(reload == scheduled)
    }

    @Test("Next-dose reload falls back to the backstop for a past/absent dose")
    func nextDoseReloadFallsBackToBackstop() {
        let expected = now.addingTimeInterval(WidgetTimelinePolicy.nextDoseBackstop)
        // Overdue dose (1h ago) → backstop, not the past time.
        #expect(WidgetTimelinePolicy.nextDoseReload(after: now, scheduledAt: now.addingTimeInterval(-3600)) == expected)
        // No dose → backstop.
        #expect(WidgetTimelinePolicy.nextDoseReload(after: now, scheduledAt: nil) == expected)
    }

    @Test("Next-dose reload caps a far-future dose at the backstop")
    func nextDoseReloadCapsFarFuture() {
        // Dose 5h out → backstop (30 min) wins so the countdown stays live.
        let expected = now.addingTimeInterval(WidgetTimelinePolicy.nextDoseBackstop)
        let reload = WidgetTimelinePolicy.nextDoseReload(after: now, scheduledAt: now.addingTimeInterval(5 * 3600))
        #expect(reload == expected)
    }

    @Test("Compliance reload lands on the next local midnight")
    func complianceReloadAtMidnight() throws {
        let reload = WidgetTimelinePolicy.complianceReload(after: now)
        let expected = try #require(Calendar.current.date(
            byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)
        ))
        #expect(reload == expected)
        #expect(reload > now)
    }

    // MARK: - v0.10.0 W-Mood-B — mood glance field

    @Test("RecentMood.isToday distinguishes a same-day from a prior-day entry")
    func recentMoodIsToday() {
        let today = WidgetSnapshot.RecentMood(score: 4, loggedAt: now)
        #expect(today.isToday(now: now))
        let yesterday = WidgetSnapshot.RecentMood(
            score: 4,
            loggedAt: now.addingTimeInterval(-24 * 3600)
        )
        #expect(yesterday.isToday(now: now) == false)
    }

    @Test("RecentMood clamps the score into 1…5")
    func recentMoodClampsScore() {
        #expect(WidgetSnapshot.RecentMood(score: 0, loggedAt: now).score == 1)
        #expect(WidgetSnapshot.RecentMood(score: 9, loggedAt: now).score == 5)
        #expect(WidgetSnapshot.RecentMood(score: 3, loggedAt: now).score == 3)
    }

    @Test("A snapshot round-trips the mood field through the store")
    func snapshotMoodRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mood-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetSnapshotStore(url: url)

        let snapshot = WidgetSnapshot(
            nextDose: nil,
            compliance: .init(scheduled: 0, taken: 0),
            recentMood: .init(score: 5, loggedAt: now),
            generatedAt: now
        )
        try store.write(snapshot)
        let read = try #require(store.read())
        #expect(read.recentMood?.score == 5)
    }

    @Test("A legacy snapshot (no recentMood key) decodes with a nil mood")
    func legacySnapshotDecodesNilMood() throws {
        // The pre-W-Mood-B snapshot shape had no `recentMood` key.
        let legacy = """
        {"compliance":{"scheduled":2,"taken":1},"generatedAt":"2026-05-29T08:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.recentMood == nil)
        #expect(snapshot.compliance.scheduled == 2)
        #expect(snapshot.nextDose == nil)
    }

    @Test("MoodLevelAppEnum(score:) clamps and maps to the domain level")
    func moodEnumScoreInit() {
        #expect(MoodLevelAppEnum(score: 1) == .lousy)
        #expect(MoodLevelAppEnum(score: 5) == .great)
        #expect(MoodLevelAppEnum(score: 0) == .lousy)
        #expect(MoodLevelAppEnum(score: 99) == .great)
        #expect(MoodLevelAppEnum(score: 3).score == 3)
    }

    // MARK: - v0.15 companion-#3 — health-score glance

    @Test("HealthScoreGlance mirrors the server score + band verbatim")
    func healthScoreGlanceMapsFromServer() throws {
        let score = HealthScore(score: 84, band: .green, delta: nil)
        let glance = try #require(WidgetSnapshot.HealthScoreGlance.make(from: score, now: now))
        #expect(glance.score == 84)
        #expect(glance.band == "green")
        #expect(abs(glance.fraction - 0.84) < 0.0001)
    }

    @Test("HealthScoreGlance falls back to the numeric band when server omits one")
    func healthScoreGlanceBandFallback() throws {
        // No server band → displayBand uses the 67/34 numeric thresholds.
        let lowScore = HealthScore(score: 20, band: nil, delta: nil)
        let glance = try #require(WidgetSnapshot.HealthScoreGlance.make(from: lowScore))
        #expect(glance.band == "red")
    }

    @Test("HealthScoreGlance clamps the score + fraction into range")
    func healthScoreGlanceClamps() {
        #expect(WidgetSnapshot.HealthScoreGlance(score: 140, band: nil, resolvedAt: now).score == 100)
        #expect(WidgetSnapshot.HealthScoreGlance(score: -10, band: nil, resolvedAt: now).fraction == 0)
    }

    @Test("nil server score yields a nil glance")
    func healthScoreGlanceNilPassthrough() {
        #expect(WidgetSnapshot.HealthScoreGlance.make(from: nil) == nil)
    }

    @Test("The health-score glance round-trips through the store")
    func healthScoreGlanceRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("score-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetSnapshotStore(url: url)
        let snapshot = WidgetSnapshot(
            nextDose: nil,
            compliance: .init(scheduled: 0, taken: 0),
            healthScore: .init(score: 73, band: "yellow", resolvedAt: now),
            generatedAt: now
        )
        try store.write(snapshot)
        let restored = try #require(store.read())
        #expect(restored.healthScore?.score == 73)
        #expect(restored.healthScore?.band == "yellow")
    }

    // MARK: - v0.15 companion-#3 — latest-measurement glance

    @Test("LatestMeasurement formats a scalar through the descriptor")
    func latestMeasurementScalarMaps() throws {
        let m = Measurement(
            id: "m1",
            kind: .weight,
            recordedAt: now,
            value: .scalar(72.43)
        )
        let latest = try #require(WidgetSnapshot.LatestMeasurement.make(from: m, units: .standard))
        #expect(latest.kindRaw == "weight")
        // decimal1, kg default — compare against the locale-formatted expectation
        // (the sim locale may use a comma decimal separator).
        #expect(latest.formattedValue == 72.4.formatted(.number.precision(.fractionLength(1))))
        #expect(latest.unit == "kg")
        #expect(latest.symbol == "scalemass")
        #expect(latest.recordedAt == now)
    }

    @Test("LatestMeasurement renders blood pressure as sys/dia")
    func latestMeasurementBloodPressureMaps() throws {
        let m = Measurement(
            id: "bp1",
            kind: .bloodPressure,
            recordedAt: now,
            value: .bloodPressure(systolic: 128, diastolic: 82)
        )
        let latest = try #require(WidgetSnapshot.LatestMeasurement.make(from: m, units: .standard))
        #expect(latest.formattedValue == "128/82")
        #expect(latest.unit == "mmHg")
    }

    @Test("LatestMeasurement honours the user's weight unit preference")
    func latestMeasurementUnitPreference() throws {
        let m = Measurement(id: "m2", kind: .weight, recordedAt: now, value: .scalar(80))
        let units = UnitPreferences(weight: .lb, bloodPressure: .mmHg, glucose: .mgdL)
        let latest = try #require(WidgetSnapshot.LatestMeasurement.make(from: m, units: units))
        // 80 kg → ~176.4 lb, one decimal (locale-tolerant separator).
        let expected = units.convertWeight(80).formatted(.number.precision(.fractionLength(1)))
        #expect(latest.formattedValue == expected)
        #expect(latest.unit == "lb")
    }

    @Test("nil measurement yields a nil glance")
    func latestMeasurementNilPassthrough() {
        #expect(WidgetSnapshot.LatestMeasurement.make(from: nil) == nil)
    }

    @Test("The latest-measurement glance round-trips through the store")
    func latestMeasurementRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("latest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WidgetSnapshotStore(url: url)
        let snapshot = WidgetSnapshot(
            nextDose: nil,
            compliance: .init(scheduled: 0, taken: 0),
            latestMeasurement: .init(
                kindRaw: "pulse",
                title: "Pulse",
                formattedValue: "61",
                unit: "bpm",
                symbol: "heart.fill",
                recordedAt: now
            ),
            generatedAt: now
        )
        try store.write(snapshot)
        let restored = try #require(store.read())
        #expect(restored.latestMeasurement?.formattedValue == "61")
        #expect(restored.latestMeasurement?.unit == "bpm")
    }

    @Test("A legacy snapshot (no score / measurement keys) decodes with nils")
    func legacySnapshotDecodesNilNewFields() throws {
        let legacy = """
        {"compliance":{"scheduled":2,"taken":1},"generatedAt":"2026-05-29T08:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.healthScore == nil)
        #expect(snapshot.latestMeasurement == nil)
    }
}
