import Foundation
@testable import HealthLog
import Testing

/// **W-VORSORGE-DETAIL (b244) — pure detail-arm routing + chart-point derivation.**
///
/// The detail sheet rests on these two decisions the way the card rests on
/// `VorsorgeCard.primaryAction` / `.dueBucket`: which arm a reminder opens
/// (screening → metric → free-text) and how the linked metric's readings become
/// chart points. Pinned without a view host.
@Suite("Vorsorge detail arm + chart points")
struct VorsorgeDetailArmTests {
    private static func row(type: String?) -> MeasurementReminderRow {
        MeasurementReminderRow(
            id: "r1",
            label: "Reminder",
            measurementType: type,
            intervalDays: 30,
            rrule: nil,
            endsOn: nil,
            origin: .vorsorge,
            notifyHour: 9,
            location: nil,
            nextDueAt: nil,
            lastSatisfiedAt: nil,
            enabled: true
        )
    }

    // MARK: - Detail arm routing

    @Test(
        "detailArm routes screening first, then a capture-mappable metric, else free-text",
        arguments: [
            ("PHQ9_SCORE", VorsorgeCard.DetailArm.screening(.phq9)),
            ("GAD7_SCORE", .screening(.gad7)),
            ("WHO5_SCORE", .screening(.who5)),
            ("SCI_SCORE", .screening(.sci)),
            ("WEIGHT", .metric(.weight)),
            ("BLOOD_PRESSURE_SYS", .metric(.bloodPressure)),
            ("MUSCLE_MASS", .freeText), // known type, but not capture-mappable → free-text
            ("SOME_FUTURE_TYPE", .freeText) // unknown wire → free-text
        ]
    )
    func detailArmRouting(_ type: String, _ expected: VorsorgeCard.DetailArm) {
        #expect(VorsorgeCard.detailArm(for: Self.row(type: type)) == expected)
    }

    @Test("a free-text reminder (nil measurementType) resolves to the free-text arm")
    func detailArmFreeText() {
        #expect(VorsorgeCard.detailArm(for: Self.row(type: nil)) == .freeText)
    }

    // MARK: - Chart points (metric arm)

    @Test("chartPoints reverses the server's newest-first list to oldest → newest")
    func chartPointsOrder() throws {
        // Newest-first, as the server returns them.
        let newestFirst = [
            Measurement(id: "c", kind: .weight, recordedAt: Date(timeIntervalSince1970: 300), value: .scalar(12)),
            Measurement(id: "b", kind: .weight, recordedAt: Date(timeIntervalSince1970: 200), value: .scalar(11)),
            Measurement(id: "a", kind: .weight, recordedAt: Date(timeIntervalSince1970: 100), value: .scalar(10))
        ]
        let points = try #require(VorsorgeCard.chartPoints(from: newestFirst))
        #expect(points.map(\.id) == ["a", "b", "c"])
        #expect(points.map(\.value) == [10, 11, 12])
    }

    @Test("chartPoints returns nil for fewer than two points (one dot is no trend)")
    func chartPointsTooThin() {
        #expect(VorsorgeCard.chartPoints(from: []) == nil)
        let one = [Measurement(id: "only", kind: .weight, recordedAt: Date(timeIntervalSince1970: 100), value: .scalar(9))]
        #expect(VorsorgeCard.chartPoints(from: one) == nil)
    }

    @Test("chartPoints extracts the systolic component as a BP row's primaryValue")
    func chartPointsBloodPressure() throws {
        let rows = [
            Measurement(
                id: "bp2",
                kind: .bloodPressure,
                recordedAt: Date(timeIntervalSince1970: 200),
                value: .bloodPressure(systolic: 128, diastolic: 82)
            ),
            Measurement(
                id: "bp1",
                kind: .bloodPressure,
                recordedAt: Date(timeIntervalSince1970: 100),
                value: .bloodPressure(systolic: 120, diastolic: 80)
            )
        ]
        let points = try #require(VorsorgeCard.chartPoints(from: rows))
        // Oldest → newest, systolic is the plotted value.
        #expect(points.map(\.value) == [120, 128])
    }
}
