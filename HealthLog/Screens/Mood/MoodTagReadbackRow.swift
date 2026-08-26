import SwiftUI

/// One resolved structured-tag chip for read-back: the stable catalog `key`,
/// its localized `label`, and the SF Symbol to render. A value type (not a
/// tuple) so the list `ForEach` has a stable `Identifiable` row identity.
struct MoodReadbackChip: Identifiable, Hashable {
    let key: String
    let label: String
    let symbol: String

    var id: String {
        key
    }
}

/// Inverse-aware qualitative bucket for a RATED factor's read-back. Mirrors the
/// capture slider's polarity: RIGHT/high = good for non-inverse factors
/// (work / sleep_quality); for inverse factors (sadness) a HIGH raw rating is a
/// WORSE day. Derived from the catalog `inverse` flag + scale, NOT the raw
/// number, so the displayed word always matches what the slider showed.
enum MoodRatedQuality {
    case bad
    case mid
    case good

    /// Map a raw rating (within `factor`'s own scale) onto a qualitative bucket
    /// using the same 0…1 good-ward "goodness" projection the capture slider
    /// uses (``MoodRatedFactorScale/position(forRating:)`` — already
    /// inverse-aware).
    static func resolve(rating: Int, factor: MoodTagDTO) -> MoodRatedQuality {
        let goodness = MoodRatedFactorScale(factor: factor).position(forRating: rating)
        switch goodness {
        case ..<0.34: return .bad
        case ..<0.67: return .mid
        default: return .good
        }
    }

    /// Localized one-word read-out ("schlecht"/"mittel"/"gut").
    var localizedWord: String {
        switch self {
        case .bad: String(localized: "mood.ratedFactor.quality.bad")
        case .mid: String(localized: "mood.ratedFactor.quality.mid")
        case .good: String(localized: "mood.ratedFactor.quality.good")
        }
    }
}

/// One resolved RATED-factor read-back chip: the factor's localized `label`
/// (e.g. "Arbeit"), its inverse-aware qualitative read-out (e.g. "gut"), and
/// the SF Symbol. Rendered as a labelled value ("Arbeit: gut") so the saved
/// slider value round-trips visibly, not just the factor name.
struct MoodRatedReadbackChip: Identifiable, Hashable {
    let key: String
    let label: String
    let qualityWord: String
    let symbol: String

    var id: String {
        key
    }
}

/// Read-back chip row for a logged mood entry (v0.14). Surfaces the structured
/// `tagKeys` as icon + label capsules so the Daylio-style logging round-trips
/// visibly. Monochrome (graphite ink on a faint surface fill), single-line
/// horizontal scroller so the row height stays stable in dense lists.
struct MoodTagReadbackRow: View {
    let chips: [MoodReadbackChip]
    /// v0.14.7 — RATED factors read back as labelled values ("Arbeit: gut"),
    /// rendered first (ahead of the binary tag chips) so the scored signal leads.
    var ratedChips: [MoodRatedReadbackChip] = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HLSpace.xs) {
                ForEach(ratedChips) { chip in
                    ratedChipView(chip)
                }
                ForEach(chips) { chip in
                    HStack(spacing: HLSpace.xxs) {
                        Image(systemName: chip.symbol)
                            .font(.hlCaption2)
                            .accessibilityHidden(true)
                        Text(chip.label)
                            .font(.hlCaption2)
                    }
                    .foregroundStyle(HLText.secondary)
                    .padding(.horizontal, HLSpace.sm)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(HLColor.surface.opacity(0.6))
                    )
                    .overlay(
                        Capsule().stroke(HLText.tertiary.opacity(0.15), lineWidth: 1)
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(a11ySummary))
    }

    /// A labelled-value chip ("Arbeit: gut") — the label in the secondary ink,
    /// the qualitative read-out in the primary ink so the scored value pops
    /// within the monochrome treatment. Same capsule chrome as the tag chips.
    private func ratedChipView(_ chip: MoodRatedReadbackChip) -> some View {
        HStack(spacing: HLSpace.xxs) {
            Image(systemName: chip.symbol)
                .font(.hlCaption2)
                .accessibilityHidden(true)
            Text(chip.label)
                .font(.hlCaption2)
                .foregroundStyle(HLText.secondary)
            Text(chip.qualityWord)
                .font(.hlCaption2.weight(.semibold))
                .foregroundStyle(HLText.primary)
        }
        .padding(.horizontal, HLSpace.sm)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(HLColor.surface.opacity(0.6))
        )
        .overlay(
            Capsule().stroke(HLText.tertiary.opacity(0.15), lineWidth: 1)
        )
    }

    private var a11ySummary: String {
        let rated = ratedChips
            .map { String(localized: "mood.readback.ratedValue \($0.label) \($0.qualityWord)") }
            .joined(separator: ", ")
        let tags = String(localized: "mood.readback.tags \(chips.map(\.label).joined(separator: ", "))")
        if ratedChips.isEmpty { return tags }
        if chips.isEmpty { return rated }
        return "\(rated), \(tags)"
    }
}
