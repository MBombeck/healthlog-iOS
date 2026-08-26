import Foundation
@testable import HealthLog
import Testing

/// Locks the server-true wire shapes for the GLP-1 detail endpoints.
///
/// These tests decode against committed fixtures matching what the server
/// emits today (server `route.ts:91-105` + `route.ts:38-106`). A breaking
/// server change fails these tests before reaching production.
@Suite("GLP-1 wire shapes")
struct Glp1WireTests {
    private let decoder = JSONDecoder.hlDefault

    // MARK: - /medications/[id]/glp1

    @Test("Glp1DetailsDTO decodes a full Tirzepatide payload")
    func decodesFullTirzepatide() throws {
        let json = Data(#"""
        {
            "doseChanges": [
                {
                    "id": "dc_1",
                    "effectiveFrom": "2026-04-01T00:00:00.000Z",
                    "doseValue": 5.0,
                    "doseUnit": "mg",
                    "note": "Initial titration"
                },
                {
                    "id": "dc_2",
                    "effectiveFrom": "2026-05-01T00:00:00.000Z",
                    "doseValue": 7.5,
                    "doseUnit": "mg",
                    "note": null
                }
            ],
            "recentIntakes": [
                { "takenAt": "2026-05-08T08:00:00.000Z", "injectionSite": "abdomen" },
                { "takenAt": "2026-05-01T08:00:00.000Z", "injectionSite": null }
            ],
            "inventory": {
                "pensRemaining": 3,
                "dosesRemaining": 12,
                "weeksOfSupply": 12,
                "lowStock": false
            }
        }
        """#.utf8)
        let dto = try decoder.decode(Glp1DetailsDTO.self, from: json)
        #expect(dto.doseChanges.count == 2)
        #expect(dto.doseChanges[0].doseValue == 5.0)
        #expect(dto.doseChanges[1].note == nil)
        #expect(dto.recentIntakes.count == 2)
        #expect(dto.recentIntakes[1].injectionSite == nil)
        #expect(dto.inventory?.pensRemaining == 3)
        #expect(dto.inventory?.lowStock == false)
    }

    @Test("Glp1DetailsDTO decodes when inventory is null")
    func decodesNullInventory() throws {
        let json = Data(#"""
        {
            "doseChanges": [],
            "recentIntakes": [],
            "inventory": null
        }
        """#.utf8)
        let dto = try decoder.decode(Glp1DetailsDTO.self, from: json)
        #expect(dto.inventory == nil)
        #expect(dto.doseChanges.isEmpty)
        #expect(dto.recentIntakes.isEmpty)
    }

    @Test("Glp1RecentIntakeDTO accepts null takenAt")
    func recentIntakeNullTakenAt() throws {
        let json = Data(#"""
        { "takenAt": null, "injectionSite": null }
        """#.utf8)
        let dto = try decoder.decode(Glp1RecentIntakeDTO.self, from: json)
        #expect(dto.takenAt == nil)
        #expect(dto.injectionSite == nil)
    }

    // MARK: - Paginated intake

    @Test("PaginatedIntakeEnvelope decodes server shape")
    func paginatedIntake() throws {
        let json = Data(#"""
        {
            "events": [
                {
                    "id": "ev_1",
                    "takenAt": "2026-05-08T08:00:00.000Z",
                    "skipped": false,
                    "scheduledFor": "2026-05-08T08:00:00.000Z",
                    "injectionSite": "abdomen"
                },
                {
                    "id": "ev_2",
                    "takenAt": null,
                    "skipped": true,
                    "scheduledFor": "2026-05-01T08:00:00.000Z",
                    "injectionSite": null
                }
            ],
            "meta": { "total": 2, "limit": 20, "offset": 0 }
        }
        """#.utf8)
        let env = try decoder.decode(PaginatedIntakeEnvelope.self, from: json)
        #expect(env.events.count == 2)
        #expect(env.events[0].skipped == false)
        #expect(env.events[1].takenAt == nil)
        #expect(env.events[1].skipped == true)
        #expect(env.meta.total == 2)
    }
}
