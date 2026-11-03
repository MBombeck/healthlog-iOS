import SwiftUI

/// #136 (server v1.43, #116 item 6) — the mood pattern cards, back.
///
/// 1.1.0 removed them because they were detected on the device calendar with
/// no statistical gate (#115 · 1.3). They now come from the server
/// (`GET /api/mood/insights` → `patterns[]`): every row passed its gate on the
/// account's mood day, and this section only phrases them, one card per entry
/// in the order delivered; the chip names the strength and the N and M days
/// each rests on.
///
/// - `nil` (a server before v1.43): the host does not draw the section.
/// - `[]` (the server found none): no section (1.4 B2).
/// - A row this build cannot phrase (an unknown `kind`, a direction of
///   `none`, a lower best weekday) is skipped, never guessed at.
///
/// Monochrome by design: the strength is a plain text chip, no colour, and the
/// copy says "tends to", never "because".
struct MoodPatternSection: View {
    /// The server's patterns (`[]` when it found none).
    let patterns: [MoodPattern]

    var body: some View {
        let cards = MoodPatternPresentation.cards(for: patterns)
        // 1.4 B2 — when the server found no pattern there is no card saying
        // "not enough data yet"; the section is absent.
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("mood.patterns.title", flush: true)
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.lg) {
                        ForEach(cards) { card in
                            row(card)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mood.patterns")
        }
    }

    /// The analysis body's index for the recent-entries section: right after
    /// the patterns when the server sent them, in their place otherwise.
    nonisolated static func recentSectionIndex(hasPatterns: Bool) -> Int {
        hasPatterns ? 6 : 5
    }

    private func row(_ card: MoodPatternPresentation.Card) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(spacing: HLSpace.sm) {
                Image(systemName: card.icon)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                HLSectionLabel(verbatim: card.category)
                Spacer(minLength: HLSpace.sm)
                // 1.4 B2 — the chip carries strength and basis ("Mittel, 8 und
                // 22 Tage"); the sentence under every row is gone.
                Text(card.chip)
                    .font(.hlCaption2.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                    .padding(.horizontal, HLSpace.chip)
                    .padding(.vertical, HLSpace.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: HLRadius.xs, style: .continuous)
                            .fill(HLSurface.tertiary)
                    )
            }
            Text(card.sentence)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(card.category))
        .accessibilityValue(Text(card.accessibilityValue))
        .accessibilityIdentifier("mood.pattern.\(card.id)")
    }
}

/// The pure phrasing of the server's patterns, testable without a view.
enum MoodPatternPresentation {
    struct Card: Identifiable, Equatable {
        let id: String
        let category: String
        let icon: String
        let sentence: String
        /// "8 und 22 Tage": the days the comparison rests on.
        let basedOn: String
        /// `nil` for a strength word this build does not know.
        let strength: String?

        /// The row's chip: strength and basis, or the basis alone.
        var chip: String {
            [strength, basedOn].compactMap(\.self).joined(separator: ", ")
        }

        var accessibilityValue: String {
            [sentence, chip].joined(separator: " ")
        }
    }

    /// One card per phrasable entry, in the order the server delivered them.
    static func cards(for patterns: [MoodPattern], locale: Locale = .current) -> [Card] {
        patterns.compactMap { card(for: $0, locale: locale) }
    }

    static func card(for pattern: MoodPattern, locale: Locale = .current) -> Card? {
        guard let sentence = sentence(for: pattern, locale: locale), let look = look(for: pattern.kind) else { return nil }
        let size = pattern.sampleSize
        return Card(
            id: pattern.id,
            category: look.category,
            icon: look.icon,
            sentence: sentence,
            basedOn: String(localized: "mood.patterns.days \(size.subject) \(size.comparison)"),
            strength: strengthLabel(pattern.strength)
        )
    }

    /// The app's own sentence for a kind and direction, carrying the two
    /// averages the server sent. `nil` when the entry cannot be phrased.
    static func sentence(for pattern: MoodPattern, locale: Locale = .current) -> String? {
        let subject = format(pattern.values.subject, locale: locale)
        let comparison = format(pattern.values.comparison, locale: locale)
        let higher: Bool
        switch pattern.direction {
        case .higher: higher = true
        case .lower: higher = false
        case .none, .unknown: return nil
        }
        switch pattern.kind {
        case .previousDay:
            return higher
                ? String(localized: "mood.patterns.previousDayHigher \(subject) \(comparison)")
                : String(localized: "mood.patterns.previousDayLower \(subject) \(comparison)")
        case .weekend:
            return higher
                ? String(localized: "mood.patterns.weekendHigher \(subject) \(comparison)")
                : String(localized: "mood.patterns.weekendLower \(subject) \(comparison)")
        case .bestWeekday:
            // A weekday that is only lower is not a best weekday.
            guard higher, let weekday = weekdayName(pattern.values.weekday, locale: locale) else { return nil }
            return String(localized: "mood.patterns.bestWeekday \(weekday) \(subject) \(comparison)")
        case .notes:
            return higher
                ? String(localized: "mood.patterns.notesHigher \(subject) \(comparison)")
                : String(localized: "mood.patterns.notesLower \(subject) \(comparison)")
        case .delayedTag:
            guard let tag = tagName(pattern.values) else { return nil }
            return higher
                ? String(localized: "mood.patterns.delayedTagHigher \(tag) \(subject) \(comparison)")
                : String(localized: "mood.patterns.delayedTagLower \(tag) \(subject) \(comparison)")
        case .multipleEntries:
            return higher
                ? String(localized: "mood.patterns.multipleEntriesHigher \(subject) \(comparison)")
                : String(localized: "mood.patterns.multipleEntriesLower \(subject) \(comparison)")
        case .unknown:
            return nil
        }
    }

    private static func look(for kind: MoodPattern.Kind) -> (category: String, icon: String)? {
        switch kind {
        case .previousDay: (String(localized: "Day to day"), "repeat")
        case .weekend: (String(localized: "Weekends"), "calendar")
        case .bestWeekday: (String(localized: "Weekdays"), "sun.max")
        case .notes: (String(localized: "Notes"), "square.and.pencil")
        case .delayedTag: (String(localized: "Next day"), "arrow.right")
        case .multipleEntries: (String(localized: "Check-ins"), "number")
        case .unknown: nil
        }
    }

    static func strengthLabel(_ strength: MoodPattern.Strength) -> String? {
        switch strength {
        case .strong: String(localized: "mood.patterns.strength.strong")
        case .moderate: String(localized: "mood.patterns.strength.moderate")
        case .weak: String(localized: "mood.patterns.strength.weak")
        case .unknown: nil
        }
    }

    /// 0 = Monday … 6 = Sunday (the server's numbering), in the locale's words.
    static func weekdayName(_ index: Int?, locale: Locale) -> String? {
        guard let index, (0 ... 6).contains(index) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        // `standaloneWeekdaySymbols` starts on Sunday.
        return calendar.standaloneWeekdaySymbols[(index + 1) % 7]
    }

    /// The tag as the server named it: its label in the account's language,
    /// else its key.
    private static func tagName(_ values: MoodPattern.Values) -> String? {
        if let label = values.tagLabel?.trimmingCharacters(in: .whitespaces), !label.isEmpty { return label }
        if let key = values.tagKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty { return key }
        return nil
    }

    private static func format(_ value: Double, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }
}
