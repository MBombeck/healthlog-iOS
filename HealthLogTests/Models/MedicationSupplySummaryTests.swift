import Foundation
@testable import HealthLog
import Testing

/// #25 / #115 · 1.3 — the Bestand headline renders the server's `summary`
/// (`GET /api/medications/{id}/inventory`, `MedicationSupplySummary` in
/// `docs/api/openapi.yaml` at `v1.39.0`) instead of summing containers on the
/// device, and `expiredUnits` reaches the screen.
@Suite("Medication supply summary (#25, #115 1.3)")
struct MedicationSupplySummaryTests {
    private struct Env: Decodable { let data: MedicationInventoryListDTO }

    private static let v139 = #"""
    {"data":{
      "items":[
        {"id":"a","userId":"u","medicationId":"m","state":"IN_USE","unitsTotal":30,"unitsRemaining":12},
        {"id":"b","userId":"u","medicationId":"m","state":"ACTIVE","unitsTotal":30,"unitsRemaining":30},
        {"id":"c","userId":"u","medicationId":"m","state":"EXPIRED","unitsTotal":30,"unitsRemaining":10}
      ],
      "summary":{"unitsRemaining":42,"unitsTotal":60,"dosesRemaining":21,"dosesTotal":30,"expiredUnits":10},
      "meta":{"total":3}
    },"error":null}
    """#

    @Test("summary decodes next to the items")
    func decodesSummary() throws {
        let list = try JSONDecoder.hlDefault.decode(Env.self, from: Data(Self.v139.utf8)).data
        #expect(list.items.count == 3)
        #expect(list.summary == MedicationSupplySummary(
            unitsRemaining: 42, unitsTotal: 60, dosesRemaining: 21, dosesTotal: 30, expiredUnits: 10
        ))
    }

    @Test("the capacity is the server's dose total, not a local sum of unitsTotal")
    func capacityFromServer() throws {
        let list = try JSONDecoder.hlDefault.decode(Env.self, from: Data(Self.v139.utf8)).data
        // A local sum over ACTIVE/IN_USE units (60) ÷ unitsPerDose would have
        // read 60 for a 1-unit dose; the server says 30 whole doses.
        #expect(MedicationInventorySection.capacityDoseString(list.summary) == "30")
    }

    @Test("expired units are named, and only when there are some")
    func expiredUnits() throws {
        let list = try JSONDecoder.hlDefault.decode(Env.self, from: Data(Self.v139.utf8)).data
        #expect(MedicationInventorySection.expiredUnitsString(list.summary) == "10")
        let none = MedicationSupplySummary(unitsRemaining: 1, unitsTotal: 1, dosesRemaining: 1, dosesTotal: 1, expiredUnits: 0)
        #expect(MedicationInventorySection.expiredUnitsString(none) == nil)
    }

    @Test("a server before v1.19 (no summary) shows — for the capacity, never a guess")
    func olderServer() throws {
        let json = #"{"data":{"items":[{"id":"a","unitsTotal":30,"unitsRemaining":12}],"meta":{"total":1}}}"#
        let list = try JSONDecoder.hlDefault.decode(Env.self, from: Data(json.utf8)).data
        #expect(list.summary == nil)
        #expect(MedicationInventorySection.capacityDoseString(list.summary) == InventorySanity.placeholder)
        #expect(MedicationInventorySection.expiredUnitsString(list.summary) == nil)
    }
}
