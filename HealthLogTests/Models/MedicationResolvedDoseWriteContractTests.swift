import Foundation
@testable import HealthLog
import Testing

/// **08-21 — the raw half of the v1.37.19 medication contract, at the edit /
/// read-modify-write boundary.**
///
/// 08-17 separated the two per-slot doses at the model boundary and 08-20 gave
/// the medication-level aggregates their display consumers. What was left is
/// the half that *writes*: `MedicationScheduleDTO` is simultaneously the read
/// row and the payload of every `schedules` REPLACE, so a schedule edit is a
/// read-modify-write over decoded server rows, and anything the rebuild fails
/// to carry is deleted server-side rather than left alone.
///
/// Three separations are load-bearing here and each has its own clause:
///
/// 1. **raw is the only half that may travel.**
///    `MedicationScheduleDTO.unitsPerDose` is the user's per-slot edit intent;
///    `resolvedUnitsPerDose` is the server's effective answer and is kept off
///    the wire by the hand-written `encode(to:)`. Nothing on this side may
///    derive one from the other, in either direction.
/// 2. **untouched is not the same as cleared.** A slot the user never opened
///    must come back with the override it had. A slot the user set back to
///    "inherit" must come back without one. Both are expressible only if the
///    form carries a tri-state; a plain `Double?` collapses them.
/// 3. **the resolved figure needs a reader.** ROUTE-06 asks for the published
///    truth to be consumed end to end. Two of its three fields are read by the
///    supply surfaces (08-20); `ScheduleEntry.resolvedUnitsPerDose` is per-slot
///    and belongs to the surface that edits slots.
///
/// The form-state reads go through `Mirror` for 08-17's reason: a clause
/// written as `state.slotUnitsPerDose["20:00"]` cannot compile before the
/// property exists, and `assert-behavioral-red.sh` refuses a build failure as
/// not-behavioural. The probe asks the constructed value, so the same clause
/// means the same thing on both sides of the change.
@Suite("Medication raw RMW")
struct MedicationResolvedDoseWriteContractTests {
    // MARK: - Reflective probes

    /// A `[String: Double]` property read by name off a constructed value.
    /// `nil` when the property does not exist (or does not carry that shape),
    /// which is a different finding from "it exists and is empty".
    static func doseMap(_ subject: Any, _ field: String) -> [String: Double]? {
        for child in Mirror(reflecting: subject).children where child.label == field {
            return child.value as? [String: Double]
        }
        return nil
    }

    /// Every stored-property name of a constructed value.
    static func propertyNames(_ subject: Any) -> [String] {
        Mirror(reflecting: subject).children.compactMap(\.label)
    }

    /// The rows a save would build for this form state under the given intents,
    /// plus the JSON the PUT would actually carry. Mirrors `EditMedicationSheet.save()`
    /// so the assertions are about the shipped path and not a parallel one.
    static func rows(
        state: EditMedicationFormState,
        value: CadenceValue,
        intents: MedicationCadenceLogic.SlotDoseIntents
    ) throws -> (rows: [MedicationScheduleDTO], body: String) {
        let rows = MedicationCadenceLogic.buildSchedules(
            value: value,
            times: state.cadenceKind == .asNeeded ? [] : state.times,
            graceMinutes: state.graceMinutes,
            slotUnitsPerDose: MedicationCadenceLogic.resolveSlotUnitsPerDose(
                existing: state.slotUnitsPerDose,
                intents: intents
            )
        )
        let data = try JSONEncoder().encode(MedicationsRepository.MedicationPatch(schedules: rows))
        let body = try #require(String(data: data, encoding: .utf8))
        return (rows, body)
    }

    /// The tracked Swift files of the medications screen tree, comment-stripped.
    /// Deliberately excludes `HealthLogTests`: the clause below asserts that a
    /// *production* surface reads the resolved figure, and a search that could
    /// be satisfied by the test proving it is not a policy (08-20's finding).
    static func medicationScreenSources() throws -> [(path: String, source: String)] {
        let directory = "HealthLog/Screens/Medications"
        let root = Phase8SourceScan.repositoryRoot.appendingPathComponent(directory)
        let names = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        var sources: [(path: String, source: String)] = []
        for name in names {
            let path = "\(directory)/\(name)"
            let source = try Phase8SourceScan.stripped(path)
            sources.append((path: path, source: source))
        }
        return sources
    }

    // MARK: - RED — raw overrides survive the rebuild, resolved truth gets a reader

    /// The two-slot fixture is the whole point: its morning slot inherits
    /// (raw `null`, resolved `1`) and its evening slot overrides (raw `0.5`,
    /// resolved `0.5`). A rebuild that cannot tell those apart either deletes
    /// the ½ the user chose or promotes the morning slot's inheritance into an
    /// override nobody asked for, and both are silent.
    @Test("Raw per-slot doses reach the edit form, survive a rebuild, and the resolved figure has a reader")
    func rawSlotDosesSurviveTheRebuild() throws {
        var violations: [String] = []

        let medication = try MedicationServerTruthDecodeTests.wire("slotAwareTruth").toDomain()
        let state = EditMedicationFormState(from: medication)

        // 1. Every server slot's dose time has to reach the form. `schedules`
        //    is a REPLACE, so a time the form never saw is a row the next save
        //    deletes — together with its label, its grace and its raw dose.
        let formTimes = Set(state.times.map(MedicationFormLogic.formatTime))
        for slot in ["08:00", "20:00"] where !formTimes.contains(slot) {
            violations.append("the edit form drops the \(slot) slot, so the next schedule save deletes it")
        }

        // 2. The raw override has to arrive as the raw override.
        if let raw = Self.doseMap(state, "slotUnitsPerDose") {
            if raw["20:00"] != 0.5 {
                let arrived = raw["20:00"].map { "\($0)" } ?? "absent"
                violations.append("the evening slot's raw ½ arrives as \(arrived)")
            }
            if raw["08:00"] != nil {
                violations.append("the inheriting morning slot arrives with an invented override")
            }
        } else {
            violations.append("EditMedicationFormState carries no raw per-slot unitsPerDose at all")
        }

        // 3. The server-effective figure has to arrive too, read rather than
        //    re-derived — this is ROUTE-06's third field getting a reader.
        if let effective = Self.doseMap(state, "serverEffectiveUnitsPerDose") {
            if effective["08:00"] != 1 || effective["20:00"] != 0.5 {
                violations.append("the server-resolved slot doses are \(effective), expected 08:00 → 1 and 20:00 → ½")
            }
        } else {
            violations.append("EditMedicationFormState carries no server-resolved per-slot dose for any surface to read")
        }

        // 4. The rebuild itself must take the raw doses as an input. Without
        //    one, every rebuilt row is created with `unitsPerDose` NULL and the
        //    server resolves the medication-level value for every slot.
        let logic = try Phase8SourceScan.stripped("HealthLog/Screens/Medications/MedicationCadenceLogic.swift")
        let builder = Phase8SourceScan.member(named: "static func buildSchedules(", in: logic)
        if let builder {
            if !builder.contains("unitsPerDose") {
                violations.append("buildSchedules takes no per-slot unitsPerDose, so a rebuild clears every override")
            }
        } else {
            violations.append("buildSchedules no longer declares itself — restate this contract")
        }

        // 5. A slot-only change has to count as a schedule change, or the PUT
        //    omits `schedules` entirely and the edit is silently discarded.
        let snapshot = MedicationCadenceLogic.ScheduleSnapshot(
            cadenceKind: .daily,
            cadenceSub: .makeDefault(),
            times: [TimeOfDay(hour: 8, minute: 0)],
            startsOn: nil,
            endsOn: nil,
            isOneShot: false,
            graceMinutes: nil
        )
        if !Self.propertyNames(snapshot).contains(where: { $0.localizedCaseInsensitiveContains("unitsPerDose") }) {
            violations.append("ScheduleSnapshot ignores the per-slot doses, so changing one alone sends no schedules")
        }

        // 6. ROUTE-06's reader has to exist in production, not in this file.
        let readers = try Self.medicationScreenSources()
            .filter { $0.source.contains("resolvedUnitsPerDose") }
            .map(\.path)
        if readers.isEmpty {
            violations.append("no file under HealthLog/Screens/Medications reads ScheduleEntry.resolvedUnitsPerDose")
        }

        #expect(
            violations.isEmpty,
            "EXPECTED_RED: raw overrides are lost or resolved values are written — \(violations)"
        )
    }

    // MARK: - The typed surface the RED could not name

    /// The tri-state, exercised end to end on the accepted two-slot fixture and
    /// read as the wire body a save actually sends. The three cases have to
    /// produce three different bodies, or the middle one is not a state.
    @Test("Untouched, cleared and explicitly set slots each produce their own write body")
    func theTriStateProducesThreeDifferentBodies() throws {
        let medication = try MedicationServerTruthDecodeTests.wire("slotAwareTruth").toDomain()
        let state = EditMedicationFormState(from: medication)
        let value = MedicationCadenceLogic.encode(state.cadenceKind, state.cadenceSub)

        // 1. Untouched — the ½ the user set on the web survives, and the
        //    inheriting morning slot stays inheriting. The slots disagree, so
        //    the rebuild adopts the server's own one-row-per-slot shape.
        let untouched = try Self.rows(state: state, value: value, intents: [:])
        #expect(untouched.rows.count == 2)
        #expect(untouched.rows[0].timesOfDay == ["08:00"])
        #expect(untouched.rows[0].unitsPerDose == nil)
        #expect(untouched.rows[1].timesOfDay == ["20:00"])
        #expect(untouched.rows[1].unitsPerDose == 0.5)
        #expect(untouched.body.contains("\"unitsPerDose\":0.5"))

        // 2. Cleared — the user chose inheritance for the evening slot. Both
        //    slots now inherit, so the historical single combined row is back
        //    and it names no `unitsPerDose` at all. Omission IS the clear: the
        //    accepted `MedicationScheduleInput.unitsPerDose` is a bare
        //    `type: number` whose description reads "Omitted / NULL means the
        //    schedule inherits `Medication.unitsPerDose`".
        let cleared = try Self.rows(state: state, value: value, intents: ["20:00": .clear])
        #expect(cleared.rows.count == 1)
        #expect(cleared.rows[0].timesOfDay == ["08:00", "20:00"])
        #expect(cleared.rows[0].unitsPerDose == nil)
        #expect(!cleared.body.contains("unitsPerDose"))

        // 3. Explicitly set — a ¼ on the morning slot travels verbatim and does
        //    not disturb the evening slot's untouched ½.
        let set = try Self.rows(state: state, value: value, intents: ["08:00": .set(0.25)])
        #expect(set.rows.count == 2)
        #expect(set.rows[0].unitsPerDose == 0.25)
        #expect(set.rows[1].unitsPerDose == 0.5)
        #expect(set.body.contains("\"unitsPerDose\":0.25"))
        #expect(set.body.contains("\"unitsPerDose\":0.5"))

        // None of the three ever carries the server's own answer.
        for body in [untouched.body, cleared.body, set.body] {
            #expect(!body.contains("resolvedUnitsPerDose"))
        }
    }

    /// The resolved figure is a reader's value, never a writer's default. The
    /// morning slot resolves to `1` server-side and has NO raw override; a
    /// rebuild that used the resolved map as a fallback would write `1` and
    /// convert inheritance into an explicit override on the first unrelated
    /// schedule edit — silently, and permanently.
    @Test("A resolved dose is never promoted into a raw override")
    func resolvedIsNeverPromotedIntoARawOverride() throws {
        let medication = try MedicationServerTruthDecodeTests.wire("slotAwareTruth").toDomain()
        let state = EditMedicationFormState(from: medication)
        #expect(state.serverEffectiveUnitsPerDose["08:00"] == 1)
        #expect(state.slotUnitsPerDose["08:00"] == nil)

        let value = MedicationCadenceLogic.encode(state.cadenceKind, state.cadenceSub)
        let rebuilt = try Self.rows(state: state, value: value, intents: [:])
        let morning = try #require(rebuilt.rows.first { $0.timesOfDay == ["08:00"] })
        #expect(morning.unitsPerDose == nil, "the inheriting slot must stay inheriting")

        // The one-slot fixtures resolve to a figure too (1 and 2) and neither
        // may reach the raw map either.
        for scenario in ["trackingOff", "exhausted"] {
            let single = try MedicationServerTruthDecodeTests.wire(scenario).toDomain()
            let singleState = EditMedicationFormState(from: single)
            #expect(singleState.slotUnitsPerDose.isEmpty, "\(scenario) invented a raw override")
            #expect(!singleState.serverEffectiveUnitsPerDose.isEmpty, "\(scenario) lost the resolved figure")
        }
    }

    /// A medication whose slots all agree keeps the exact single-row shape iOS
    /// has always written — the fan-out is a last resort for slots that cannot
    /// be expressed as one row, not a new default.
    @Test("Agreeing slots keep the historical single combined row")
    func agreeingSlotsKeepTheSingleRow() {
        let value = MedicationCadenceLogic.encode(.daily, .makeDefault())
        let times = [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)]

        let noOverrides = MedicationCadenceLogic.buildSchedules(
            value: value, times: times, graceMinutes: nil
        )
        #expect(noOverrides.count == 1)
        #expect(noOverrides[0].timesOfDay == ["08:00", "20:00"])
        #expect(noOverrides[0].unitsPerDose == nil)

        let sameOverride = MedicationCadenceLogic.buildSchedules(
            value: value,
            times: times,
            graceMinutes: nil,
            slotUnitsPerDose: ["08:00": 0.5, "20:00": 0.5]
        )
        #expect(sameOverride.count == 1)
        #expect(sameOverride[0].unitsPerDose == 0.5)
        #expect(sameOverride[0].timesOfDay == ["08:00", "20:00"])
    }

    /// A slot the form never saw is a row the REPLACE deletes. The union prefill
    /// is what keeps the evening dose — and everything hanging off it — alive.
    @Test("Every server slot reaches the form and survives an unrelated edit")
    func everyServerSlotSurvivesAnUnrelatedEdit() throws {
        let medication = try MedicationServerTruthDecodeTests.wire("slotAwareTruth").toDomain()
        let state = EditMedicationFormState(from: medication)
        #expect(state.times == [TimeOfDay(hour: 8, minute: 0), TimeOfDay(hour: 20, minute: 0)])

        // An unrelated edit (the grace window) still rebuilds `schedules`, and
        // both slots plus the raw ½ have to come out the other side.
        let value = MedicationCadenceLogic.encode(state.cadenceKind, state.cadenceSub)
        let rebuilt = MedicationCadenceLogic.buildSchedules(
            value: value,
            times: state.times,
            graceMinutes: 90,
            slotUnitsPerDose: MedicationCadenceLogic.resolveSlotUnitsPerDose(
                existing: state.slotUnitsPerDose, intents: [:]
            )
        )
        #expect(rebuilt.flatMap { $0.timesOfDay ?? [] } == ["08:00", "20:00"])
        #expect(rebuilt.compactMap(\.unitsPerDose) == [0.5])
        #expect(rebuilt.allSatisfy { $0.reminderGraceMinutes == 90 })
    }

    /// A slot-dose-only edit changes nothing else in the form, so without the
    /// snapshot carrying the doses the PUT would omit `schedules` and discard it.
    @Test("Changing only a slot dose is a schedule change")
    func slotDoseOnlyEditRebuildsSchedules() {
        let base = MedicationCadenceLogic.ScheduleSnapshot(
            cadenceKind: .daily,
            cadenceSub: .makeDefault(),
            times: [TimeOfDay(hour: 8, minute: 0)],
            startsOn: nil,
            endsOn: nil,
            isOneShot: false,
            graceMinutes: nil,
            slotUnitsPerDose: [:]
        )
        var changed = base
        changed.slotUnitsPerDose = ["08:00": 0.5]
        #expect(MedicationCadenceLogic.scheduleDidChange(baseline: base, current: changed))
        #expect(!MedicationCadenceLogic.scheduleDidChange(baseline: base, current: base))

        // …and clearing an override back to what it already was is not a change.
        let resolved = MedicationCadenceLogic.resolveSlotUnitsPerDose(
            existing: [:], intents: ["08:00": .clear]
        )
        var cleared = base
        cleared.slotUnitsPerDose = resolved
        #expect(!MedicationCadenceLogic.scheduleDidChange(baseline: base, current: cleared))
    }

    // MARK: - Preservation — the write boundary, which already holds

    /// 08-17 put the guard at the type rather than at the call sites, and this
    /// plan opens the biggest call site there is. The clause re-states the
    /// boundary from decoded rows (so the field really is populated) through
    /// both write bodies, and pins that the raw half still travels — a guard
    /// that dropped both halves would be trivially "safe" and useless.
    @Test("Server-computed truth never enters a create or update body, and the raw half still does")
    func resolvedTruthNeverEntersAWriteBody() throws {
        let slotAware = try MedicationServerTruthDecodeTests.wire("slotAwareTruth")
        let schedules = try #require(slotAware.schedules)
        let encoder = JSONEncoder()
        let bodies: [(String, Data)] = try [
            ("schedules", encoder.encode(schedules)),
            ("create", encoder.encode(MedicationsRepository.MedicationCreate(
                name: "Metformin", dose: "1000 mg", unitsPerDose: 1, schedules: schedules
            ))),
            ("patch", encoder.encode(MedicationsRepository.MedicationPatch(schedules: schedules)))
        ]
        for (name, data) in bodies {
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(!text.contains("resolvedUnitsPerDose"), "\(name) body leaks the server-resolved dose")
            #expect(!text.contains("stockDosesRemaining"), "\(name) body leaks aggregated stock")
            #expect(!text.contains("runwayDays"), "\(name) body leaks the computed runway")
            #expect(text.contains("\"unitsPerDose\":0.5"), "\(name) body dropped the raw per-slot override")
        }
    }
}
