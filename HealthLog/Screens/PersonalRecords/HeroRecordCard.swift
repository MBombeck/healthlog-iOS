import SwiftUI

/// Hero Record card.
///
/// Apple-Fitness-Award-styled card that anchors the top of the
/// `PersonalRecordsScreen`. Picks the user's most impressive record
/// (`PersonalRecordsStore.heroRecord`) and renders it as a 280pt diagonal
/// gradient hero with a 60pt kind glyph (`.bounce` on appear), the value
/// in the page's one hero size and a "Bestleistung seit \(date)" caption.
/// Sharing lives in the screen's navigation bar, not on the card: glass
/// belongs to the navigation layer, never to content.
///
/// **Visual language** — diagonal gradient: kind tint at top-leading →
/// kind tint at 35% in the middle → near-black at 85% bottom-trailing.
/// Reduces to a single tint on Reduce Transparency.
struct HeroRecordCard: View {
    let record: PersonalRecord

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The account's display units.
    @Environment(\.unitPreferences) private var unitPreferences
    @State private var hasAppeared = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            backgroundGradient
            trophyWatermark
            content
        }
        .frame(maxWidth: .infinity)
        // At least the hero height; at the large text sizes the card grows
        // with its words instead of cutting them at its edge.
        .frame(minHeight: 280)
        // The record hero is a brand surface (kind gradient, trophy
        // watermark), not a content card: it keeps its own shape.
        // swiftlint:disable:next hl_no_handmade_card
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.xl, style: .continuous))
        .hlShadow(HLShadow.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isHeader)
        .onAppear { hasAppeared = true }
    }

    // MARK: - Subviews

    private var backgroundGradient: some View {
        let tint = PersonalRecordKindTint.color(for: record.kind)
        return LinearGradient(
            stops: [
                .init(color: tint, location: 0.0),
                .init(color: tint.opacity(0.35), location: 0.55),
                .init(color: HLColor.recordHeroScrim.opacity(0.85), location: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            // Soft spotlight in the top-trailing corner — matches the
            // Apple-Fitness-Award gradient signature without needing a
            // real RadialGradient (cheaper to render at scroll time).
            RadialGradient(
                colors: [HLColor.recordHeroInk.opacity(0.18), Color.clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 220
            )
        )
    }

    /// A subtle monochrome trophy/Pokal watermark so the big
    /// hero card no longer reads as empty. Rendered in graphite/silver (white
    /// at very low opacity over the dark bottom-trailing of the gradient — NOT
    /// a loud accent colour, doctrine-safe), oversized and bled off the
    /// bottom-trailing corner so it sits clearly BEHIND the value + glyph as a
    /// texture, not a competing focal point. Hidden from VoiceOver (decorative)
    /// and clipped to the card's rounded rect by the parent `clipShape`.
    private var trophyWatermark: some View {
        Image(systemName: "trophy.fill")
            // Decorative background texture at a FIXED render size — it must NOT
            // grow with Dynamic Type (it is a watermark, not readable text), so a
            // pixel-locked size is correct here.
            // swiftlint:disable:next dynamic_type_bypass
            .font(.system(size: 240, weight: .bold))
            // Graphite/silver watermark: white ink at very low opacity over the
            // dark bottom-trailing of the existing gradient. Matches the file's
            // established in-gradient spotlight style (see `backgroundGradient`);
            // routed through the sanctioned `recordHeroInk` token (v0.14.8 W2,
            // Audit §1.1) — monochrome + doctrine-safe (no accent hue).
            .foregroundStyle(
                LinearGradient(
                    colors: [HLColor.recordHeroInk.opacity(0.14), HLColor.recordHeroInk.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .rotationEffect(.degrees(-12))
            .offset(x: 70, y: 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            kindGlyph
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                // The hero size of `HLValueText`; the value is drawn here
                // because it stands in the gradient's ink, not in text primary.
                Text(formattedValue)
                    .font(HLValueSize.hero.numberFont)
                    .foregroundStyle(HLColor.recordHeroInk)
                    .monospacedDigit()
                    .lineLimit(1)
                    // 0.6 → 0.75: hero record value held above the
                    // legibility floor at large Dynamic Type.
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText(value: record.base.value))
                Text(unitLabel)
                    .font(HLValueSize.hero.unitFont)
                    .foregroundStyle(HLColor.recordHeroInk.opacity(0.8))
            }
            Spacer(minLength: 0)
            // Side by side up to XXXL; at the accessibility sizes the slot and
            // the date stand under each other so neither breaks inside a word.
            let footer = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.xs))
                : AnyLayout(HStackLayout(spacing: HLSpace.sm))
            footer {
                if let slot = Self.badgeText(slot: record.base.metricSlot) {
                    // In the gradient's ink on a tint of it: the neutral badge
                    // put dark words on the dark end of the gradient.
                    Text(verbatim: slot)
                        .foregroundStyle(HLColor.recordHeroInk)
                        .hlText(.tileLabel)
                        .padding(.horizontal, HLSpace.sm)
                        .padding(.vertical, HLSpace.xxs)
                        .background(HLColor.recordHeroInk.opacity(0.18), in: Capsule())
                }
                Text(achievedAtLabel)
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.recordHeroInk.opacity(0.85))
            }
        }
        .padding(HLSpace.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kindGlyph: some View {
        Image(systemName: glyphName)
            // Cover-scale hero glyph (audit-01 H2/M1 — the one-off 60pt pulled
            // onto the canonical `HLIconSize.cover`).
            .font(.hlIcon(HLIconSize.cover))
            .foregroundStyle(HLColor.recordHeroInk)
            .symbolEffect(.bounce, value: hasAppeared && !reduceMotion)
            .accessibilityHidden(true)
    }

    // MARK: - Derived

    private var glyphName: String {
        guard let kind = record.kind else { return "rosette" }
        return MetricKindDescriptor.descriptor(for: kind).sfSymbol
    }

    /// The record in the account's unit (the row is canonical).
    private var formattedValue: String {
        let value = record.base.displayValue(unitPreferences)
        return Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private var unitLabel: String {
        record.base.displayUnit(unitPreferences)
    }

    private var achievedAtLabel: String {
        // Day and short month ("7. Nov."): the long date broke inside itself
        // beside the badge.
        String(localized: "records.hero.since \(HLDateFormat.dayMonth(Self.sinceDate(of: record.base)))")
    }

    /// The slot on the hero's badge. A streak's slot ends in its length in
    /// brackets ("… (12 Tage)"), which the hero already shows in large type
    /// above it; the badge keeps the rest.
    nonisolated static func badgeText(slot: String?) -> String? {
        guard var text = slot?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasSuffix(")"), let open = text.lastIndex(of: "("), open > text.startIndex {
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? nil : text
    }

    /// Since when the record holds. A streak holds since its first day (the
    /// day it reached is today while it runs); any other record since the day
    /// it was reached.
    nonisolated static func sinceDate(of record: PersonalRecordDTO) -> Date {
        streakStart(record.externalId) ?? record.achievedAt
    }

    /// The first day of a streak from its key "streak:2026-11-03..2026-11-14".
    nonisolated static func streakStart(_ key: String?) -> Date? {
        guard let key, key.hasPrefix("streak:"),
              let range = key.dropFirst("streak:".count).components(separatedBy: "..").first else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = range.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private var accessibilityLabel: Text {
        let metric = MetricTypeLocalisation.label(forType: record.base.metricType)
        let date = HLDateFormat.date(record.base.achievedAt, style: .long)
        return Text("records.hero.a11y \(metric) \(formattedValue) \(unitLabel) \(date)")
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale.current
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return f
    }()
}

#Preview("HeroRecordCard") {
    let dto = PersonalRecordDTO(
        id: "preview.steps",
        userId: "u1",
        metricType: "ACTIVITY_STEPS",
        metricSlot: "Bester Tag",
        direction: .max,
        value: 23412,
        unit: "Steps",
        achievedAt: Date(timeIntervalSince1970: 1_716_854_400),
        sourceMeasurementId: nil,
        source: "HEALTHLOG_CLIENT",
        externalId: nil,
        createdAt: Date()
    )
    let record = PersonalRecord(
        id: dto.id,
        base: dto,
        kind: .steps,
        sparklineValues: [],
        peakIndex: nil,
        previousValue: 21000,
        bucket: .month,
        impressiveness: 0.95
    )
    return HeroRecordCard(record: record)
        .padding()
        .background(HLSurface.primary)
}
