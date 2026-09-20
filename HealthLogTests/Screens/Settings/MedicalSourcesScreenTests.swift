@testable import HealthLog
import Testing

@Suite("MedicalSourcesScreen — grouping covers the catalog")
struct MedicalSourcesScreenTests {
    @Test("every id lands in exactly one non-empty group")
    func partition() {
        for id in MedicalSourceID.allCases {
            let groups = MedicalSourcesScreen.Group.allCases.filter { $0.contains(id) }
            #expect(groups.count == 1, "\(id.rawValue) in \(groups)")
        }
        for g in MedicalSourcesScreen.Group.allCases {
            #expect(MedicalSourceCatalog.all.contains(where: { g.contains($0.id) }), "group \(g) is empty")
        }
    }
}
