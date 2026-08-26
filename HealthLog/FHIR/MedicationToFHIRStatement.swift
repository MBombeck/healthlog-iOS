//
//  MedicationToFHIRStatement.swift
//  HealthLog (iOS-only — imports ModelsR4 via SpeziFHIR)
//
//  Created 2026-05-22 — v0.6.0 H.3 Medication → FHIR R4 MedicationStatement
//  mapper. Pairs with `MeasurementToFHIRObservation` (H.2) so the H.4
//  bundle builder can fold Observations + MedicationStatements into one
//  transaction Bundle keyed by `Patient.id`.
//
//  Why iOS-only (and **not** `HealthLogCore`):
//  Same reason as `MeasurementToFHIRObservation` — `ModelsR4` ships via
//  `apple/FHIRModels` which is pulled in transitively through SpeziFHIR.
//  SpeziFHIR is iOS-targeted; the mapper cannot compile under the
//  plattformfrei `HealthLogCore` SPM target.
//
//  Domain → FHIR field map (per v060-research.md spec):
//
//      Medication.id           → identifier[0].value
//      Medication.name         → medication.codeableConcept.text
//                                (RxNorm coding omitted — operator hasn't
//                                keyed RxNorm mappings; folded in via H.5
//                                if/when the table lands).
//      archivedAt == nil       → status = .active
//      archivedAt != nil       → status = .completed
//                              + effectivePeriod.end = archivedAt
//      subject                 → Reference("Patient/<patientID>")
//      schedule.times          → dosage[0].timing.repeat.timeOfDay
//      schedule.times.count    → dosage[0].timing.repeat.frequency
//      schedule.weekdays       → dosage[0].timing.repeat.dayOfWeek
//      schedule.intervalWeeks  → period + periodUnit (.d), see notes
//      dose: "5 mg"            → dosage[0].doseAndRate[0].dose.quantity
//
//  Why ONE Dosage instance (not one per time):
//  FHIR R4 Dosage with `timing.repeat.timeOfDay = [t1, t2, …]` already
//  encodes multi-dose-per-day. Splitting into N Dosages would imply N
//  distinct prescribed regimens which is **not** the user intent for a
//  "twice-daily 5 mg" medication. Per FHIR best-practice (Dosage spec
//  §timing.repeat.timeOfDay) the array shape is canonical.
//
//  Period encoding for intervalWeeks:
//  - `intervalWeeks ≤ 1`: `period = 1`, `periodUnit = .d` (daily).
//  - `intervalWeeks > 1`: `period = intervalWeeks * 7`, `periodUnit = .d`.
//    (Days, not weeks, because FHIR `periodUnit` expects UCUM time codes
//     and the most clinician-readable encoding for "every 2 weeks" is
//     `period: 14, periodUnit: d`.)
//
//  Period.start is **omitted** because the domain `Medication` does not
//  carry a `startedAt` / `createdAt` field on the wire (server's
//  `/api/medications` endpoint never emitted one — see
//  `Models/Medication.swift` for the verified shape). Without a server
//  source we choose to leave the field unset rather than synthesise a
//  fake start date from `lastTakenAt` (which is *intake* time, not
//  *regimen-start* time).
//

import Foundation
import ModelsR4

/// Maps a domain `Medication` to a FHIR R4 `ModelsR4.MedicationStatement`.
enum MedicationToFHIRStatement {
    /// UCUM code-system URI (FHIR-canonical, required for `Quantity.system`).
    private static let ucumSystemURI = "http://unitsofmeasure.org"

    /// Maps the given medication to a FHIR R4 `MedicationStatement`.
    ///
    /// - Parameters:
    ///   - medication: the domain medication (with schedule).
    ///   - patientID: the FHIR `Patient.id` to reference from
    ///     `MedicationStatement.subject` (`"Patient/<patientID>"`).
    /// - Returns: a populated `MedicationStatement`.
    static func map(_ medication: Medication, patientID: String) -> MedicationStatement {
        let statement = MedicationStatement(
            medication: .codeableConcept(makeMedicationConcept(name: medication.name)),
            status: makeStatus(archivedAt: medication.archivedAt).asPrimitive(),
            subject: Reference(reference: FHIRString("Patient/\(patientID)").asPrimitive())
        )

        // Identifier — surface the domain id so a round-trip can correlate
        // back to the source medication row.
        let identifier = Identifier()
        identifier.value = FHIRString(medication.id).asPrimitive()
        statement.identifier = [identifier]

        // effectivePeriod: only emit when we have an archive timestamp.
        // Skipping the whole field for active meds avoids encoding an empty
        // Period — FHIR validators flag period with neither start nor end.
        if let archivedAt = medication.archivedAt {
            let period = Period()
            period.end = makeDateTime(from: archivedAt).asPrimitive()
            statement.effective = .period(period)
        }

        // Dosage — one entry per medication regimen (see file-header
        // rationale for the single-Dosage decision).
        statement.dosage = [makeDosage(medication: medication)]

        return statement
    }

    // MARK: - Status

    private static func makeStatus(archivedAt: Date?) -> MedicationStatementStatusCodes {
        archivedAt == nil ? .active : .completed
    }

    // MARK: - Medication concept

    private static func makeMedicationConcept(name: String) -> CodeableConcept {
        let concept = CodeableConcept()
        concept.text = FHIRString(name).asPrimitive()
        return concept
    }

    // MARK: - Dosage

    private static func makeDosage(medication: Medication) -> Dosage {
        let dosage = Dosage()

        // Free-text dose surface ("5 mg twice daily" etc.). FHIR servers
        // that don't parse `doseAndRate.dose.quantity` can still render
        // the human-readable string. Defaults to the raw `medication.dose`
        // so the operator sees the same label they typed in.
        if !medication.dose.isEmpty {
            dosage.text = FHIRString(medication.dose).asPrimitive()
        }

        // doseAndRate — only emitted when the parser recognises both
        // numeric value AND a known UCUM unit. "1 tablet" produces nil
        // and falls back to the `text` field only.
        if let quantity = parseDose(medication.dose) {
            let doseAndRate = DosageDoseAndRate()
            doseAndRate.dose = .quantity(quantity)
            dosage.doseAndRate = [doseAndRate]
        }

        dosage.timing = makeTiming(schedule: medication.schedule)

        return dosage
    }

    private static func makeTiming(schedule: MedicationSchedule) -> Timing {
        let timing = Timing()
        let repeatComp = TimingRepeat()

        // dayOfWeek — only when weekdays are restricted (nil == every day).
        if let weekdays = schedule.weekdays, !weekdays.isEmpty {
            // Sort by FHIR week-order (Mon → Sun) for deterministic output.
            let ordered = weekdays.sorted { lhs, rhs in
                fhirOrder(lhs) < fhirOrder(rhs)
            }
            repeatComp.dayOfWeek = ordered.map { fhirDay(for: $0).asPrimitive() }
        }

        // frequency: number of doses per period.
        if !schedule.times.isEmpty {
            let frequency = FHIRPositiveInteger(Int32(schedule.times.count))
            repeatComp.frequency = frequency.asPrimitive()
        }

        // period + periodUnit (always in days — see file header).
        let periodDays = schedule.intervalWeeks <= 1 ? 1 : schedule.intervalWeeks * 7
        repeatComp.period = FHIRDecimal(Decimal(periodDays)).asPrimitive()
        repeatComp.periodUnit = FHIRString("d").asPrimitive()

        // timeOfDay — explicit clock times per day.
        if !schedule.times.isEmpty {
            repeatComp.timeOfDay = schedule.times.map { makeFHIRTime(from: $0).asPrimitive() }
        }

        timing.repeat = repeatComp
        return timing
    }

    // MARK: - Weekday mapping (HealthLog → FHIR R4)

    /// Map our 0=Sun..6=Sat domain enum onto the FHIR R4 DaysOfWeek code
    /// (`mon/tue/wed/thu/fri/sat/sun`).
    private static func fhirDay(for weekday: Weekday) -> DaysOfWeek {
        switch weekday {
        case .sun: .sun
        case .mon: .mon
        case .tue: .tue
        case .wed: .wed
        case .thu: .thu
        case .fri: .fri
        case .sat: .sat
        }
    }

    /// Sort key so `dayOfWeek` ends up in canonical Mon→Sun FHIR order.
    private static func fhirOrder(_ weekday: Weekday) -> Int {
        switch weekday {
        case .mon: 0
        case .tue: 1
        case .wed: 2
        case .thu: 3
        case .fri: 4
        case .sat: 5
        case .sun: 6
        }
    }

    // MARK: - Helpers

    /// Build a `Quantity` from the medication's free-text dose string.
    ///
    /// Recognised shapes (case-insensitive on the unit, whitespace-tolerant):
    /// - `"5mg"` → 5 mg
    /// - `"10 mg"` → 10 mg
    /// - `"5.5mg"` → 5.5 mg
    /// - `"5,5 mg"` (German decimal) → 5.5 mg
    /// - `"100 mcg"`, `"0.5 g"`, `"10 mL"`, `"1 IU"`
    ///
    /// Returns `nil` when:
    /// - the string has no numeric prefix ("two tablets"),
    /// - the unit token isn't in the known UCUM whitelist ("1 tablet",
    ///   "1 pill" — counts without a UCUM mapping are caller-handled via
    ///   the `dosage.text` fallback).
    static func parseDose(_ doseString: String) -> Quantity? {
        let trimmed = doseString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Scan: leading number (with `.` or `,` decimal), optional whitespace,
        // trailing unit token.
        var numericPart = ""
        var unitStartIndex = trimmed.startIndex
        for index in trimmed.indices {
            let char = trimmed[index]
            if char.isNumber || char == "." || char == "," {
                numericPart.append(char == "," ? "." : char)
                unitStartIndex = trimmed.index(after: index)
            } else if char == " " {
                unitStartIndex = trimmed.index(after: index)
                continue
            } else {
                break
            }
        }
        guard let value = Double(numericPart) else { return nil }
        // AUD-4 M1 — a non-finite / out-of-range parsed dose must not reach
        // `FHIRDecimal(floatLiteral:)`. Drop the coded Quantity (the dose still
        // surfaces as `dosage.text`) rather than emit a garbage / encode-aborting
        // value.
        guard let safeValue = FHIRDecimal(safeServer: value) else { return nil }

        let rawUnit = String(trimmed[unitStartIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ucumUnit = canonicalUCUMUnit(rawUnit) else { return nil }

        let quantity = Quantity()
        quantity.value = safeValue.asPrimitive()
        quantity.unit = FHIRString(ucumUnit).asPrimitive()
        quantity.system = makeFHIRURI(ucumSystemURI).asPrimitive()
        quantity.code = FHIRString(ucumUnit).asPrimitive()
        return quantity
    }

    /// Whitelist of dose units we map to canonical UCUM. Anything outside
    /// this set returns `nil` (and the dose surfaces as `dosage.text`
    /// only). Kept intentionally tight: the FHIR validator rejects free
    /// `Quantity.code` values that don't resolve in UCUM, so we'd rather
    /// emit no quantity than an invalid one.
    private static func canonicalUCUMUnit(_ raw: String) -> String? {
        let normalised = raw.lowercased()
        switch normalised {
        case "mg": return "mg"
        case "g": return "g"
        case "kg": return "kg"
        case "mcg", "µg", "ug": return "ug"
        case "ml": return "mL"
        case "l": return "L"
        case "iu", "i.u.", "ie": return "[iU]"
        case "%": return "%"
        default: return nil
        }
    }

    private static func makeFHIRTime(from time: TimeOfDay) -> FHIRTime {
        FHIRTime(
            hour: UInt8(clamping: time.hour),
            minute: UInt8(clamping: time.minute),
            second: 0
        )
    }

    private static func makeDateTime(from date: Date) -> DateTime {
        // A2-L4 — non-throwing construction from calendar components (no `try!`
        // on a runtime date). See `FHIRDateConverter`.
        FHIRDateConverter.dateTime(from: date)
    }

    private static func makeFHIRURI(_ string: String) -> FHIRURI {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid FHIR URI: \(string)")
        }
        return FHIRURI(url)
    }
}
