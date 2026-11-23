import SwiftUI

/// How the row under the lead sentence is laid out. The view only reads the
/// answer; the decision stays testable without rendering.
enum TodayHeroReadLayout: Equatable, Sendable {
    /// The facts beside the trailing ring, both on one vertical centre.
    case columnBesideRing
    /// Large text sizes: the facts first, the ring centred under them.
    case columnAboveRing
    /// A score with nothing beside it: the ring alone, centred in the card.
    case ringCentred
    /// No score: the facts take the full width of the card.
    case columnFullWidth
    /// Neither score nor facts: no row at all.
    case none

    static func resolve(hasScore: Bool, hasLeftContent: Bool, stacked: Bool) -> TodayHeroReadLayout {
        switch (hasScore, hasLeftContent) {
        case (false, false): .none
        case (false, true): .columnFullWidth
        case (true, false): .ringCentred
        case (true, true): stacked ? .columnAboveRing : .columnBesideRing
        }
    }

    /// From this text size on a one-line value no longer fits beside the
    /// ring, so the facts and the ring stand on top of each other.
    static func stacks(_ size: DynamicTypeSize) -> Bool {
        size >= .xxLarge
    }

    /// Two equal columns only where the facts have the whole card to
    /// themselves; beside the ring or stacked a second column would squeeze
    /// the values.
    func factColumns(factCount: Int, stacked: Bool) -> Int {
        self == .columnFullWidth && factCount >= 2 && !stacked ? 2 : 1
    }
}

/// The hero's facts beside the ring: up to four equally built pairs, a
/// caption label over a one-line value (`today[]`, pre-formatted by the
/// server). The sleep fact keeps only its duration; the comparison with the
/// usual night would break the one line.
struct TodayHeroFacts: View {
    let digest: DailyDigest
    var columns: Int = 1
    /// At accessibility sizes a value may wrap instead of shrinking away.
    var wrapsValues: Bool = false
    /// 1.7: the medication fact counts the confirmed today rows.
    var medicationState: MedicationTodayState = .unknown

    var body: some View {
        let facts = Self.facts(digest)
        if !facts.isEmpty {
            factGroup(facts)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("today.hero.facts")
        }
    }

    @ViewBuilder
    private func factGroup(_ facts: [DailyDigest.TodayFact]) -> some View {
        if columns >= 2 {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: HLLayout.cardGap, alignment: .topLeading),
                    count: columns
                ),
                alignment: .leading,
                spacing: Self.pairSpacing
            ) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    pair(fact)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Self.pairSpacing) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    pair(fact)
                }
            }
        }
    }

    /// Label above, value under it; every pair the same build: the stacked
    /// fact pair, label in the row subtitle role, value in the row value role.
    private func pair(_ fact: DailyDigest.TodayFact) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            line(Text(verbatim: fact.label))
                .hlText(.rowSubtitle)
            line(Text(verbatim: Self.displayValue(fact, medicationState: medicationState)))
                .hlText(.rowValue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func line(_ text: Text) -> some View {
        text
            .lineLimit(wrapsValues ? nil : 1)
            .minimumScaleFactor(wrapsValues ? 1 : Self.valueMinimumScale)
            .allowsTightening(true)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One gap between all pairs, so the column reads as a calm list.
    static let pairSpacing = HLSpace.md
    /// How far a long value may shrink to stay on its one line.
    static let valueMinimumScale: CGFloat = 0.8
    /// Three or four facts carry the day; a fifth would outgrow the ring.
    static let maxFacts = 4

    static func facts(_ digest: DailyDigest) -> [DailyDigest.TodayFact] {
        Array(digest.today.prefix(maxFacts))
    }

    /// The value as shown. Sleep arrives as "duration, comparison"; the hero
    /// shows the duration only. A decimal comma has no space after it, so
    /// "7,5 Std." stays whole.
    static func displayValue(_ fact: DailyDigest.TodayFact, medicationState: MedicationTodayState = .unknown) -> String {
        if MedicationDigestFilter.isMedicationFact(fact) {
            return MedicationDigestFilter.factValue(server: fact.value, state: medicationState)
        }
        guard fact.kind == "sleep", let comma = fact.value.range(of: ", ") else { return fact.value }
        return String(fact.value[..<comma.lowerBound])
    }

    /// Whether the left side has anything to carry. Without a ring the
    /// footnotes stand there instead of under it.
    static func hasContent(_ digest: DailyDigest) -> Bool {
        !digest.today.isEmpty || (digest.score == nil && !footnotes(digest).isEmpty)
    }

    /// Rest Mode and the steady weeks, each only when the server said so.
    /// Small lines under the ring's word, never a sentence under the lead.
    static func footnotes(_ digest: DailyDigest) -> [String] {
        var lines: [String] = []
        if let restMode = digest.restMode, restMode.day > 0 {
            lines.append(String(localized: "today.restMode.day \(restMode.day)"))
        }
        if let weeks = digest.score?.steadyWeeks, weeks > 0 {
            lines.append(
                digest.score?.steadyAtLeast == true
                    ? String(localized: "today.hero.steadyAtLeast \(weeks)")
                    : String(localized: "today.hero.steady \(weeks)")
            )
        }
        return lines
    }
}

/// One footnote line: caption, secondary text.
struct TodayHeroFootnote: View {
    let text: String
    var alignment: TextAlignment = .center

    var body: some View {
        Text(verbatim: text)
            .hlText(.rowSubtitle)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}
