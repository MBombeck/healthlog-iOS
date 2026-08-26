import Foundation
@testable import HealthLog
import Testing

/// **Generic per-medication supply + C1 wire-rename round-trip (v1.16.10–.12).**
///
/// Pins (1) the tolerant decode of `MedicationInventoryItemDTO` against the
/// NEW `unitsTotal` / `unitsRemaining` wire dialect AND the legacy
/// `dosesTotal` / `dosesRemaining` fallback (stale local cache), (2) the
/// `containerType` decode, (3) the encode→decode round-trip on the new names,
/// and (4) that the detail store surfaces supply for a NON-GLP-1 medication.
@Suite("Medication supply — generic + C1 wire rename")
struct MedicationInventoryGenericTests {
    @Test("Tolerant decode: minimal payload (id + unitsTotal) fills safe defaults")
    func tolerantDecodeMinimal() throws {
        let json = Data(#"{"id":"inv-1","unitsTotal":30}"#.utf8)
        let item = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: json)
        #expect(item.id == "inv-1")
        #expect(item.unitsTotal == 30)
        #expect(item.unitsRemaining == 30, "unitsRemaining defaults to unitsTotal")
        #expect(item.state == "ACTIVE", "state defaults to ACTIVE")
        #expect(item.containerType == nil)
        #expect(item.userId.isEmpty)
        #expect(item.medicationId.isEmpty)
    }

    @Test("C1 back-compat: legacy dosesTotal/dosesRemaining still decode")
    func legacyKeysDecode() throws {
        let json = Data(#"{"id":"inv-legacy","dosesTotal":30,"dosesRemaining":12}"#.utf8)
        let item = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: json)
        #expect(item.unitsTotal == 30, "dosesTotal maps onto unitsTotal")
        #expect(item.unitsRemaining == 12, "dosesRemaining maps onto unitsRemaining")
    }

    @Test("Full server row decodes with the new wire dialect + containerType")
    func fullRowDecodes() throws {
        let json = Data("""
        {
          "id": "inv-2",
          "userId": "u-1",
          "medicationId": "med-tablet",
          "state": "IN_USE",
          "unitsTotal": 30,
          "unitsRemaining": 12,
          "containerType": "BLISTER",
          "firstUseAt": "2026-06-01T08:00:00.000Z",
          "printedExpiry": "2027-01-01T00:00:00.000Z",
          "notes": "Blisterpackung"
        }
        """.utf8)
        let item = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: json)
        #expect(item.state == "IN_USE")
        #expect(item.unitsRemaining == 12)
        #expect(item.containerType == .blister)
        #expect(item.medicationId == "med-tablet")
        #expect(item.notes == "Blisterpackung")
        #expect(item.firstUseAt != nil)
    }

    @Test("C1 fractional units (split-pill remainder) decode losslessly")
    func fractionalUnitsDecode() throws {
        let json = Data(#"{"id":"inv-frac","unitsTotal":30,"unitsRemaining":29.5}"#.utf8)
        let item = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: json)
        #expect(item.unitsRemaining == 29.5)
    }

    @Test("C1 encode→decode round-trip on the new wire names")
    func encodeDecodeRoundTrip() throws {
        let original = MedicationInventoryItemDTO(
            id: "inv-rt",
            userId: "u-1",
            medicationId: "m-1",
            state: "ACTIVE",
            unitsTotal: 1000,
            unitsRemaining: 750,
            containerType: .inhaler
        )
        let data = try JSONEncoder.hlDefault.encode(original)
        // The encoded payload must carry the NEW keys (the server no longer
        // accepts the legacy names on write).
        let asString = try #require(String(bytes: data, encoding: .utf8))
        #expect(asString.contains("unitsTotal"))
        #expect(asString.contains("unitsRemaining"))
        #expect(!asString.contains("dosesTotal"))
        let decoded = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: data)
        #expect(decoded == original)
    }

    @Test("Create body encodes unitsTotal + containerType (not dosesTotal)")
    func createBodyEncodesNewKeys() throws {
        let body = MedicationInventoryCreate(unitsTotal: 200, containerType: .inhaler)
        let asString = try #require(String(bytes: JSONEncoder.hlDefault.encode(body), encoding: .utf8))
        #expect(asString.contains("unitsTotal"))
        #expect(asString.contains("INHALER"))
        #expect(!asString.contains("dosesTotal"))
    }

    @Test("Patch body encodes unitsRemaining correction only when set")
    func patchBodyEncodesCorrection() throws {
        let withCorrection = MedicationInventoryPatch(unitsRemaining: 5)
        let s1 = try #require(String(bytes: JSONEncoder.hlDefault.encode(withCorrection), encoding: .utf8))
        #expect(s1.contains("unitsRemaining"))

        let without = MedicationInventoryPatch(markAsUsedUp: true)
        let s2 = try #require(String(bytes: JSONEncoder.hlDefault.encode(without), encoding: .utf8))
        #expect(!s2.contains("unitsRemaining"), "omitted correction must not be sent")
    }

    @Test("doseString divides units by unitsPerDose")
    func doseStringConversion() {
        #expect(MedicationInventorySection.doseString(30, unitsPerDose: 1) == "30")
        #expect(MedicationInventorySection.doseString(30, unitsPerDose: 2) == "15")
        #expect(MedicationInventorySection.doseString(30, unitsPerDose: 0.5) == "60")
        // 29.5 units at half-tablet dose → 59 doses.
        #expect(MedicationInventorySection.doseString(29.5, unitsPerDose: 0.5) == "59")
    }

    // MARK: - #31 (v1.18.3) — explicit `null` units = UNKNOWN, not a throw / 0

    @Test("#31: explicit null unitsTotal/unitsRemaining decode to nil (UNKNOWN), not a throw")
    func explicitNullDecodesToUnknown() throws {
        // The exact live wire shape #31 introduced: the server emits an UNKNOWN
        // supply count as JSON `null`. Pre-fix this made the WHOLE list decode
        // throw (decode-fragile, data-loss). It must now decode to `nil`.
        let json = Data(#"{"id":"inv-null","unitsTotal":null,"unitsRemaining":null}"#.utf8)
        let item = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: json)
        #expect(item.unitsTotal == nil, "null → nil (unknown), not 0")
        #expect(item.unitsRemaining == nil, "null → nil (unknown), not 0")
        // Both surface as "—", never a fabricated 0.
        #expect(MedicationInventorySection.doseString(item.unitsTotal, unitsPerDose: 1)
            == InventorySanity.placeholder)
        #expect(MedicationInventorySection.doseString(item.unitsRemaining, unitsPerDose: 1)
            == InventorySanity.placeholder)
    }

    @Test("#31: a genuine 0 still reads as a tracked zero-stock (not unknown)")
    func genuineZeroIsZeroNotUnknown() throws {
        let json = Data(#"{"id":"inv-zero","unitsTotal":30,"unitsRemaining":0}"#.utf8)
        let item = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: json)
        #expect(item.unitsRemaining == 0, "an explicit 0 is a genuine empty container, not unknown")
        #expect(item.unitsTotal == 30)
        // 0 is a valid, renderable number — NOT the placeholder.
        #expect(MedicationInventorySection.doseString(item.unitsRemaining, unitsPerDose: 1) == "0")
    }

    @Test("#31: a null in a list does not throw the whole list decode")
    func nullDoesNotThrowListDecode() throws {
        let json = Data("""
        {"data":{"items":[
          {"id":"a","unitsTotal":30,"unitsRemaining":12},
          {"id":"b","unitsTotal":null,"unitsRemaining":null},
          {"id":"c","unitsTotal":50,"unitsRemaining":0}
        ],"meta":{"total":3}}}
        """.utf8)
        // Decode through the envelope so we exercise the same path the repo does.
        struct Env: Decodable { let data: MedicationInventoryListDTO }
        let list = try JSONDecoder.hlDefault.decode(Env.self, from: json).data
        #expect(list.items.count == 3, "the unknown row must NOT collapse the whole list")
        #expect(list.items[1].unitsTotal == nil)
        #expect(list.items[2].unitsRemaining == 0)
    }

    @Test("#31: nil units round-trip back to JSON null (never a fabricated 0)")
    func nilUnitsRoundTripAsNull() throws {
        let unknown = MedicationInventoryItemDTO(
            id: "inv-rt-null", userId: "u", medicationId: "m", state: "ACTIVE",
            unitsTotal: nil, unitsRemaining: nil
        )
        let data = try JSONEncoder.hlDefault.encode(unknown)
        let asString = try #require(String(bytes: data, encoding: .utf8))
        #expect(asString.contains("\"unitsTotal\":null"), "unknown encodes as explicit null")
        #expect(!asString.contains("\"unitsTotal\":0"), "never a fabricated 0")
        let decoded = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: data)
        #expect(decoded == unknown)
    }

    @Test("#31: an UNKNOWN remaining collapses the validated summary sum to nil (—)")
    func unknownRemainingCollapsesSum() {
        let good = MedicationInventoryItemDTO(
            id: "g", userId: "u", medicationId: "m", state: "ACTIVE",
            unitsTotal: 30, unitsRemaining: 30
        )
        let unknown = MedicationInventoryItemDTO(
            id: "u", userId: "u", medicationId: "m", state: "ACTIVE",
            unitsTotal: nil, unitsRemaining: nil
        )
        #expect(MedicationInventorySection.validatedSum([good, unknown], \.unitsRemaining) == nil)
    }

    @Test("#31: editor pre-fill seeds an EMPTY field for an UNKNOWN (nil) count")
    func unitStringEmptyForUnknown() {
        let unknown: Double? = nil
        let seeded = MedicationSupplyEditorSheet.unitString(unknown)
        #expect(seeded.isEmpty)
    }

    // MARK: - W-INVENTORY — corrupt supply renders "—", never a fake 0 / number

    // Supersedes the W-B187 clamp-to-0 doctrine: the operator brief forbids
    // silently guessing 0. A corrupt value is preserved through decode (only a
    // non-finite value is normalised to a finite reject-sentinel) and the ONE
    // central display gate (`InventorySanity`) turns it into "—".

    @Test("W-INVENTORY: a huge negative server unitsRemaining is preserved (not faked-0) at decode")
    func negativeRemainingPreservedAtDecode() throws {
        // The exact wild-number scenario the operator hit: -4e12.
        let json = Data(#"{"id":"inv-bad","unitsTotal":30,"unitsRemaining":-4000000000000}"#.utf8)
        let item = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: json)
        #expect(item.unitsRemaining == -4_000_000_000_000, "finite corrupt value preserved verbatim")
        #expect(item.unitsTotal == 30, "a valid total is untouched")
        // The display gate rejects it → "—", never "0".
        #expect(MedicationInventorySection.doseString(item.unitsRemaining, unitsPerDose: 1)
            == InventorySanity.placeholder)
    }

    @Test("W-INVENTORY: a non-finite unitsRemaining is normalised to a reject-sentinel")
    func nonFiniteRemainingNormalised() {
        // JSON can't carry NaN/Infinity, so exercise the normaliser directly +
        // verify the stored value is finite (sum/Int()-safe) AND rejected by the gate.
        #expect(sanitizeInventoryUnits(.nan, field: "x").isFinite)
        #expect(sanitizeInventoryUnits(.infinity, field: "x").isFinite)
        #expect(InventorySanity.validUnits(sanitizeInventoryUnits(.nan, field: "x")) == nil)
        #expect(InventorySanity.validUnits(sanitizeInventoryUnits(.infinity, field: "x")) == nil)
    }

    @Test("W-INVENTORY: an absurdly large unitsTotal is preserved + rejected by the gate")
    func absurdLargeTotalRejected() throws {
        let json = Data(#"{"id":"inv-big","unitsTotal":9999999999,"unitsRemaining":50}"#.utf8)
        let item = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: json)
        #expect(item.unitsTotal == 9_999_999_999, "value preserved (no silent clamp-to-cap)")
        #expect(
            MedicationInventorySection.doseString(item.unitsTotal, unitsPerDose: 1)
                == InventorySanity.placeholder,
            "above-ceiling total renders —"
        )
        #expect(item.unitsRemaining == 50)
        #expect(MedicationInventorySection.doseString(item.unitsRemaining, unitsPerDose: 1) == "50")
    }

    @Test("W-INVENTORY: doseString renders — for corrupt input, real numbers otherwise")
    func doseStringRendersPlaceholderForCorrupt() {
        #expect(MedicationInventorySection.doseString(-4_000_000_000_000, unitsPerDose: 1)
            == InventorySanity.placeholder)
        #expect(MedicationInventorySection.doseString(.nan, unitsPerDose: 1) == InventorySanity.placeholder)
        #expect(MedicationInventorySection.doseString(.infinity, unitsPerDose: 1) == InventorySanity.placeholder)
        #expect(MedicationInventorySection.doseString(-1, unitsPerDose: 1) == InventorySanity.placeholder)
        // A degenerate unitsPerDose falls back to 1 (not itself corrupt supply).
        #expect(MedicationInventorySection.doseString(30, unitsPerDose: 0) == "30")
        #expect(MedicationInventorySection.doseString(30, unitsPerDose: -2) == "30")
        // Normal values unchanged (regression guard).
        #expect(MedicationInventorySection.doseString(30, unitsPerDose: 2) == "15")
        // A nil sum (pre-validated invalid) renders —.
        #expect(MedicationInventorySection.doseString(Double?.none, unitsPerDose: 1)
            == InventorySanity.placeholder)
    }

    @Test("W-INVENTORY: a single corrupt row poisons neither the summary nor a sibling row")
    func corruptRowDoesNotHideInSummarySum() {
        let good = MedicationInventoryItemDTO(
            id: "g", userId: "u", medicationId: "m", state: "ACTIVE",
            unitsTotal: 30, unitsRemaining: 30
        )
        let bad = MedicationInventoryItemDTO(
            id: "b", userId: "u", medicationId: "m", state: "ACTIVE",
            unitsTotal: 30, unitsRemaining: -5 // would silently net to 25 if summed naively
        )
        // Validated sum bails to nil when ANY contributing row is corrupt.
        #expect(MedicationInventorySection.validatedSum([good, bad], \.unitsRemaining) == nil)
        // All-good rows still sum normally.
        #expect(MedicationInventorySection.validatedSum([good, good], \.unitsRemaining) == 60)
    }

    @Test("W-INVENTORY: editor pre-fill seeds an EMPTY field (not a fake 0) for corrupt input")
    func unitStringEmptyForCorruptValue() {
        #expect(MedicationSupplyEditorSheet.unitString(-4_000_000_000_000).isEmpty)
        #expect(MedicationSupplyEditorSheet.unitString(.nan).isEmpty)
        #expect(MedicationSupplyEditorSheet.unitString(9_999_999_999).isEmpty)
        #expect(MedicationSupplyEditorSheet.unitString(-1).isEmpty)
        // Normal values unchanged (whole numbers are locale-independent).
        #expect(MedicationSupplyEditorSheet.unitString(12) == "12")
        #expect(MedicationSupplyEditorSheet.unitString(1000) == "1000")
        #expect(
            MedicationSupplyEditorSheet.unitString(29.5)
                == 29.5.formatted(.number.precision(.fractionLength(0 ... 2)))
        )
    }

    @Test("W-INVENTORY: GLP-1 pen-aggregate counts are gated (negative → nil → —)")
    func glp1CountGate() {
        #expect(InventorySanity.validCount(-8) == nil)
        #expect(InventorySanity.validCount(Int.max) == nil)
        #expect(InventorySanity.validCount(4) == 4)
        #expect(InventorySanity.validCount(0) == 0)
    }

    @Test("W-INVENTORY: a sentinel / epoch date is suppressed; a plausible one shows")
    func dateGate() {
        #expect(InventorySanity.validDate(nil) == nil)
        #expect(InventorySanity.validDate(Date(timeIntervalSince1970: 0)) == nil, "1970 epoch suppressed")
        #expect(InventorySanity.validDate(Date(timeIntervalSince1970: -1_000_000)) == nil)
        let plausible = Date(timeIntervalSince1970: 1_750_000_000) // 2025
        #expect(InventorySanity.validDate(plausible) == plausible)
        let farFuture = Date(timeIntervalSinceNow: 100 * 365 * 24 * 60 * 60)
        #expect(InventorySanity.validDate(farFuture) == nil, "100y-out date suppressed")
    }

    // The W-INVENTORY case that pinned "the runway never projects off a corrupt
    // stock count" was removed by plan 08-20 together with the local engine it
    // exercised: there is no client-side projection left to protect from a
    // corrupt container. The property it defended survives in
    // `MedicationServerRunwayTests.corruptServerDayCountIsRefused`, which
    // refuses an implausible day count from the *server* instead.

    @Test("Unknown future state literal renders verbatim (no crash, no hidden row)")
    func unknownStateLabelVerbatim() {
        #expect(MedicationInventorySection.stateLabel("RECALLED") == "RECALLED")
    }

    // MARK: - 2026-07-18 — %lld-vs-String format-specifier regression guard

    /// The "Bestand" headline + item lines interpolate `doseString(...)` — which
    /// returns a **String** ("30", "29.5", "—") — into the localized format
    /// strings. Both keys MUST use `%@`; a `%lld` there reinterprets the bridged
    /// NSString pointer as a signed Int64 → the quadrillion-negative "Bestand"
    /// the operator hit on b227. These guards render through the REAL localized
    /// strings (not a hand-rolled template) so a future revert to `%lld` fails
    /// here, and assert the output shows the true numbers with no absurd
    /// pointer-sized digit run and no spurious minus.
    @Test("Format guard: med.inventory.summary renders true doses, never a pointer-int")
    func summaryFormatUsesStringSpecifier() {
        let out = String(
            format: String(localized: "med.inventory.summary"),
            MedicationInventorySection.doseString(12, unitsPerDose: 1),
            MedicationInventorySection.doseString(30, unitsPerDose: 1)
        )
        #expect(out.contains("12"))
        #expect(out.contains("30"))
        #expect(!out.contains("-"), "no sign-flipped pointer value")
        #expect(longestDigitRun(in: out) <= 4, "no pointer-sized (10+ digit) integer leaked through %lld")
    }

    @Test("Format guard: med.inventory.item.doses renders true doses, never a pointer-int")
    func itemDosesFormatUsesStringSpecifier() {
        let out = String(
            format: String(localized: "med.inventory.item.doses"),
            MedicationInventorySection.doseString(29.5, unitsPerDose: 0.5), // "59"
            MedicationInventorySection.doseString(60, unitsPerDose: 0.5) // "120"
        )
        #expect(out.contains("59"))
        #expect(out.contains("120"))
        #expect(!out.contains("-"))
        #expect(longestDigitRun(in: out) <= 4)
    }

    @Test("Format guard: the '—' placeholder survives the format (not mangled to an int)")
    func placeholderSurvivesFormat() {
        let out = String(
            format: String(localized: "med.inventory.summary"),
            MedicationInventorySection.doseString(Double?.none, unitsPerDose: 1), // "—"
            MedicationInventorySection.doseString(30, unitsPerDose: 1)
        )
        #expect(out.contains(InventorySanity.placeholder), "the em-dash must pass through %@ intact")
        #expect(longestDigitRun(in: out) <= 4)
    }

    /// Longest run of consecutive digits in `s` — a `%lld`-mangled pointer shows
    /// up as a 10+ digit integer, so a small bound is a tight quadrillion trap.
    private func longestDigitRun(in s: String) -> Int {
        var longest = 0, current = 0
        for ch in s {
            if ch.isNumber { current += 1
                longest = max(longest, current)
            } else { current = 0 }
        }
        return longest
    }

    @Test("hasGenericInventory is true for a NON-GLP-1 medication with stored items")
    @MainActor
    func nonGlp1MedicationSurfacesInventory() throws {
        let tablet = Medication(
            id: "med-tablet",
            name: "Lisinopril",
            dose: "5 mg",
            treatmentClass: "BLOOD_PRESSURE",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: StubAPIClient(), outbox: outbox)
        let store = MedicationDetailStore(medication: tablet, repo: repo)
        #expect(!store.isGLP1Recognised, "fixture must be non-GLP-1 — that is the bug surface")
        #expect(!store.hasGenericInventory)

        store._testInject(
            intakes: [],
            inventoryItems: [
                MedicationInventoryItemDTO(
                    id: "inv-1",
                    userId: "u-1",
                    medicationId: tablet.id,
                    state: "IN_USE",
                    unitsTotal: 30,
                    unitsRemaining: 12
                )
            ]
        )
        #expect(store.hasGenericInventory, "stored inventory must be visible for ALL medication types")
    }

    @Test("Empty server list keeps hasGenericInventory false")
    @MainActor
    func emptyListStaysHidden() throws {
        let tablet = Medication(
            id: "med-tablet",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: StubAPIClient(), outbox: outbox)
        let store = MedicationDetailStore(medication: tablet, repo: repo)
        store._testInject(intakes: [], inventoryItems: [])
        #expect(!store.hasGenericInventory)
    }

    @Test("MedicationWireDTO decodes unitsPerDose and threads it into the domain")
    func wireDtoUnitsPerDose() throws {
        let json = Data("""
        {"id":"m-1","name":"Aspirin","dose":"100 mg","unitsPerDose":0.5}
        """.utf8)
        let dto = try JSONDecoder.hlDefault.decode(MedicationWireDTO.self, from: json)
        #expect(dto.unitsPerDose == 0.5)
        let domain = dto.toDomain()
        #expect(domain.unitsPerDose == 0.5)
        #expect(domain.effectiveUnitsPerDose == 0.5)
    }

    @Test("effectiveUnitsPerDose defaults to 1.0 when absent")
    func effectiveUnitsPerDoseDefault() {
        let med = Medication(
            id: "m",
            name: "X",
            dose: "1",
            schedule: MedicationSchedule(times: [])
        )
        #expect(med.effectiveUnitsPerDose == 1.0)
    }
}
