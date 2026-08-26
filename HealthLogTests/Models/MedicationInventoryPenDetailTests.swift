import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **CU-23 — pen detail from the server (#52) + the per-form expiry rule (B2).**
///
/// Pure model-level pins, no network:
///   1. `manufacturer` / `doseStrength` decode off `MedicationInventoryItem`
///      (server v1.31.0, migration 0256) and survive an encode round-trip,
///   2. the create body carries them so a pen registered on iOS is a complete
///      row on the web,
///   3. `PenInventoryStore.penDetail` refuses to turn a detail-less generic
///      container into a blank pen card,
///   4. the expiry copy states the rule the server v1.33.0 actually applies —
///      the 30-day-after-opening clock for `PEN` / `AMPOULE` only.
@Suite("Medication inventory — pen detail (#52) + expiry rule (B2)")
struct MedicationInventoryPenDetailTests {
    // MARK: - #52 wire fields

    @Test("#52: manufacturer + doseStrength decode off the server row")
    func penDetailDecodes() throws {
        let json = Data("""
        {
          "id": "inv-pen",
          "userId": "u-1",
          "medicationId": "med-glp1",
          "state": "IN_USE",
          "unitsTotal": 4,
          "unitsRemaining": 3,
          "containerType": "PEN",
          "manufacturer": "Novo Nordisk",
          "doseStrength": "1,0 mg / Dosis",
          "firstUseAt": "2026-06-01T08:00:00.000Z"
        }
        """.utf8)
        let item = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: json)
        #expect(item.manufacturer == "Novo Nordisk")
        #expect(item.doseStrength == "1,0 mg / Dosis")
        #expect(item.containerType == .pen)
    }

    @Test("#52: a pre-v1.31.0 row without the fields still decodes (nil, not a throw)")
    func penDetailAbsentDecodes() throws {
        let json = Data(#"{"id":"inv-old","unitsTotal":30}"#.utf8)
        let item = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: json)
        #expect(item.manufacturer == nil)
        #expect(item.doseStrength == nil)
    }

    @Test("#52: an explicit null pen detail decodes to nil")
    func penDetailNullDecodes() throws {
        let json = Data(#"{"id":"i","unitsTotal":4,"manufacturer":null,"doseStrength":null}"#.utf8)
        let item = try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: json)
        #expect(item.manufacturer == nil)
        #expect(item.doseStrength == nil)
    }

    @Test("#52: pen detail survives the encode→decode round-trip")
    func penDetailRoundTrips() throws {
        let original = MedicationInventoryItemDTO(
            id: "inv-rt",
            userId: "u-1",
            medicationId: "m-1",
            state: "ACTIVE",
            unitsTotal: 4,
            unitsRemaining: 4,
            containerType: .pen,
            manufacturer: "Lilly",
            doseStrength: "2,5 mg"
        )
        let data = try JSONEncoder.hlDefault.encode(original)
        #expect(try JSONDecoder.hlDefault.decode(MedicationInventoryItemDTO.self, from: data) == original)
    }

    @Test("#52: the create body sends manufacturer + doseStrength + containerType")
    func createBodyCarriesPenDetail() throws {
        let body = MedicationInventoryCreate(
            unitsTotal: 4,
            containerType: .pen,
            manufacturer: "Novo Nordisk",
            doseStrength: "1,0 mg"
        )
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder.hlDefault.encode(body)
        ) as? [String: Any]
        let json = try #require(object)
        #expect(json["manufacturer"] as? String == "Novo Nordisk")
        #expect(json["doseStrength"] as? String == "1,0 mg")
        #expect(json["containerType"] as? String == "PEN")
    }

    @Test("#52: an omitted pen detail is not sent as null on create")
    func createBodyOmitsAbsentPenDetail() throws {
        let body = MedicationInventoryCreate(unitsTotal: 30, containerType: .blister)
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder.hlDefault.encode(body)
        ) as? [String: Any]
        let json = try #require(object)
        #expect(json["manufacturer"] == nil)
        #expect(json["doseStrength"] == nil)
    }

    // MARK: - No blank pen cards

    @Test("#52: a row with neither detail field is NOT a pen entry")
    func genericContainerIsNotAPen() {
        let tabletPack = MedicationInventoryItemDTO(
            id: "inv-tab", userId: "u", medicationId: "m", state: "ACTIVE",
            unitsTotal: 30, unitsRemaining: 30, containerType: .blister
        )
        #expect(PenInventoryStore.penDetail(from: tabletPack) == nil)
    }

    @Test("#52: whitespace-only detail is treated as absent (no blank card)")
    func whitespaceDetailIsNotAPen() {
        let blank = MedicationInventoryItemDTO(
            id: "inv-blank", userId: "u", medicationId: "m", state: "ACTIVE",
            unitsTotal: 4, unitsRemaining: 4, containerType: .pen,
            manufacturer: "   ", doseStrength: "\n"
        )
        #expect(PenInventoryStore.penDetail(from: blank) == nil)
    }

    @Test("#52: one populated field is enough to qualify; the empty half stays empty")
    func partialDetailQualifies() throws {
        let partial = MedicationInventoryItemDTO(
            id: "inv-partial", userId: "u", medicationId: "m", state: "ACTIVE",
            unitsTotal: 4, unitsRemaining: 4, containerType: .pen,
            manufacturer: "Novo Nordisk", doseStrength: nil
        )
        let detail = try #require(PenInventoryStore.penDetail(from: partial))
        #expect(detail.manufacturer == "Novo Nordisk")
        #expect(detail.doseStrength.isEmpty, "the missing half must not be invented")
    }

    // MARK: - B2 — the expiry clock is no longer blanket

    @Test("B2: only PEN and AMPOULE run the 30-day-after-opening clock")
    func firstUseClockAppliesToPenAndAmpouleOnly() {
        #expect(MedicationContainerType.pen.usesFirstUseExpiryClock)
        #expect(MedicationContainerType.ampoule.usesFirstUseExpiryClock)
        for type in [MedicationContainerType.blister, .inhaler, .bottle, .other] {
            #expect(!type.usesFirstUseExpiryClock, "\(type.rawValue) expires on the printed date only")
        }
    }

    @Test("B2: the expiry copy differs per container form and names the right rule")
    func expiryCopyMatchesTheForm() {
        let penRule = MedicationContainerType.pen.localizedExpiryRule
        let blisterRule = MedicationContainerType.blister.localizedExpiryRule
        #expect(penRule != blisterRule)
        #expect(penRule == MedicationContainerType.ampoule.localizedExpiryRule)
        // The 30-day clock may ONLY be claimed for pen / ampoule.
        #expect(penRule.contains("30"))
        for type in [MedicationContainerType.blister, .inhaler, .bottle, .other] {
            #expect(
                !type.localizedExpiryRule.contains("30"),
                "\(type.rawValue) must not claim the 30-day clock (server v1.33.0)"
            )
            #expect(type.localizedExpiryRule == blisterRule)
        }
    }

    @Test("B2: a row without a containerType falls back to the printed-date-only rule")
    func absentContainerTypeUsesPrintedOnly() {
        #expect(
            MedicationContainerType.expiryRule(for: nil)
                == MedicationContainerType.other.localizedExpiryRule
        )
        #expect(
            MedicationContainerType.expiryRule(for: .pen)
                == MedicationContainerType.pen.localizedExpiryRule
        )
    }
}
