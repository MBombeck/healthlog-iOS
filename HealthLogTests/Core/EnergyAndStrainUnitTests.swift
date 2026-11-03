import Foundation
@testable import HealthLog
import Testing

/// **1.4 B4 — one unit per value, everywhere.**
///
/// Energy expenditure arrives in kJ (WHOOP's unit; the server keeps it and has
/// no energy preference). The recovery page converted it to kcal (plan
/// decision 4), but the metric page behind the row still read kJ, and the day
/// strain there had no "von 21". Both now ride the account-unit transform that
/// every value surface already reads, so the number and its label agree on the
/// recovery page, the metric page, the tiles and the lists.
@Suite("1.4 B4: energy in kcal and strain on its 0 to 21 scale")
struct EnergyAndStrainUnitTests {
    @Test("energy expenditure reads in kcal on metric and imperial accounts", arguments: [HLUnitPreference.metric, .imperial])
    func energyInKcal(system: HLUnitPreference) {
        let units = UnitPreferences(system: system)
        let transform = units.transform(for: .energyExpenditureKJ)
        #expect(transform.rescales)
        #expect(abs(transform.display(10460) - 2500) < 0.001, "10,460 kJ is 2,500 kcal")
        #expect(units.unitLabel(for: .energyExpenditureKJ) == String(localized: "kcal"))
        #expect(MetricValueFormatter.account(10460, kind: .energyExpenditureKJ, units: units) { "\($0)" }
            == 2500.formatted(.number))
    }

    @Test("a value typed in kcal goes back to the server's kJ")
    func energyEntryRoundTrip() {
        let units = UnitPreferences.standard
        #expect(abs(units.canonicalValue(fromDisplayed: 2500, kind: .energyExpenditureKJ) - 10460) < 0.001)
    }

    @Test("active energy is untouched: it is kcal on the wire already")
    func activeEnergyStaysIdentity() {
        #expect(UnitPreferences.standard.transform(for: .activeEnergy) == .identity)
    }

    @Test("day and workout strain keep their value and carry the scale as their label", arguments: [MetricKind.dayStrain, .workoutStrain])
    func strainScale(kind: MetricKind) {
        let units = UnitPreferences.standard
        let transform = units.transform(for: kind)
        #expect(!transform.rescales)
        #expect(transform.display(12.4) == 12.4)
        #expect(units.unitLabel(for: kind) == String(localized: "metric.strain.ofTwentyOne"))
        #expect(String(localized: kind.descriptor.unitLabel) == String(localized: "metric.strain.ofTwentyOne"))
    }

    @Test("the recovery page and the metric page write energy the same way")
    func recoveryRowMatchesTransform() {
        let row = RecoveryValueText.value(10460, kind: .energyExpenditureKJ)
        #expect(row == "\(2500.formatted(.number)) \(String(localized: "kcal"))")
    }
}
