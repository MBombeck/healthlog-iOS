import Foundation
@testable import HealthLog
import Testing

/// **B5 (1.4, #126 3.11) — 1½ and the other halves above one unit.**
///
/// The server takes any value above 0 and at most 100 with four decimals
/// since v1.39.1 (`isSupportedUnitsPerDose`, `src/lib/medications/
/// units-per-dose.ts`, read at v1.43.10). The picker offered ¼ … ¾ and whole
/// numbers only, so 1½ could be shown but not chosen. It now offers the halves
/// between the wholes, but only against a server known to take them: an older
/// one answers 422, and an unknown version keeps the curated set.
@Suite("B5 — halves above one unit in the dose picker")
struct MedicationHalfDoseTests {
    private func defaults(version: String?) throws -> UserDefaults {
        let suite = "hl.test.b5.halves.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        if let version {
            KnownServerVersion.record(ServerVersionInfo(version: version), defaults: defaults)
        }
        return defaults
    }

    @Test("with halves the picker offers 1, 1½, 2 … 9½, 10 after the fractions")
    func halvesSitBetweenTheWholes() {
        let options = MedicationUnitsPerDose.pickerOptions(offeringHalves: true)
        let labels = options.map(\.label)
        #expect(Array(labels.prefix(5)) == ["¼", "⅓", "½", "⅔", "¾"])
        #expect(Array(labels.dropFirst(5).prefix(4)) == ["1", "1½", "2", "2½"])
        #expect(labels.last == "10")
        #expect(labels.contains("9½"))
        #expect(!labels.contains("10½"))
        #expect(options.count == 5 + 10 + 9)
    }

    @Test("a half is the value a stored decimal maps back to, so the selection finds its row")
    func halfRoundTrips() throws {
        let options = MedicationUnitsPerDose.pickerOptions(offeringHalves: true)
        let stored = MedicationUnitsPerDose.from(decimal: 2.5)
        #expect(options.contains(stored))
        let half = try #require(options.first { $0.label == "1½" })
        #expect(half.decimalValue == 1.5)

        let patch = MedicationsRepository.MedicationPatch(dose: "47.5 mg", unitsPerDose: half.decimalValue)
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any]
        )
        #expect(object["unitsPerDose"] as? Double == 1.5)
    }

    @Test("without halves the picker keeps the curated set")
    func curatedSetWithoutHalves() {
        #expect(MedicationUnitsPerDose.pickerOptions(offeringHalves: false) == MedicationUnitsPerDose.allCases)
    }

    @Test("halves are offered only against a server known to be v1.39.1 or later")
    func serverVersionGate() throws {
        #expect(try MedicationUnitsPerDose.serverTakesHalves(defaults: defaults(version: "1.43.10")))
        #expect(try MedicationUnitsPerDose.serverTakesHalves(defaults: defaults(version: "1.39.1")))
        #expect(try !MedicationUnitsPerDose.serverTakesHalves(defaults: defaults(version: "1.39.0")))
        #expect(try !MedicationUnitsPerDose.serverTakesHalves(defaults: defaults(version: nil)))
    }
}
