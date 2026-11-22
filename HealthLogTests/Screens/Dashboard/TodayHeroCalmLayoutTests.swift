import Foundation
@testable import HealthLog
import Testing

/// The calmer Today hero: the facts stand beside the ring instead of under it,
/// and the "worth a look" hints leave the hero for a section of their own.
/// Every decision the views take is a pure function, pinned here.
@Suite("Today hero: facts beside the ring, hints as their own section")
struct TodayHeroCalmLayoutTests {
    // MARK: - Read row layout

    @Test(
        "every combination of score, left content and stacking has one layout",
        arguments: [
            (false, false, false, TodayHeroReadLayout.none),
            (false, false, true, TodayHeroReadLayout.none),
            (false, true, false, TodayHeroReadLayout.columnFullWidth),
            (false, true, true, TodayHeroReadLayout.columnFullWidth),
            (true, false, false, TodayHeroReadLayout.ringCentred),
            (true, false, true, TodayHeroReadLayout.ringCentred),
            (true, true, false, TodayHeroReadLayout.columnBesideRing),
            (true, true, true, TodayHeroReadLayout.columnAboveRing)
        ]
    )
    func layoutResolves(
        hasScore: Bool,
        hasLeftContent: Bool,
        stacked: Bool,
        expected: TodayHeroReadLayout
    ) {
        #expect(
            TodayHeroReadLayout.resolve(
                hasScore: hasScore,
                hasLeftContent: hasLeftContent,
                stacked: stacked
            ) == expected
        )
    }

    @Test("two or more facts without a score stand in two equal columns")
    func factsWithoutScoreUseTwoColumns() {
        let layout = TodayHeroReadLayout.columnFullWidth
        #expect(layout.factColumns(factCount: 2, stacked: false) == 2)
        #expect(layout.factColumns(factCount: 5, stacked: false) == 2)
        #expect(layout.factColumns(factCount: 1, stacked: false) == 1)
        #expect(layout.factColumns(factCount: 0, stacked: false) == 1)
        // Stacked at large text sizes two columns would cut words; one column.
        #expect(layout.factColumns(factCount: 3, stacked: true) == 1)
    }

    @Test("beside or above the ring the facts stay in one column", arguments: [
        TodayHeroReadLayout.columnBesideRing, .columnAboveRing, .ringCentred, .none
    ])
    func factsBesideRingUseOneColumn(layout: TodayHeroReadLayout) {
        #expect(layout.factColumns(factCount: 4, stacked: false) == 1)
    }

    @Test("a digest with facts and no score lays them out across the full width")
    func factsWithoutScore() throws {
        let digest = try Self.decode(
            #"{"date":"2026-11-13","lead":"Ein ruhiger Tag.","#
                + #""today":[{"kind":"sleep","label":"Letzte Nacht","value":"6 Std. 19 Min.","href":null},"#
                + #"{"kind":"medication","label":"Medikamente","value":"0 von 5 genommen","href":null}]}"#
        )
        #expect(TodayHeroCard.availableScore(digest) == nil)
        #expect(TodayHeroFacts.hasContent(digest))
        let layout = TodayHeroReadLayout.resolve(
            hasScore: false,
            hasLeftContent: TodayHeroFacts.hasContent(digest),
            stacked: false
        )
        #expect(layout == .columnFullWidth)
        #expect(layout.factColumns(factCount: TodayHeroFacts.facts(digest).count, stacked: false) == 2)
        // Shown as delivered, nothing shortened or reworded.
        #expect(TodayHeroFacts.facts(digest).map(\.value) == ["6 Std. 19 Min.", "0 von 5 genommen"])
    }

    @Test("a score with nothing beside it stands alone and centred")
    func scoreAlone() throws {
        let digest = try Self.decode(
            #"{"date":"2026-11-13","lead":"Ein ruhiger Tag.","score":{"value":71,"band":"green","delta":null}}"#
        )
        #expect(!TodayHeroFacts.hasContent(digest))
        #expect(
            TodayHeroReadLayout.resolve(
                hasScore: TodayHeroCard.availableScore(digest) != nil,
                hasLeftContent: TodayHeroFacts.hasContent(digest),
                stacked: false
            ) == .ringCentred
        )
    }

    @Test("without a score, Rest Mode alone counts as left content")
    func statusLineIsLeftContent() throws {
        let digest = try Self.decode(#"{"date":"2026-11-13","lead":"x","restMode":{"day":2}}"#)
        #expect(TodayHeroFacts.hasContent(digest))
    }

    @Test("the facts are capped at four, beside the ring")
    func factsCapped() throws {
        let facts = (1 ... 7).map { #"{"kind":"k\#($0)","label":"L\#($0)","value":"V\#($0)","href":null}"# }
        let digest = try Self.decode(
            #"{"date":"2026-11-13","lead":"x","today":["# + facts.joined(separator: ",") + "]}"
        )
        #expect(TodayHeroFacts.facts(digest).count == TodayHeroFacts.maxFacts)
    }

    // MARK: - Hint cards

    @Test("one action makes the whole card the button")
    func oneActionMakesTheCardTheButton() {
        let action = Self.action("daily.action.viewCheckups", "checkup.view")
        #expect(PriorityRailCardAffordance.resolve([action]) == .wholeCard(action))
    }

    @Test("two or three actions keep their buttons under the text")
    func severalActionsKeepTheirButtons() {
        let keep = Self.action("daily.action.checkinKeep", "coach.checkin.keep:p1")
        let letGo = Self.action("daily.action.checkinLetGo", "coach.checkin.letGo:p1")
        let adjust = Self.action("daily.action.checkinAdjust", "coach.checkin.adjust")
        #expect(PriorityRailCardAffordance.resolve([keep, letGo]) == .buttons([keep, letGo]))
        #expect(PriorityRailCardAffordance.resolve([keep, letGo, adjust]) == .buttons([keep, letGo, adjust]))
    }

    @Test("a hint without an action is a plain card")
    func noActionIsAPlainCard() {
        #expect(PriorityRailCardAffordance.resolve([]) == .none)
    }

    @Test("a fourth action from the server never reaches the card")
    func actionsStayBounded() {
        let actions = (1 ... 4).map { Self.action("daily.action.viewMilestone", "milestone.view.\($0)") }
        let item = Self.item(kind: "milestone", actions: actions)
        #expect(PriorityRailCardAffordance.resolve(item.boundedActions) == .buttons(Array(actions.prefix(3))))
    }

    @Test("the whole-card button speaks its action's title as the hint")
    func wholeCardHintIsTheActionTitle() {
        let action = Self.action("daily.action.viewCheckups", "checkup.view")
        #expect(
            PriorityRailCardAffordance.wholeCard(action).accessibilityHint
                == TodayHeroCopy.actionLabel("daily.action.viewCheckups")
        )
        #expect(PriorityRailCardAffordance.none.accessibilityHint == nil)
    }

    @Test("an empty hint list shows no section and no header")
    func emptyListShowsNoSection() throws {
        #expect(!TodayHeroWorthALookSection.isShown([]))
        let digest = try Self.decode(#"{"date":"2026-11-13","lead":"x","score":{"value":71,"band":"green","delta":null}}"#)
        #expect(!TodayHeroWorthALookSection.isShown(digest.rail))
    }

    @Test("a hint list shows the section")
    func hintListShowsSection() {
        let item = Self.item(kind: "preventive_care", actions: [Self.action("daily.action.viewCheckups", "checkup.view")])
        #expect(TodayHeroWorthALookSection.isShown([item]))
    }

    @Test("no hint card draws a chevron, whether it is one button, several or none")
    func hintCardsShowNoChevron() {
        let one = Self.action("daily.action.viewMilestone", "milestone.view")
        let two = Self.action("daily.action.checkinKeep", "coach.checkin.keep:p1")
        let forms: [PriorityRailCardAffordance] = [.none, .wholeCard(one), .buttons([one, two])]
        #expect(forms.allSatisfy { $0.rowIndicator == .hidden })
    }

    @Test("the dismissible kinds are the observational ones the sweep's milestone belongs to")
    func milestoneIsDismissible() {
        let item = DailyPriorityItem(
            kind: "milestone",
            itemKey: "milestone:steps:2026-11-12",
            title: "Neuer Rekord",
            body: nil,
            status: "success",
            actions: [Self.action("daily.action.viewMilestone", "milestone.view")],
            moduleKey: nil
        )
        #expect(item.isDismissible)
        #expect(PriorityRailCardAffordance.resolve(item.boundedActions) == .wholeCard(item.actions[0]))
    }

    @Test("each action still routes where it did")
    func routesUnchanged() {
        #expect(TodayHeroActionRoute.resolve(intent: "checkup.view", href: nil) == .checkupFrontDoor)
        #expect(TodayHeroActionRoute.resolve(intent: "coach.checkin.keep:p1", href: nil) == .coachKeep(planId: "p1"))
        #expect(TodayHeroActionRoute.resolve(intent: "dose.log", href: nil) == .intakes)
    }

    // MARK: - Helpers

    private static func decode(_ json: String) throws -> DailyDigest {
        try JSONDecoder.hlDefault.decode(DailyDigest.self, from: Data(json.utf8))
    }

    private static func action(_ labelKey: String, _ intent: String) -> DailyPriorityItem.Action {
        DailyPriorityItem.Action(labelKey: labelKey, intent: intent, href: nil)
    }

    private static func item(kind: String, actions: [DailyPriorityItem.Action]) -> DailyPriorityItem {
        DailyPriorityItem(
            kind: kind,
            itemKey: nil,
            title: "Vorsorge fällig",
            body: "Blutdruck messen ist offen.",
            status: "warning",
            actions: actions,
            moduleKey: nil
        )
    }
}
