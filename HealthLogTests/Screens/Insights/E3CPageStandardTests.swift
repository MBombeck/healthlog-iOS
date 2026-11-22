import SwiftUI
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// The detail pages of Insights, charts and custom metrics in the app's one
/// form: the period choice in the floating bar at the bottom edge, the bar
/// actions in their fixed places. Pure value checks, no view.
@Suite("E3-C — period choice, page actions")
@MainActor
struct E3CPageStandardTests {
    @Test("the floating period capsule is narrow and becomes a menu from the first accessibility size")
    func floatingPeriodForm() {
        #expect(HLFloatingPeriodControl<MoodPeriod>.maxWidth <= 320)
        #expect(!HLFloatingPeriodControl<MoodPeriod>.usesMenu(at: .xxxLarge))
        #expect(HLFloatingPeriodControl<ChartDetailStore.Range>.usesMenu(at: .accessibility1))
    }

    @Test("every period choice of the area is the shared picker: segments, a menu from the first accessibility size")
    func periodChoiceForm() {
        #expect(!HLPeriodPicker<MoodPeriod>.usesMenu(at: .xxxLarge))
        #expect(HLPeriodPicker<MoodPeriod>.usesMenu(at: .accessibility1))
        #expect(!HLPeriodPicker<CustomMetricSeries.Range>.usesMenu(at: .large))
        #expect(HLPeriodPicker<ChartDetailStore.Range>.usesMenu(at: .accessibility5))
        #expect(HLPeriodPicker<ChartDetailStore.Range>.identifier == "hl.periodPicker")
    }

    @Test("a custom metric logs a value with the plus at the edge and edits its definition under More")
    func customMetricActions() {
        let actions = CustomMetricDetailScreen.pageActions(hasMetric: true, editDefinition: {}, logValue: {})
        #expect(actions.items.map(\.role) == [.more, .add])
        #expect(actions.items.map(\.systemImage) == ["ellipsis", "plus"])
        #expect(actions.items.map(\.identifier) == ["customMetric.detail.more", "customMetric.detail.add"])
        #expect(!actions.items.contains { $0.systemImage == "slider.horizontal.3" })
    }

    @Test("a custom metric that is not loaded has no bar actions")
    func customMetricWithoutMetric() {
        let actions = CustomMetricDetailScreen.pageActions(hasMetric: false, editDefinition: {}, logValue: {})
        #expect(actions.items.isEmpty)
    }

    @Test("the plus runs the log action, not the editor")
    func customMetricPlusLogsAValue() {
        var logged = 0
        var edited = 0
        let actions = CustomMetricDetailScreen.pageActions(
            hasMetric: true,
            editDefinition: { edited += 1 },
            logValue: { logged += 1 }
        )
        guard let add = actions.items.first(where: { $0.role == .add }), case let .button(run) = add.kind else {
            Issue.record("no add button")
            return
        }
        run()
        #expect(logged == 1)
        #expect(edited == 0)
    }
}
