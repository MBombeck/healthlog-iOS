import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The quieter Today hero: a smaller lead of at most three lines, no grey
/// line under it, three or four equal fact pairs beside the ring and the
/// steady weeks as a footnote under the ring. The skeleton has the loaded
/// card's height, so the data arrives without a jump.
@MainActor
@Suite("Today hero: smaller lead, equal fact pairs, footnote under the ring")
struct TodayHeroQuietCardTests {
    @Test("the lead is capped at three lines")
    func leadLineCap() {
        #expect(TodayHeroCard.leadLineLimit == 3)
    }

    @Test("the sleep fact shows its duration only", arguments: [
        ("8 Std. 34 Min., 1 Std. 22 Min. mehr als sonst", "8 Std. 34 Min."),
        ("7 Std. 12 Min., so lang wie sonst", "7 Std. 12 Min."),
        ("7,5 Std.", "7,5 Std."),
        ("6 Std. 19 Min.", "6 Std. 19 Min.")
    ])
    func sleepDuration(value: String, shown: String) {
        let fact = DailyDigest.TodayFact(kind: "sleep", label: "Letzte Nacht", value: value, href: nil, moduleKey: nil)
        #expect(TodayHeroFacts.displayValue(fact) == shown)
    }

    @Test("other facts are shown as delivered, commas and all")
    func otherFactsVerbatim() {
        let fact = DailyDigest.TodayFact(
            kind: "vitals", label: "Vitalwerte", value: "4 geprüft, alle im Bereich", href: nil, moduleKey: nil
        )
        #expect(TodayHeroFacts.displayValue(fact) == "4 geprüft, alle im Bereich")
    }

    @Test("the signal line no longer stands in the hero")
    func signalLineIsGone() throws {
        let digest = try Self.decode(
            #"{"date":"2026-11-14","lead":"x","signalLine":{"headline":null,"delta":"-2 bpm vs. dein 7- und 30-Tage-Mittel"}}"#
        )
        #expect(digest.signalText != nil)
        #expect(!TodayHeroFacts.hasContent(digest))
    }

    @Test("the steady weeks become the footnote under the ring")
    func steadyWeeksFootnote() throws {
        let digest = try Self.decode(
            #"{"date":"2026-11-14","lead":"x","score":{"value":74,"band":"green","delta":null,"steadyWeeks":5}}"#
        )
        #expect(TodayHeroFacts.footnotes(digest) == [String(localized: "today.hero.steady \(5)")])
        // The footnote rides the ring, so it is no left content of its own.
        #expect(!TodayHeroFacts.hasContent(digest))
    }

    @Test("without a ring, Rest Mode stands on the left instead")
    func restModeWithoutScore() throws {
        let digest = try Self.decode(#"{"date":"2026-11-14","lead":"x","restMode":{"day":2}}"#)
        #expect(TodayHeroFacts.hasContent(digest))
        #expect(TodayHeroFacts.footnotes(digest) == [String(localized: "today.restMode.day \(2)")])
    }

    @Test("facts and ring stack from the extra-extra-large text size on", arguments: [
        (DynamicTypeSize.large, false), (.xLarge, false), (.xxLarge, true), (.accessibility5, true)
    ])
    func stackingThreshold(size: DynamicTypeSize, stacks: Bool) {
        #expect(TodayHeroReadLayout.stacks(size) == stacks)
    }

    @Test("the fact pairs are evenly spaced and equally built")
    func evenPairs() throws {
        let one = try Self.height(of: Self.facts(count: 1), size: .large)
        let two = try Self.height(of: Self.facts(count: 2), size: .large)
        let three = try Self.height(of: Self.facts(count: 3), size: .large)
        #expect(abs((two - one) - (three - two)) <= 1)
        #expect(abs((two - one) - (one + TodayHeroFacts.pairSpacing)) <= 1)
    }

    @Test(
        "the skeleton card is as high as the loaded card",
        arguments: [(DynamicTypeSize.large, CGFloat(2)), (.xxxLarge, CGFloat(2))]
    )
    func skeletonMatchesLoadedCard(size: DynamicTypeSize, tolerance: CGFloat) throws {
        let skeleton = try Self.height(of: TodayHeroSkeleton.heroCard, size: size)
        let loaded = try Self.height(
            of: TodayHeroCard(digest: TodayHeroSkeleton.placeholderDigest, onRingTap: {}),
            size: size
        )
        #expect(abs(skeleton - loaded) <= tolerance)
    }

    @Test("a lead longer than three lines does not grow the card at the standard size")
    func longLeadKeepsHeight() throws {
        let base = TodayHeroSkeleton.placeholderDigest
        let longer = DailyDigest(
            generatedAt: base.generatedAt,
            phase: base.phase,
            sleepPending: false,
            score: base.score,
            topSignal: nil,
            briefingLead: nil,
            line: String(repeating: base.lead + " ", count: 3),
            worthALook: [],
            today: base.today
        )
        let short = try Self.height(of: TodayHeroCard(digest: base, onRingTap: {}), size: .large)
        let long = try Self.height(of: TodayHeroCard(digest: longer, onRingTap: {}), size: .large)
        #expect(abs(short - long) <= 1)
    }

    // MARK: - Helpers

    private static func facts(count: Int) -> some View {
        let digest = DailyDigest(
            generatedAt: "",
            phase: "final",
            sleepPending: false,
            score: nil,
            topSignal: nil,
            briefingLead: nil,
            line: "x",
            worthALook: [],
            today: Array(TodayHeroSkeleton.placeholderDigest.today.prefix(count))
        )
        return TodayHeroFacts(digest: digest)
    }

    private static func decode(_ json: String) throws -> DailyDigest {
        try JSONDecoder.hlDefault.decode(DailyDigest.self, from: Data(json.utf8))
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
