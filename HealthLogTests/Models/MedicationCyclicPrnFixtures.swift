import Foundation
@testable import HealthLog
import Testing

/// Fixture loading and the two transcriptions the 09-14 contract suites compare
/// against. Kept beside the suites rather than inside one of them because both
/// suites read the same pinned bytes, and kept out of the suite types so a
/// `-only-testing` selector still names a suite that produces cases.
enum MedicationCyclicPrnFixtures {
    static let utc = TimeZone(identifier: "UTC") ?? .gmt
    /// A fixed instant so `infer`'s `now` fallback can never make a clause
    /// depend on the wall clock.
    static let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - The server's own cyclic rule, transcribed

    /// Verbatim transcription of `isInCyclicOnWeek`
    /// (`src/lib/medications/scheduling/recurrence.ts:236-253`) at the accepted
    /// tag `v1.37.24`. The anchor is the medication's `startsOn ?? createdAt`,
    /// snapped to the Sunday-rooted UTC week; the slot survives iff
    /// `phase < onWeeks`. Transcribed rather than paraphrased so the parity
    /// clause compares the iOS engine against the server's arithmetic instead
    /// of against a hand-written list of days that would have to be re-derived
    /// every time the fixture moved.
    static func serverCyclicOnWeek(_ instant: Date, anchor: Date, onWeeks: Int, offWeeks: Int) -> Bool {
        if onWeeks <= 0 { return true }
        let cycleLength = onWeeks + offWeeks
        if cycleLength <= 0 { return true }
        let anchorWeekStart = startOfUtcWeek(anchor)
        let instantWeekStart = startOfUtcWeek(instant)
        let weeksFromAnchor = Int((instantWeekStart.timeIntervalSince(anchorWeekStart) / (7 * 86400)).rounded())
        let phase = ((weeksFromAnchor % cycleLength) + cycleLength) % cycleLength
        return phase < onWeeks
    }

    /// `startOfUtcWeek` (same file, line 919): UTC midnight of `d`, rolled back
    /// to the preceding Sunday.
    static func startOfUtcWeek(_ date: Date) -> Date {
        let midnight = utcCalendar.startOfDay(for: date)
        let weekdayIndex = utcCalendar.component(.weekday, from: midnight) - 1
        return midnight.addingTimeInterval(-Double(weekdayIndex) * 86400)
    }

    static func utcDayKey(_ date: Date) -> String {
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    // MARK: - Write-path subjects

    /// A cyclic value with 3 weeks on and 1 week off, encoded through the same
    /// picker path the sheets use. Those two numbers are the picker's own
    /// defaults, so this helper never has to name the sub-control properties —
    /// which is deliberate: it keeps the clause compiling unchanged across a
    /// rename of the form-side vocabulary.
    static func buildCyclicSchedules() -> [MedicationScheduleDTO] {
        let sub = CadenceSubControls.makeDefault(now: fixedNow)
        let value = MedicationCadenceLogic.encode(.cyclic, sub, calendar: utcCalendar)
        return MedicationCadenceLogic.buildSchedules(
            value: value,
            times: [TimeOfDay(hour: 8, minute: 0)],
            graceMinutes: nil,
            calendar: utcCalendar
        )
    }

    /// An as-needed value. `maxTimes(for: .asNeeded)` is 0, so the sheets pass
    /// no times — mirrored here.
    static func buildAsNeededSchedules() -> [MedicationScheduleDTO] {
        let sub = CadenceSubControls.makeDefault(now: fixedNow)
        let value = MedicationCadenceLogic.encode(.asNeeded, sub, calendar: utcCalendar)
        return MedicationCadenceLogic.buildSchedules(
            value: value,
            times: [],
            graceMinutes: nil,
            calendar: utcCalendar
        )
    }

    /// The rows as they actually leave the device — encoded through
    /// `MedicationScheduleDTO.encode(to:)`, never read off the Swift value, so
    /// a key that exists on the type but not on the wire cannot pass.
    static func encodedRows(_ dtos: [MedicationScheduleDTO]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(dtos)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    static func text(_ data: Data) throws -> String {
        try #require(String(data: data, encoding: .utf8))
    }

    // MARK: - Pinned payloads

    static func cyclicMedication() throws -> MedicationWireDTO {
        try decode(MedicationWireDTO.self, from: "cyclicMedication")
    }

    static func prnMedication() throws -> MedicationWireDTO {
        try decode(MedicationWireDTO.self, from: "prnMedication")
    }

    static func decodeLegacyCachedSchedule() throws -> MedicationSchedule {
        try decode(MedicationSchedule.self, from: "legacyCachedSchedule")
    }

    static func decodeLegacyOutboxCreate() throws -> MedicationsRepository.MedicationCreate {
        try decode(MedicationsRepository.MedicationCreate.self, from: "legacyOutboxCreate")
    }

    private static func decode<T: Decodable>(_ type: T.Type, from key: String) throws -> T {
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL("cyclic-prn-payloads.json")))
                as? [String: Any]
        )
        let payload = try #require(root[key])
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder.hlDefault.decode(type, from: data)
    }

    // MARK: - The extract is an extract

    /// Census the pinned OpenAPI extract: every property declaration at exactly
    /// eight spaces of indentation must be one of the names this plan
    /// implements against, so a fifth shape cannot be smuggled into the fixture
    /// later and quietly become "the contract".
    static func checkPinnedPropertyCensus(into violations: inout [String]) throws {
        let expected: Set = ["scheduleType", "cyclicOnWeeks", "cyclicOffWeeks", "asNeeded", "schedules"]
        let yaml = try String(contentsOf: fixtureURL("openapi-cyclic-prn.yaml"), encoding: .utf8)
        var found: Set<String> = []
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            guard raw.hasPrefix("        "), !raw.hasPrefix("         "), raw.hasSuffix(":") else { continue }
            found.insert(String(raw.dropFirst(8).dropLast()))
        }
        if found != expected {
            violations.append(
                "the pinned OpenAPI extract declares \(found.sorted()), expected exactly \(expected.sorted())"
            )
        }
    }

    private static func fixtureURL(_ name: String, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Models
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("HealthLogTests/Fixtures/ServerContracts/v1.37.24/\(name)")
    }
}
