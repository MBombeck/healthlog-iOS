import Foundation
@testable import HealthLog
import Testing

/// **09-14 — the accepted v1.37.24 cyclic / PRN wire contract, both directions.**
///
/// Pinned to the immutable tag `v1.37.24` (commit
/// `e00d013459d88bb8be4b197138cf72da489c1645`) whose `docs/api/openapi.yaml`
/// hashes to `355d1f145b8c03b3c714ac6c21bc454865bcc329389216f957d9579e0d8fabb8`
/// and was read twice over independent transports. The fixtures under
/// `HealthLogTests/Fixtures/ServerContracts/v1.37.24/` carry that tag's bytes;
/// this file reads only them.
///
/// The defect these suites pin is a **release blocker with user impact**, and it
/// is bidirectional:
///
/// - **Read.** `MedicationScheduleOutput` publishes `cyclicOnWeeks` /
///   `cyclicOffWeeks` (required) and no anchor at all. iOS decoded
///   `cycleWeeksOn` / `cycleWeeksOff` / `cycleAnchor` — three strings that
///   appear **zero** times in the accepted 44,337-line file — so
///   `cyclicCadence(from:)` could never satisfy its own guard and every CYCLIC
///   schedule fell through to rolling / rrule / legacy.
/// - **Write.** `MedicationScheduleInput` declares neither `cycleAnchor` nor a
///   schedule-level `asNeeded`, and the cyclic pair is "ignored otherwise"
///   without `scheduleType: CYCLIC`. iOS emitted the undeclared keys and never
///   the discriminator, so a Zod-stripped body created a plain SCHEDULED row —
///   and a PRN medication became a fixed daily plan that reminds and is scored.
///
/// **The anchor is not renamed, it is deleted.** The server anchors the cyclic
/// phase on `medication.startsOn ?? medication.createdAt`, snapped to the
/// Sunday-rooted UTC week (`src/lib/medications/scheduling/recurrence.ts:246`
/// at the accepted tag). There is no per-schedule anchor and there is nowhere
/// on the server to put one. `serverCyclicOnWeek` below is a transcription of
/// that function, and the parity clause asserts the iOS engine agrees with it
/// rather than asserting a hand-written list of days.
///
/// Every clause reads its subject through JSON, through `String(describing:)`
/// or through `Mirror` — never through a property or an enum arity that
/// changes — so the RED is behavioural, compiles unchanged before and after,
/// and keeps meaning the same thing.
@Suite("Medication cyclic wire v1.37.24")
struct MedicationCyclicWireContractTests {
    @Test("A CYCLIC schedule survives the accepted wire shape in both directions")
    func cyclicSurvivesTheAcceptedWireShape() throws {
        var violations: [String] = []
        try checkPublishedCyclicDecodes(into: &violations)
        try checkCyclicPhaseMatchesTheServer(into: &violations)
        try checkCyclicWriteUsesAcceptedKeys(into: &violations)
        try checkPreFixShapesMigrate(into: &violations)
        try MedicationCyclicPrnFixtures.checkPinnedPropertyCensus(into: &violations)

        #expect(
            violations.isEmpty,
            "EXPECTED_RED: the accepted cyclic wire shape does not survive iOS — \(violations.count) violation(s): \(violations.joined(separator: " | "))"
        )
    }

    // MARK: - Read

    private func checkPublishedCyclicDecodes(into violations: inout [String]) throws {
        let medication = try MedicationCyclicPrnFixtures.cyclicMedication().toDomain()
        guard let entry = medication.schedule.entries.first else {
            violations.append("the published CYCLIC medication decoded to zero schedule entries")
            return
        }
        let label = String(describing: entry.cadence)
        if !label.hasPrefix("cyclic(") {
            violations.append("published scheduleType=CYCLIC decoded as \(label), not a cyclic cadence")
        }
        if !label.contains("weeksOn: 3") {
            violations.append("cyclicOnWeeks 3 did not reach the cadence (got \(label))")
        }
        if !label.contains("weeksOff: 1") {
            violations.append("cyclicOffWeeks 1 did not reach the cadence (got \(label))")
        }
        if label.contains("anchor") {
            violations.append("the cadence still carries a per-schedule anchor the server cannot store (got \(label))")
        }
    }

    private func checkCyclicPhaseMatchesTheServer(into violations: inout [String]) throws {
        let medication = try MedicationCyclicPrnFixtures.cyclicMedication().toDomain()
        guard let entry = medication.schedule.entries.first,
              let anchor = medication.startsOn ?? medication.createdAt else
        {
            violations.append("the published CYCLIC medication carries no entry or no startsOn/createdAt anchor")
            return
        }
        let context = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: MedicationCyclicPrnFixtures.utc,
            now: anchor
        )
        // Six whole cycles' worth of days, and the range runs to the END of the
        // last one: a range that stops at the last day's midnight excludes that
        // day's 08:00 slot and would report a phase disagreement that is only a
        // boundary artefact of the query.
        let end = anchor.addingTimeInterval(42 * 86400 - 1)
        let fired = Set(
            MedicationRecurrenceEngine
                .occurrences(in: anchor ... end, entry: entry, context: context)
                .map { MedicationCyclicPrnFixtures.utcDayKey($0.at) }
        )
        for offset in 0 ... 41 {
            let day = anchor.addingTimeInterval(Double(offset) * 86400)
            let serverSaysOn = MedicationCyclicPrnFixtures.serverCyclicOnWeek(
                day, anchor: anchor, onWeeks: 3, offWeeks: 1
            )
            let iosFired = fired.contains(MedicationCyclicPrnFixtures.utcDayKey(day))
            if serverSaysOn != iosFired {
                violations.append(
                    "day +\(offset) (\(MedicationCyclicPrnFixtures.utcDayKey(day))): server says on-week=\(serverSaysOn), iOS fired=\(iosFired)"
                )
            }
        }
    }

    // MARK: - Write

    private func checkCyclicWriteUsesAcceptedKeys(into violations: inout [String]) throws {
        let rows = try MedicationCyclicPrnFixtures.encodedRows(
            MedicationCyclicPrnFixtures.buildCyclicSchedules()
        )
        guard let row = rows.first else {
            violations.append("a cyclic rebuild emitted no schedule row at all")
            return
        }
        for dead in ["cycleWeeksOn", "cycleWeeksOff", "cycleAnchor"] where row[dead] != nil {
            violations.append("a cyclic write still emits `\(dead)`, which appears zero times in the accepted contract")
        }
        if row["scheduleType"] as? String != "CYCLIC" {
            violations.append(
                "a cyclic write does not carry `scheduleType: CYCLIC`, so the accepted schema ignores the cyclic pair"
            )
        }
        if (row["cyclicOnWeeks"] as? Int) != 3 {
            violations.append("a cyclic write does not carry `cyclicOnWeeks: 3`")
        }
        if (row["cyclicOffWeeks"] as? Int) != 1 {
            violations.append("a cyclic write does not carry `cyclicOffWeeks: 1`")
        }
    }

    // MARK: - Update path

    private func checkPreFixShapesMigrate(into violations: inout [String]) throws {
        let cached = try MedicationCyclicPrnFixtures.decodeLegacyCachedSchedule()
        let label = cached.entries.first.map { String(describing: $0.cadence) } ?? "<no entry>"
        if !label.hasPrefix("cyclic(") || !label.contains("weeksOn: 3") || !label.contains("weeksOff: 1") {
            violations.append("a pre-fix cached cyclic blob no longer decodes to its on/off weeks (got \(label))")
        }
        let reEncoded = try MedicationCyclicPrnFixtures.text(JSONEncoder.hlDefault.encode(cached))
        if reEncoded.contains("\"anchor\"") {
            violations.append("re-encoding a pre-fix cached blob writes the removed `anchor` back as if it were a user choice")
        }

        let queued = try MedicationCyclicPrnFixtures.decodeLegacyOutboxCreate()
        let replayed = try MedicationCyclicPrnFixtures.text(JSONEncoder().encode(queued))
        for dead in ["cycleWeeksOn", "cycleWeeksOff", "cycleAnchor"] where replayed.contains("\"\(dead)\"") {
            violations.append("replaying a pre-fix queued create still writes `\(dead)`")
        }
    }
}

/// **09-14 — an as-needed medication is saved as PRN and reads back as PRN.**
///
/// The accepted `CreateMedicationRequest` / `UpdateMedicationRequest` spell a
/// whole-medication PRN as the medication-level `asNeeded: true` with an empty
/// `schedules` array, and the invariant runs both ways: any schedule entry
/// alongside the flag is a 422, and an empty array without the flag is a 422.
/// The reference client's own payload builder makes the same split — an
/// as-needed slot beside scheduled ones rides a `scheduleType: PRN` row, while
/// an entirely as-needed medication "only flips the WHOLE-medication `asNeeded`
/// flag (zero schedules, never due / scored)". iOS carries one `CadenceKind`
/// per medication, so `.asNeeded` on iOS is always the whole-medication case.
///
/// Until this suite is green, a PRN medication saved from iOS is created as a
/// plain SCHEDULED row that the route defaults to `FREQ=DAILY` — it acquires
/// reminders and a daily compliance expectation the user never asked for.
@Suite("Medication PRN round trip v1.37.24")
struct MedicationPrnRoundTripContractTests {
    @Test("An as-needed medication is written and read back as PRN")
    func asNeededMedicationsRoundTripAsPrn() throws {
        var violations: [String] = []
        try checkPrnWriteShape(into: &violations)
        checkPrnCanBeExpressedOnAnUpdate(into: &violations)
        try checkPrnReadsBackAsPrn(into: &violations)

        #expect(
            violations.isEmpty,
            "EXPECTED_RED: an as-needed medication does not round-trip as PRN — \(violations.count) violation(s): \(violations.joined(separator: " | "))"
        )
    }

    private func checkPrnWriteShape(into violations: inout [String]) throws {
        let rows = try MedicationCyclicPrnFixtures.encodedRows(
            MedicationCyclicPrnFixtures.buildAsNeededSchedules()
        )
        if !rows.isEmpty {
            violations.append(
                "an as-needed save emits \(rows.count) schedule row(s); the accepted contract 422s any entry alongside `asNeeded: true`"
            )
        }
        for row in rows where row["asNeeded"] != nil {
            violations.append("an as-needed save still emits a schedule-level `asNeeded`, which the input schema does not declare")
        }
    }

    private func checkPrnCanBeExpressedOnAnUpdate(into violations: inout [String]) {
        let patch = MedicationsRepository.MedicationPatch()
        let carriesFlag = Mirror(reflecting: patch).children.contains { $0.label == "asNeeded" }
        if !carriesFlag {
            violations.append("MedicationPatch carries no `asNeeded`, so no edit can make a medication PRN or clear its plan")
        }
    }

    private func checkPrnReadsBackAsPrn(into violations: inout [String]) throws {
        let dto = try MedicationCyclicPrnFixtures.prnMedication()
        let carriesFlag = Mirror(reflecting: dto).children.contains { $0.label == "asNeeded" }
        if !carriesFlag {
            violations.append("MedicationWireDTO does not decode the published medication-level `asNeeded`")
        }
        let inferred = MedicationCadenceLogic.infer(
            from: dto.toDomain(),
            now: MedicationCyclicPrnFixtures.fixedNow
        )
        if inferred.kind != .asNeeded {
            violations.append(
                "a published PRN medication (asNeeded: true, schedules: []) re-selects `\(inferred.kind)` in the edit form, not `asNeeded`"
            )
        }
    }
}
