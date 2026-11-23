import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The Today hero while it loads and once it has loaded: the skeleton keeps
/// the place of one hint, so a day with a hint arrives without the page
/// jumping by a card. Measured as laid-out heights, not bitmaps.
@MainActor
@Suite("Today hero: skeleton holds the hint's place, check-in answers keep 44 pt")
struct N2TodayHeroSkeletonTests {
    @Test(
        "the skeleton is the hero silhouette plus a hint as high as a loaded one",
        arguments: [(DynamicTypeSize.large, CGFloat(1)), (.accessibility3, CGFloat(8))]
    )
    func skeletonHoldsOneHint(size: DynamicTypeSize, tolerance: CGFloat) throws {
        let skeleton = try Self.height(of: TodayHeroSkeleton(), size: size)
        let heroOnly = try Self.height(of: TodayHeroSkeleton.heroCard, size: size)
        let loadedHint = try Self.height(of: Self.section([Self.hint(actions: [])]), size: size)

        #expect(loadedHint > 0)
        // Redacted lines round their boxes a little differently from live
        // text once the hint wraps at accessibility sizes; a few points are
        // no jump, a missing card would be.
        #expect(abs(skeleton - (heroOnly + HLLayout.cardGap + loadedHint)) <= tolerance)
    }

    @Test("a hint with one action is as high as the placeholder hint")
    func oneActionHintMatchesPlaceholder() throws {
        let placeholder = try Self.height(of: TodayHeroSkeleton.hint, size: .large)
        let loaded = try Self.height(
            of: Self.section([Self.hint(actions: [Self.action("daily.action.viewMilestone", "milestone.view")])]),
            size: .large
        )
        #expect(abs(placeholder - loaded) <= 1)
    }

    @Test("the coach check-in answers add a row at least 44 pt high")
    func checkInAnswersKeepTheMinimum() throws {
        let plain = try Self.height(of: Self.section([Self.hint(actions: [])]), size: .large)
        let answers = try Self.height(
            of: Self.section([Self.hint(actions: [
                Self.action("daily.action.checkinKeep", "coach.checkin.keep:p1"),
                Self.action("daily.action.checkinLetGo", "coach.checkin.letgo:p1")
            ])]),
            size: .large
        )
        #expect(answers - plain >= HLHitTarget.minimum + HLSpace.md - 1)
    }

    // MARK: - Helpers

    private static func section(_ items: [DailyPriorityItem]) -> some View {
        TodayHeroWorthALookSection(items: items, onAction: { _, _ in }, onDismiss: { _ in })
    }

    private static func action(_ labelKey: String, _ intent: String) -> DailyPriorityItem.Action {
        DailyPriorityItem.Action(labelKey: labelKey, intent: intent, href: nil)
    }

    /// Same text lengths as the placeholder, so the comparison is about the
    /// structure and not about how a sentence happens to wrap.
    private static func hint(actions: [DailyPriorityItem.Action]) -> DailyPriorityItem {
        DailyPriorityItem(
            kind: "milestone",
            itemKey: nil,
            title: TodayHeroSkeleton.placeholderHint.title,
            body: TodayHeroSkeleton.placeholderHint.body,
            status: nil,
            actions: actions,
            moduleKey: nil
        )
    }

    private static func height(of view: some View, width: CGFloat = 360, size: DynamicTypeSize) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .dynamicTypeSize(size)
        )
        renderer.scale = 1
        let image = try #require(renderer.uiImage, "view failed to render")
        return image.size.height
    }
}
