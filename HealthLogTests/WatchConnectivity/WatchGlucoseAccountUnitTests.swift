import Foundation
@testable import HealthLog
import Testing

/// **#115 B5 — the wrist enters glucose in the account's unit.**
///
/// The watch dialled glucose in fixed mg/dL (20…600). For an mmol/L account
/// that was a second unit at the wrist. The phone now tells the watch the
/// account unit in the snapshot, and the watch converts the dialled value to
/// canonical mg/dL before it sends the action, so the wire — and every phone
/// build, old or new — keeps receiving mg/dL.
@Suite("#115 B5 — watch glucose entry in the account unit")
struct WatchGlucoseAccountUnitTests {
    // MARK: - The conversion the wrist applies

    @Test("an mmol/L entry reaches the wire as the phone's own canonical mg/dL", arguments: [3.9, 5.3, 7.8, 11.1, 33.3])
    func mmolEntryMatchesPhoneEntryPath(dialled: Double) {
        let wrist = WatchGlucoseUnit.mmolL.canonicalMgdL(fromDisplayed: dialled)
        let sheet = UnitPreferences(glucose: .mmolL).canonicalGlucose(fromDisplayed: dialled)
        #expect(wrist == sheet, "wrist and sheet must store the identical number for the identical entry")
        #expect(wrist == GlucoseUnit.mmolL.canonicalMgdL(fromDisplayed: dialled))
        // And it reads back as exactly what was dialled.
        #expect(abs(UnitPreferences(glucose: .mmolL).convertGlucose(wrist) - dialled) < 1e-9)
    }

    @Test("an mg/dL entry is sent unchanged")
    func mgdlEntryIsIdentity() {
        #expect(WatchGlucoseUnit.mgdL.canonicalMgdL(fromDisplayed: 104) == 104)
    }

    @Test("the crown covers the same 20…600 mg/dL band in mmol/L, in tenths")
    func mmolCrownBand() {
        let unit = WatchGlucoseUnit.mmolL
        let low = unit.canonicalMgdL(fromDisplayed: unit.entryRange.lowerBound)
        let high = unit.canonicalMgdL(fromDisplayed: unit.entryRange.upperBound)
        #expect(abs(low - 20) < 1, "lower bound ≈ 20 mg/dL, got \(low)")
        #expect(abs(high - 600) < 2, "upper bound ≈ 600 mg/dL, got \(high)")
        #expect(unit.entryStep == 0.1)
        #expect(unit.entryRange.contains(unit.entryDefault))
        #expect(unit.suffix == "mmol/L")
        #expect(WatchGlucoseUnit.mgdL.entryRange == 20 ... 600)
    }

    // MARK: - The snapshot carries the unit

    @Test("the phone snapshot carries the account's glucose unit")
    func snapshotCarriesAccountUnit() {
        let mmol = WatchSnapshot.make(
            medications: [],
            derivedIntakes: [],
            recentMoods: [],
            signedIn: true,
            glucoseUnit: .mmolL
        )
        #expect(mmol.glucoseUnit == .mmolL)
        let mgdl = WatchSnapshot.make(medications: [], derivedIntakes: [], recentMoods: [], signedIn: true)
        #expect(mgdl.glucoseUnit == .mgdL)
    }

    @Test("the unit survives the WatchConnectivity transport")
    func unitSurvivesTransport() throws {
        let snapshot = WatchSnapshot(
            doses: [],
            scheduledCount: 0,
            takenCount: 0,
            recentMoodScore: nil,
            signedIn: true,
            glucoseUnit: .mmolL,
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let decoded = try #require(WatchTransport.decodeSnapshot(WatchTransport.encode(snapshot: snapshot)))
        #expect(decoded.glucoseUnit == .mmolL)
        #expect(decoded == snapshot)
    }

    /// Update path: a watch on this build paired with a phone on an older build
    /// receives snapshots without the key, and keeps entering in mg/dL — the
    /// unit the older phone's wire expects.
    @Test("a snapshot from an older phone (no key) or with an unknown unit reads as mg/dL")
    func legacyOrUnknownUnitIsMgdl() throws {
        let snapshot = WatchSnapshot(
            doses: [],
            scheduledCount: 1,
            takenCount: 1,
            recentMoodScore: 3,
            signedIn: true,
            glucoseUnit: .mmolL,
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let data = try #require(WatchTransport.encode(snapshot: snapshot)[WatchTransport.snapshotKey])
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        object.removeValue(forKey: "glucoseUnit")
        let legacy = try #require(try decode(object))
        #expect(legacy.glucoseUnit == .mgdL)
        #expect(legacy.takenCount == 1, "the rest of the blob still reads")

        object["glucoseUnit"] = "mmol/dL-typo"
        #expect(try #require(try decode(object)).glucoseUnit == .mgdL)
    }

    @Test("the logout placeholder is mg/dL")
    func placeholderIsMgdl() {
        #expect(WatchSnapshot.placeholder.glucoseUnit == .mgdL)
        #expect(WatchSnapshot.placeholder.isCleared)
    }

    @Test("every app glucose unit has its wire token, bit-identical raw values")
    func wireTokensMirrorAppUnits() {
        for unit in GlucoseUnit.allCases {
            #expect(WatchGlucoseUnit(unit).rawValue == unit.rawValue)
        }
    }

    private func decode(_ object: [String: Any]) throws -> WatchSnapshot? {
        let data = try JSONSerialization.data(withJSONObject: object)
        return WatchTransport.decodeSnapshot([WatchTransport.snapshotKey: data])
    }
}
