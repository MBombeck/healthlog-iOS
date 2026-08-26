import Foundation

/// **Pure, static write-body builders for ``CycleCaptureSheet``.**
///
/// Split out of `CycleCaptureSheet.swift` under the repo's file-length
/// discipline (CU-25 / #72) — pure movement, no behaviour change. Everything
/// here is `static` and touches no view state, which is exactly why it is
/// unit-testable without the SwiftUI runtime (`CycleCaptureSheetTests`).
extension CycleCaptureSheet {
    // swiftlint:disable:next function_parameter_count
    /// Pure builder for the contract `CycleDayLogWrite` — unit-testable without
    /// the SwiftUI runtime. `externalId` is the same-day stable UPSERT key
    /// (last-writer-wins per the contract); `protectedSex` is only sent when
    /// `sexualActivity` is set; empty symptoms / note are omitted (never sent
    /// as a `null` that the server would read as "clear this field").
    static func buildWrite(
        date: Date,
        flow: CycleFlowLevel,
        selectedSymptoms: Set<String>,
        symptomSeverity: [String: Int],
        hasBBT: Bool,
        bbt: Double,
        temperatureExcluded: Bool = false,
        ovulationTest: CycleOvulationTest?,
        cervicalMucus: CycleCervicalMucus?,
        cervixPosition: CycleCervixPosition? = nil,
        cervixFirmness: CycleCervixFirmness? = nil,
        cervixOpening: CycleCervixOpening? = nil,
        intermenstrualBleeding: Bool = false,
        pregnancyTest: CycleTestResult? = nil,
        progesteroneTest: CycleTestResult? = nil,
        contraceptive: CycleContraceptiveKind? = nil,
        sexualActivity: Bool,
        protectedSex: Bool,
        note: String
    ) -> CycleDayLogWrite {
        let key = dayKey(date)
        let symptoms: [CycleSymptomDTO] = selectedSymptoms.sorted().map { symptomKey in
            CycleSymptomDTO(key: symptomKey, severity: symptomSeverity[symptomKey])
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return CycleDayLogWrite(
            date: key,
            flow: flow,
            intermenstrualBleeding: intermenstrualBleeding,
            basalBodyTempC: hasBBT ? (bbt * 100).rounded() / 100 : nil,
            // `temperatureExcluded` is only meaningful alongside a reading — never
            // send a bare `true` for a day with no BBT.
            temperatureExcluded: hasBBT && temperatureExcluded ? true : nil,
            ovulationTest: ovulationTest,
            cervicalMucus: cervicalMucus,
            cervixPosition: cervixPosition,
            cervixFirmness: cervixFirmness,
            cervixOpening: cervixOpening,
            sexualActivity: sexualActivity ? true : nil,
            protectedSex: sexualActivity ? protectedSex : nil,
            pregnancyTest: pregnancyTest,
            progesteroneTest: progesteroneTest,
            contraceptive: contraceptive,
            symptoms: symptoms.isEmpty ? nil : symptoms,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            loggedAt: iso(date),
            source: "MANUAL",
            externalId: "cycle-manual:\(key)"
        )
    }

    // MARK: - Date helpers (user-tz, POSIX)

    static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
