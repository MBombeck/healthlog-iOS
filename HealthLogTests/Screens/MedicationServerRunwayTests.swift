import Foundation
@testable import HealthLog
import Testing

/// **ROUTE-06 / plan 08-20 — the medication supply consumers, driven by
/// v1.37.19 server truth.**
///
/// Plan 08-17 decoded `Medication.stockDosesRemaining` and
/// `Medication.runwayDays` at the model boundary and deliberately left every
/// consumer untouched. This suite is the consumer half: the detail aggregate
/// shows the server's slot-aware dose count and the server's projected days,
/// the mirrored low-supply preference only *filters* that day count, and no
/// file re-derives a runway from inventory units ÷ a locally implied burn rate.
///
/// **Why the policy clause reads source text rather than calling the engine.**
/// A clause written against the retired arithmetic could not survive its own
/// deletion — the RED would have had to be a build failure, which proves
/// nothing about behaviour. Reading comment-stripped source keeps one clause
/// meaningful on both sides of the change, exactly as 08-18's
/// `acceptedContractHasNoIOSConsumer` does for the reminder wire.
@Suite("Medication server runway — consumers")
struct MedicationServerRunwayTests {
    // MARK: - The consumer policy

    @Test("Supply consumers read server stock/runway and no file derives a runway")
    func supplyConsumersReadServerTruth() throws {
        var violations: [String] = []

        // 1. The retired engine's file is gone.
        let enginePath = "HealthLog/Screens/Medications/Medication" + "SupplyRunway.swift"
        if FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(enginePath).path) {
            violations.append("\(enginePath) still exists")
        }

        // 2. No production file names the retired arithmetic — under its own
        //    name or under a new one carrying the same members.
        for relative in try Self.productionSources() {
            let source = try Self.strippedSource(relative)
            for symbol in Self.retiredSymbols where source.contains(symbol) {
                violations.append("\(relative) names \(symbol)")
            }
        }

        // 3. The three consumers read the decoded server fields directly.
        for (relative, required) in Self.requiredReads {
            let source = try Self.strippedSource(relative)
            if !source.contains(required) {
                violations.append("\(relative) does not read \(required)")
            }
        }

        // 4. The supply headline is not a local sum of container units.
        let section = try Self.strippedSource(Self.sectionPath)
        if section.contains("remainingUnits") {
            violations.append("\(Self.sectionPath) still sums container units for the headline")
        }

        #expect(
            violations.isEmpty,
            """
            EXPECTED_RED: medication supply consumers still derive the runway locally \
            (\(violations.count)): \(violations.joined(separator: " | "))
            """
        )
    }

    // MARK: - Preservation — the input contract the consumers must not flatten

    @Test("Server nil and server zero arrive at the consumer as different answers")
    func nullAndZeroAreDifferentAtTheConsumerBoundary() {
        let untracked = Self.medication(stockDosesRemaining: nil, runwayDays: nil)
        let exhausted = Self.medication(stockDosesRemaining: 0, runwayDays: 0)

        #expect(untracked.stockDosesRemaining == nil)
        #expect(untracked.runwayDays == nil)
        #expect(exhausted.stockDosesRemaining == 0)
        #expect(exhausted.runwayDays == 0)
        // The two states are not interchangeable: "we do not know" is not "none left".
        #expect(untracked.stockDosesRemaining != exhausted.stockDosesRemaining)
        #expect(untracked.runwayDays != exhausted.runwayDays)
    }

    // MARK: - The headline is the server's dose count

    @Test("Headline renders the server dose count: nil is —, zero is a real zero")
    func headlineDistinguishesUnknownFromExhausted() {
        #expect(MedicationInventorySection.remainingDoseString(nil) == InventorySanity.placeholder)
        #expect(MedicationInventorySection.remainingDoseString(0) == "0")
        #expect(MedicationInventorySection.remainingDoseString(40) == "40")
        // A corrupt count is not laundered into a number the user would act on.
        #expect(MedicationInventorySection.remainingDoseString(-3) == InventorySanity.placeholder)
        #expect(MedicationInventorySection.remainingDoseString(.max) == InventorySanity.placeholder)
    }

    /// The fixture's two slots resolve to **1** and **0.5** units per dose, so
    /// the schedule-weighted divisor is 0.75 and 30 remaining units are 40
    /// doses — while the medication-level `unitsPerDose` of 1 that a local
    /// derivation has to fall back on says 30. The rendered headline is the
    /// server's 40, and the difference is asserted rather than described.
    @Test("Unequal per-slot resolved doses: the headline is the server's, not a local sum ÷ dose")
    func headlineIsNotReweightedLocally() {
        let medication = Self.medication(stockDosesRemaining: 40, runwayDays: 20)
        let items = [Self.item(remaining: 30, total: 30)]

        let rendered = MedicationInventorySection.remainingDoseString(medication.stockDosesRemaining)
        #expect(rendered == "40")

        // What a single medication-level divisor would have produced from the
        // same containers — still reachable, because container ROWS legitimately
        // convert their own units, and demonstrably not the headline.
        let localSum = MedicationInventorySection.validatedSum(items, \.unitsRemaining)
        #expect(localSum == 30)
        #expect(MedicationInventorySection.doseString(localSum, unitsPerDose: medication.effectiveUnitsPerDose) == "30")
        #expect(rendered != "30")
    }

    // MARK: - The threshold filters, it does not project

    @Test("A comfortable server runway is hidden; a low one is shown; the boundary is inclusive")
    func thresholdFiltersTheServerDayCount() {
        #expect(MedicationInventorySection.runwayWithinThreshold(5, threshold: 7) == 5)
        #expect(MedicationInventorySection.runwayWithinThreshold(7, threshold: 7) == 7)
        #expect(MedicationInventorySection.runwayWithinThreshold(30, threshold: 7) == nil)
    }

    @Test("Server zero passes the gate — an exhausted supply is what the threshold is for")
    func exhaustedSupplyIsSurfacedNotSuppressed() {
        #expect(MedicationInventorySection.runwayWithinThreshold(0, threshold: 7) == 0)
        #expect(MedicationInventorySection.runwayWithinThreshold(0, threshold: 1) == 0)
    }

    @Test("Server nil stays unavailable at every threshold, and is not a zero")
    func trackingOffIsNeverRendered() {
        #expect(MedicationInventorySection.runwayWithinThreshold(nil, threshold: 7) == nil)
        #expect(MedicationInventorySection.runwayWithinThreshold(nil, threshold: 60) == nil)
        #expect(MedicationInventorySection.runwayWithinThreshold(nil, threshold: nil) == nil)
        // The two nils that reach the row are the same instruction ("render
        // nothing") from two different sentences, and the zero is neither.
        #expect(MedicationInventorySection.runwayWithinThreshold(0, threshold: 7) != nil)
    }

    @Test("Threshold nil (low-supply alert off) renders and alerts nothing")
    func alertOffSuppressesEveryRunway() {
        #expect(MedicationInventorySection.runwayWithinThreshold(1, threshold: nil) == nil)
        #expect(MedicationInventorySection.runwayWithinThreshold(0, threshold: nil) == nil)
    }

    @Test("A corrupt server day count renders nothing rather than a wild projection")
    func corruptServerDayCountIsRefused() {
        #expect(MedicationInventorySection.runwayWithinThreshold(-4, threshold: 7) == nil)
        #expect(MedicationInventorySection.runwayWithinThreshold(.max, threshold: .max) == nil)
    }

    /// The sharpest form of "no local derivation": on this fixture the server's
    /// answer (20 days) and the answer a single-divisor local rate would have
    /// produced (30 units ÷ 2 units/day = 15 days) fall on **opposite sides** of
    /// a threshold of 17, so the two disagree about whether to warn the user at
    /// all — not merely about a number.
    @Test("Unequal per-slot resolved doses: the gate decision follows the server, not a local rate")
    func gateDecisionFollowsTheServer() {
        let medication = Self.medication(stockDosesRemaining: 40, runwayDays: 20)
        let localDaysASingleDivisorWouldGive = 15

        #expect(medication.runwayDays == 20)
        #expect(MedicationInventorySection.runwayWithinThreshold(medication.runwayDays, threshold: 30) == 20)
        #expect(MedicationInventorySection.runwayWithinThreshold(medication.runwayDays, threshold: 17) == nil)
        #expect(localDaysASingleDivisorWouldGive <= 17)
        #expect(medication.runwayDays.map { $0 > 17 } == true)
    }

    // MARK: - Fixtures

    /// A medication whose two slots resolve to *unequal* effective doses, so a
    /// single medication-level divisor cannot reproduce the server's answer.
    static func medication(
        stockDosesRemaining: Int?,
        runwayDays: Int?,
        unitsPerDose: Double? = 1
    ) -> Medication {
        Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            unitsPerDose: unitsPerDose,
            schedule: MedicationSchedule(entries: [
                ScheduleEntry(
                    cadence: .daily,
                    timesOfDay: [TimeOfDay(hour: 8, minute: 0)],
                    windowStart: TimeOfDay(hour: 8, minute: 0),
                    unitsPerDose: nil,
                    resolvedUnitsPerDose: 1
                ),
                ScheduleEntry(
                    cadence: .daily,
                    timesOfDay: [TimeOfDay(hour: 20, minute: 0)],
                    windowStart: TimeOfDay(hour: 20, minute: 0),
                    unitsPerDose: 0.5,
                    resolvedUnitsPerDose: 0.5
                )
            ]),
            stockDosesRemaining: stockDosesRemaining,
            runwayDays: runwayDays
        )
    }

    static func item(
        id: String = "inv-1",
        state: String = "ACTIVE",
        remaining: Double,
        total: Double? = nil
    ) -> MedicationInventoryItemDTO {
        MedicationInventoryItemDTO(
            id: id,
            userId: "u",
            medicationId: "med-1",
            state: state,
            unitsTotal: total ?? remaining,
            unitsRemaining: remaining
        )
    }

    // MARK: - Source access

    static let sectionPath = "HealthLog/Screens/Medications/MedicationInventorySection.swift"

    /// The consumer files and the decoded field each one must read.
    static let requiredReads: [(String, String)] = [
        ("HealthLog/Screens/Medications/MedicationDetailScreen.swift", "store.medication.runwayDays"),
        ("HealthLog/Screens/Medications/MedicationDetailScreen+Actions.swift", "medication.runwayDays"),
        (sectionPath, "medication.stockDosesRemaining")
    ]

    /// The retired engine's members, assembled at runtime instead of written as
    /// literals. The plan's own source-policy search greps `HealthLog` **and**
    /// `HealthLogTests`, so a literal here would fail the very check this case
    /// exists to prove — and exempting this file from the search would be worse.
    static let retiredSymbols: [String] = [
        "Medication" + "SupplyRunway",
        "daily" + "UnitConsumption",
        "daily" + "DoseRate",
        "validated" + "RemainingUnits"
    ]

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func productionSources() throws -> [String] {
        let base = root.appendingPathComponent("HealthLog")
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            throw SourceScanError.unreadable(base.path)
        }
        var out: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            out.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return out.sorted()
    }

    static func strippedSource(_ relativePath: String) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        // Line comments first. The reverse order (which 08-15 carried forward
        // as a hazard) truncates any file whose `//` comment contains a `/*`.
        return stripBlockComments(from: stripLineComments(from: text))
    }

    private static func stripLineComments(from source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var quoted = false
            var previous: Character = " "
            for (offset, character) in line.enumerated() {
                if character == "\"", previous != "\\" { quoted.toggle() }
                if !quoted, character == "/", previous == "/" { return String(line.prefix(offset - 1)) }
                previous = character
            }
            return String(line)
        }.joined(separator: "\n")
    }

    private static func stripBlockComments(from source: String) -> String {
        var out = ""
        var rest = Substring(source)
        while let open = rest.range(of: "/*") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    enum SourceScanError: Error {
        case unreadable(String)
    }
}

/// **MED-4 / C3** — the once-per-crossing alert ledger that keeps the local
/// low-supply notification from re-firing on every detail-screen open.
@Suite("LowSupplyAlertLedger — once-per-crossing")
struct LowSupplyAlertLedgerTests {
    private func freshDefaults() throws -> UserDefaults {
        let suite = "test.lowsupply.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("First evaluation always alerts")
    func firstAlerts() throws {
        let d = try freshDefaults()
        #expect(LowSupplyAlertLedger.shouldAlert(medicationID: "m", runwayDays: 5, defaults: d))
    }

    @Test("Does not re-alert while the runway keeps shrinking past an alerted level")
    func noReNagWhileShrinking() throws {
        let d = try freshDefaults()
        LowSupplyAlertLedger.recordAlert(medicationID: "m", runwayDays: 5, defaults: d)
        // 4 days left is below the already-alerted 5 → no re-nag.
        #expect(!LowSupplyAlertLedger.shouldAlert(medicationID: "m", runwayDays: 4, defaults: d))
        #expect(!LowSupplyAlertLedger.shouldAlert(medicationID: "m", runwayDays: 5, defaults: d))
    }

    @Test("Re-alerts after a re-stock lifts the runway above the alerted level")
    func reAlertsAfterRestock() throws {
        let d = try freshDefaults()
        LowSupplyAlertLedger.recordAlert(medicationID: "m", runwayDays: 3, defaults: d)
        // Re-stocked → runway recovered to 20, then crosses back down: 20 > 3
        // so a recovery crossing re-arms.
        #expect(LowSupplyAlertLedger.shouldAlert(medicationID: "m", runwayDays: 20, defaults: d))
    }

    @Test("Clear re-arms the next crossing")
    func clearReArms() throws {
        let d = try freshDefaults()
        LowSupplyAlertLedger.recordAlert(medicationID: "m", runwayDays: 5, defaults: d)
        LowSupplyAlertLedger.clear(medicationID: "m", defaults: d)
        #expect(LowSupplyAlertLedger.shouldAlert(medicationID: "m", runwayDays: 4, defaults: d))
    }

    @Test("Ledgers are per-medication")
    func perMedication() throws {
        let d = try freshDefaults()
        LowSupplyAlertLedger.recordAlert(medicationID: "a", runwayDays: 5, defaults: d)
        // A different medication has never alerted → should alert.
        #expect(LowSupplyAlertLedger.shouldAlert(medicationID: "b", runwayDays: 5, defaults: d))
    }
}

/// **MED-4 / C3** — the local low-supply notification request carries the
/// routing payload (medicationId + deep-link) so a body-tap reaches the
/// medication's detail (where the supply tab lives).
@Suite("Low-supply notification — routing payload")
struct LowSupplyNotificationRequestTests {
    @Test("Request carries medicationId + deep-link + low-stock event type")
    func requestRoutingPayload() {
        let request = NotificationService.buildLowSupplyRequest(
            medicationID: "med-42",
            medicationName: "Lisinopril",
            runwayDays: 4
        )
        let info = request.content.userInfo
        #expect(info["medicationId"] as? String == "med-42")
        #expect(info["eventType"] as? String == NotificationService.eventTypeLowSupply)
        #expect(info["deepLink"] as? String == "healthlog://medications/med-42")
        // The body-tap parser resolves the same payload → the detail route.
        let payload = APNsPayload.parse(userInfo: info)
        #expect(payload?.medicationId == "med-42")
        #expect(payload?.deepLink == URL(string: "healthlog://medications/med-42"))
    }

    @Test("Low-supply uses the action-free category, never the intake category (no phantom-dose button)")
    func usesActionFreeCategory() {
        let request = NotificationService.buildLowSupplyRequest(
            medicationID: "med-42",
            medicationName: "Lisinopril",
            runwayDays: 4
        )
        // W-B185 dose-safety: a supply alert must NOT carry the
        // Taken/Snooze/Skipped intake actions — tapping "Taken" on a heads-up
        // would record a dose the user never took. It rides the dedicated
        // action-free MEDICATION_LOW_STOCK category, not MEDICATION_REMINDER.
        #expect(request.content.categoryIdentifier == NotificationService.categoryMedicationLowStock)
        #expect(request.content.categoryIdentifier != NotificationService.categoryMedication)
    }

    @Test("Identifier is per-medication so re-evaluation replaces, not stacks")
    func perMedicationIdentifier() {
        let a = NotificationService.lowSupplyLocalIdentifier(medicationID: "a")
        let b = NotificationService.lowSupplyLocalIdentifier(medicationID: "b")
        #expect(a != b)
        #expect(a == NotificationService.lowSupplyLocalIdentifier(medicationID: "a"))
    }
}
