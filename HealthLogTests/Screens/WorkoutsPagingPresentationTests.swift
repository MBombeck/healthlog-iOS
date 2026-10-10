import CoreGraphics
import Foundation
@testable import HealthLog
import Testing

/// #19 — the count line, the end-of-list row and the Insights scroll trigger.
/// The header used to read "50 workouts" for a user with 730: the page size
/// dressed up as a total.
@Suite("#19 Workouts paging — header, footer, trigger")
@MainActor
struct WorkoutsPagingPresentationTests {
    @Test("partial list: the header names loaded rows AND the server total")
    func partialHeader() {
        let text = WorkoutsListSummary.headerText(loaded: 50, total: 730)
        #expect(text == String(localized: "workouts.count.partial \(50) \(730)"))
        #expect(text.contains("50") && text.contains("730"))
        #expect(text != String(localized: "insights.workoutsCount \(50)"), "the page size is not the total")
    }

    @Test("complete list: the header is the plain total")
    func completeHeader() {
        #expect(WorkoutsListSummary.headerText(loaded: 730, total: 730) == String(localized: "insights.workoutsCount \(730)"))
        // A total that shrank below the loaded rows still reads the server's number.
        #expect(WorkoutsListSummary.headerText(loaded: 61, total: 60) == String(localized: "insights.workoutsCount \(60)"))
        // Before the first envelope there is no total to show.
        #expect(WorkoutsListSummary.headerText(loaded: 0, total: nil) == String(localized: "insights.workoutsCount \(0)"))
    }

    @Test("VoiceOver: a partial list is announced as loaded-of-total")
    func accessibilityLabel() {
        let label = WorkoutsListSummary.headerAccessibilityLabel(loaded: 50, total: 730)
        #expect(label == String(localized: "workouts.count.partial.a11y \(50) \(730)"))
        #expect(label != WorkoutsListSummary.headerText(loaded: 50, total: 730))
        #expect(
            WorkoutsListSummary.headerAccessibilityLabel(loaded: 730, total: 730)
                == WorkoutsListSummary.headerText(loaded: 730, total: 730)
        )
    }

    @Test("the new strings exist in de and en with both numbers")
    func catalogValues() throws {
        let catalog = try ParityCatalog.load()
        let expected: [String: (en: String, de: String)] = [
            "workouts.count.partial %lld %lld": ("%1$lld of %2$lld workouts", "%1$lld von %2$lld Workouts"),
            "workouts.count.partial.a11y %lld %lld": ("%1$lld of %2$lld workouts loaded", "%1$lld von %2$lld Workouts geladen")
        ]
        for (key, values) in expected {
            let entry = try #require(catalog.strings[key], "missing catalog key \(key)")
            #expect(ParityCatalog.value(entry, language: "en") == values.en)
            #expect(ParityCatalog.value(entry, language: "de") == values.de)
        }
        for key in ["workouts.paging.loading", "workouts.paging.failed", "workouts.paging.end"] {
            let entry = try #require(catalog.strings[key], "missing catalog key \(key)")
            #expect(ParityCatalog.value(entry, language: "en") != nil)
            #expect(ParityCatalog.value(entry, language: "de") != nil)
        }
    }

    @Test("footer: hidden before data, loading while pages are due, error wins, then the end")
    func footerStates() {
        #expect(WorkoutsPagingFooterState.resolve(hasLoadedPage: false, hasMorePages: false, hasPageError: false) == .hidden)
        #expect(WorkoutsPagingFooterState.resolve(hasLoadedPage: false, hasMorePages: true, hasPageError: true) == .hidden)
        #expect(WorkoutsPagingFooterState.resolve(hasLoadedPage: true, hasMorePages: true, hasPageError: false) == .loading)
        #expect(WorkoutsPagingFooterState.resolve(hasLoadedPage: true, hasMorePages: true, hasPageError: true) == .failed)
        #expect(WorkoutsPagingFooterState.resolve(hasLoadedPage: true, hasMorePages: false, hasPageError: false) == .end)
    }

    @Test("Insights trigger: within one screen of the end, not before")
    func insightsNearEnd() {
        // 800 pt screen, 5000 pt of rows.
        #expect(!InsightsWorkoutsPage.isNearEnd(offsetY: 0, containerHeight: 800, contentHeight: 5000))
        #expect(!InsightsWorkoutsPage.isNearEnd(offsetY: 3300, containerHeight: 800, contentHeight: 5000))
        #expect(InsightsWorkoutsPage.isNearEnd(offsetY: 3400, containerHeight: 800, contentHeight: 5000))
        #expect(InsightsWorkoutsPage.isNearEnd(offsetY: 4200, containerHeight: 800, contentHeight: 5000))
        // No layout yet: never fire.
        #expect(!InsightsWorkoutsPage.isNearEnd(offsetY: 0, containerHeight: 0, contentHeight: 0))
    }
}
