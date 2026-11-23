import SwiftUI

// The two standalone wellness ring TILES the Insights score block renders — the
// 0–100 score ring and the Cardio-Fitness years-delta ring. Split out of
// `InsightsScoreCardsBlock.swift` for file-length discipline (pure movement;
// `private struct` → internal so the sibling file can still mount them).

// MARK: - Score ring tile (half-width: ring + number + short label below)

/// Half-width wellness-score tile. A bigger centred ring with the
/// number inside, and a short label below it. No right-hand text block, no
/// chevron, no trend line — clean + standalone, two per row. Tap → detail sheet.
struct ScoreRingCard: View {
    let dto: DerivedMetricDTO
    /// The dev-switchable tile style. Resolves to the surface +
    /// ring appearance; the insufficient-data calm gate always falls back to the
    /// plain mono surface regardless of style.
    let style: InsightsTileStyle
    /// Grid index for the phase-offset glow breath.
    var glowPhaseIndex: Int = 0
    let onTap: () -> Void

    /// The resolved appearance for this style + the metric's signal. v0152 T1 —
    /// the sole shipped style (P9 `prismUniform`) is already a plain mono surface
    /// that never over-promises, so the old insufficient-state mono fork is moot;
    /// the signal is always suppressed (no cap dot) regardless of data state.
    private var appearance: InsightsTileAppearance {
        style.appearance(signal: WellnessScorePresentation.signal(dto))
    }

    /// The metric label UNDER the ring — calm off-white on the gradient surface,
    /// primary ink on the mono surface.
    private var labelColor: Color {
        WellnessScorePresentation.isInsufficient(dto) ? HLText.primary : appearance.labelColor
    }

    var body: some View {
        Button(action: onTap) {
            ScoreRingTileFace(
                title: InsightsDerivedCopy.title(for: dto.metric),
                labelColor: labelColor,
                appearance: appearance,
                fraction: WellnessScorePresentation.ringFraction(dto) ?? 0,
                glowPhaseIndex: glowPhaseIndex
            ) {
                ring
            }
        }
        .hlPressable(hover: .lift) // Press feedback, the card rises under the pointer
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(String(localized: "Double-tap for the breakdown")))
        .accessibilityIdentifier("insights.scoreCard.\(dto.metric)")
    }

    @ViewBuilder
    private var ring: some View {
        if WellnessScorePresentation.isInsufficient(dto) {
            // Calm gate — a mono track ring with a dash, never a fake fill.
            HLScoreRing(fraction: 0, value: "—")
        } else {
            // The band-boundary ticks stay dropped (they read as
            // stray strokes on the tile); the single signal cap dot is now ON
            // across the switchable concepts (the only colour = meaning). The
            // surface + ring ink are resolved per `appearance`.
            HLScoreRing(
                fraction: WellnessScorePresentation.ringFraction(dto) ?? 0,
                value: WellnessScorePresentation.scoreValueText(dto),
                signal: appearance.ringSignal,
                fillColor: appearance.ringFill,
                trackColor: appearance.ringTrack,
                centreValueColor: appearance.ringValueColor,
                centreLabelColor: appearance.ringLabelColor,
                accessibilityLabel: accessibilityLabel
            )
            // Legibility safeguard — a soft dark shadow so the white ring +
            // value never wash out on the gradient's lightest corner. Only on
            // the warm-gradient surface (Concept F).
            .modifier(WellnessRingShadow(active: appearance.ringShadowActive))
        }
    }

    private var accessibilityLabel: String {
        let title = InsightsDerivedCopy.title(for: dto.metric)
        if WellnessScorePresentation.isInsufficient(dto) {
            return String(localized: "\(title): not enough data yet")
        }
        let score = WellnessScorePresentation.scoreValueText(dto) ?? "—"
        return String(localized: "\(title) \(score) of 100")
    }
}

// MARK: - The face every score ring tile shares

/// Ring over name on the tile surface: the one face of the 0 to 100 score
/// tiles, so the health score and the derived scores stand as equals.
struct ScoreRingTileFace<Ring: View>: View {
    let title: String
    let labelColor: Color
    let appearance: InsightsTileAppearance
    let fraction: Double
    let glowPhaseIndex: Int
    @ViewBuilder let ring: Ring

    var body: some View {
        InsightsTileSurface(appearance: appearance, glowPhaseIndex: glowPhaseIndex) {
            VStack(spacing: HLSpace.sm) {
                ring
                    .frame(width: 96, height: 96)
                    .insightsRingEffect(
                        appearance.ringEffect,
                        fraction: fraction,
                        isHero: glowPhaseIndex == 0
                    )
                // The tile label role; the calm comes from the palette ink
                // on a gradient tile, primary on mono.
                ScoreRingTileLabel(title: title, color: labelColor)
            }
            // Ring at the top of every tile, whatever its label's length.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.vertical, HLSpace.xs)
        }
    }
}

// MARK: - The label under a score ring

/// The name under a score ring, in the tile label role. It takes the room of
/// the lines it may use: one for a single word, two for a name of several
/// words, so a one-word tile has no empty line under its name. The rings of
/// a row stay level, because every face stands at the top of its tile. At
/// the tile label's size the longest name ("Gesundheitsscore") fits a tile
/// whole, so every name of a row has the same size; a name of several words
/// wraps at a space. Only at the accessibility sizes may a single word shrink
/// rather than break into syllables.
struct ScoreRingTileLabel: View {
    let title: String
    let color: Color

    /// A word is never split; a single word shrinks this far before it would.
    nonisolated static func lineLimit(for title: String) -> Int {
        title.split(whereSeparator: \.isWhitespace).count > 1 ? 2 : 1
    }

    /// The invisible text that holds the room of ``lineLimit(for:)`` lines.
    nonisolated static func reservedText(for title: String) -> String {
        Array(repeating: "X", count: lineLimit(for: title)).joined(separator: "\n")
    }

    /// How far a single word may shrink at the accessibility sizes.
    nonisolated static let minimumScale: CGFloat = 0.7

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The shrink a name may take at `size`: none below the accessibility
    /// sizes, so every name of a row stands at the size of the role; only
    /// there a single word shrinks rather than break into syllables.
    nonisolated static func minimumScale(at size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? minimumScale : 1
    }

    var body: some View {
        ZStack(alignment: .top) {
            // The lines the name may take hold the room.
            Text(verbatim: Self.reservedText(for: title))
                .hidden()
                .accessibilityHidden(true)
            Text(title)
                .hlText(.tileLabel, status: color)
                .lineLimit(Self.lineLimit(for: title))
                .minimumScaleFactor(Self.minimumScale(at: dynamicTypeSize))
        }
        .font(HLTextRole.tileLabel.font)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        // The name may reach into the card's inset: at the narrowest tile
        // (128 pt, five in a row on the iPad) "Gesundheitsscore" then fits
        // whole at the size of its neighbours instead of being cut.
        .padding(.horizontal, -Self.insetReach)
    }

    /// How far a name may reach into the card's inset on each side.
    nonisolated static let insetReach: CGFloat = HLSpace.sm
}

// MARK: - Health score ring tile

/// The health score as a tile beside the derived scores: the same face, the
/// same tap into its detail. The number is the server's composite
/// (`HealthScoreStore.score`), monochrome like every ring here.
struct HealthScoreRingCard: View {
    let score: HealthScore
    let style: InsightsTileStyle
    var glowPhaseIndex: Int = 0
    let onTap: () -> Void

    private var appearance: InsightsTileAppearance {
        style.appearance(signal: nil)
    }

    private var title: String {
        String(localized: "Health score")
    }

    private var fraction: Double {
        max(0, min(1, Double(score.score) / 100))
    }

    private var accessibilityLabel: String {
        String(localized: "\(title) \(String(score.score)) of 100")
    }

    var body: some View {
        Button(action: onTap) {
            ScoreRingTileFace(
                title: title,
                labelColor: appearance.labelColor,
                appearance: appearance,
                fraction: fraction,
                glowPhaseIndex: glowPhaseIndex
            ) {
                HLScoreRing(
                    fraction: fraction,
                    value: String(score.score),
                    signal: appearance.ringSignal,
                    fillColor: appearance.ringFill,
                    trackColor: appearance.ringTrack,
                    centreValueColor: appearance.ringValueColor,
                    centreLabelColor: appearance.ringLabelColor,
                    accessibilityLabel: accessibilityLabel
                )
                .modifier(WellnessRingShadow(active: appearance.ringShadowActive))
            }
        }
        .hlPressable(hover: .lift)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(String(localized: "Double-tap for the breakdown")))
        .accessibilityIdentifier("insights.scoreCard.HEALTH_SCORE")
    }
}

// MARK: - Cardio-fitness years-delta ring tile (no gauge)

/// Cardio-Fitness as a half-width RING with the fitness-age delta
/// centred ("3 yr older" / "younger"), WHOLE number only — the gauge/tacho is
/// gone. Same shape as the other score tiles: ring + label below.
struct FitnessDeltaRingCard: View {
    let dto: DerivedMetricDTO
    /// The dev-switchable tile style.
    let style: InsightsTileStyle
    /// Grid index for the phase-offset glow breath.
    var glowPhaseIndex: Int = 0
    let onTap: () -> Void

    /// The Cardio-Fitness gauge carries no green/yellow/red band, so the cap dot
    /// stays off (pure mono) on every style — its meaning is "above/below" by
    /// position, not a status colour.
    private var appearance: InsightsTileAppearance {
        style.appearance(signal: nil)
    }

    var body: some View {
        Button(action: onTap) {
            InsightsTileSurface(appearance: appearance, glowPhaseIndex: glowPhaseIndex) {
                VStack(spacing: HLSpace.sm) {
                    HLScoreRing(
                        fraction: WellnessScorePresentation.fitnessGaugeFraction(dto),
                        value: deltaValue,
                        label: deltaUnit,
                        fillColor: appearance.ringFill,
                        trackColor: appearance.ringTrack,
                        centreValueColor: appearance.ringValueColor,
                        centreLabelColor: appearance.ringLabelColor,
                        accessibilityLabel: accessibilityLabel
                    )
                    .frame(width: 96, height: 96)
                    .insightsRingEffect(
                        appearance.ringEffect,
                        fraction: WellnessScorePresentation.fitnessGaugeFraction(dto),
                        isHero: glowPhaseIndex == 0
                    )
                    // Legibility safeguard (see ScoreRingCard) — only on the
                    // warm-gradient surface (Concept F).
                    .modifier(WellnessRingShadow(active: appearance.ringShadowActive))
                    // The tile-title weight; palette ink on the gradient
                    // tile, primary on mono.
                    ScoreRingTileLabel(title: InsightsDerivedCopy.title(for: dto.metric), color: appearance.labelColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.vertical, HLSpace.xs)
            }
        }
        .hlPressable(hover: .lift) // Press feedback, the card rises under the pointer
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier("insights.scoreCard.FITNESS_AGE")
    }

    /// The whole-number years-delta magnitude centred in the ring ("3"), or "—"
    /// when the server carries no delta. WHOLE number only (§4: 34.9 → 35-style
    /// rounding; here the delta itself is rounded to a whole year).
    private var deltaValue: String {
        guard let years = dto.value?.fitnessAgeDeltaYears, years.rounded() != 0,
              let mag = Int(safeServer: abs(years)) else
        {
            return "0"
        }
        return "\(mag)"
    }

    /// The unit line under the centred number: "yr older" / "yr younger" / "on
    /// par" — so the ring reads "3 / yr older". Honest, whole-number framing.
    private var deltaUnit: String {
        guard let years = dto.value?.fitnessAgeDeltaYears, years.rounded() != 0 else {
            return String(localized: "yr on par")
        }
        return years < 0
            ? String(localized: "yr younger")
            : String(localized: "yr older")
    }

    private var accessibilityLabel: String {
        let title = InsightsDerivedCopy.title(for: dto.metric)
        return "\(title), \(InsightsDerivedCopy.fitnessHeadline(dto.value?.fitnessAgeDeltaYears))"
    }
}
