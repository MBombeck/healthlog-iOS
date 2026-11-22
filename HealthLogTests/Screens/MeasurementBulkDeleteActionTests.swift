@testable import HealthLog
import Testing

/// The bottom bar's bulk delete of the measurement list: several readings go
/// only after the question, and the confirmed answer deletes them once.
@MainActor
@Suite("Measurement list bulk delete asks first and deletes once")
struct MeasurementBulkDeleteActionTests {
    @Test("several readings need the question and never a full swipe")
    func asksFirst() {
        let action = MeasurementListScreen.bulkDeleteAction(count: 2) {}
        #expect(action.requiresConfirmation)
        #expect(!action.allowsFullSwipe)
    }

    @Test("the confirmed answer runs the delete of the selection once")
    func deletesOnce() async {
        var deleted: [Int] = []
        let selection = 3
        let action = MeasurementListScreen.bulkDeleteAction(count: selection) { deleted.append(selection) }
        let ran = await HLDeleteRunner().run(action)
        #expect(ran)
        #expect(deleted == [3])
    }
}
