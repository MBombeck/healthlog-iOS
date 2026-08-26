import SwiftUI

// The two standalone wellness ring TILES the Insights score block renders — the
// 0–100 score ring and the Cardio-Fitness years-delta ring. Split out of
// `InsightsScoreCardsBlock.swift` for file-length discipline (pure movement;
// `private struct` → internal so the sibling file can still mount them).

// MARK: - Score ring tile (half-width: ring + number + short label below)

/// v0.14.1 §4 — half-width wellness-score tile. A bigger centred ring with the
/// number inside, and a short label below it. No right-hand text block, no
/// chevron, no trend line — clean + standalone, two per row. Tap → detail sheet.
struct ScoreRingCard: View {
    let dto: DerivedMetricDTO
    /// S4b (b182) — the dev-switchable tile style. Resolves to the surface +
    /// ring appearance; the insufficient-data calm gate always falls back to the
    /// plain mono surface regardless of style.
    let style: InsightsTileStyle
    /// v0.14.11 — grid index for the phase-offset glow breath.
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
    /// primary ink on the mono / glass surfaces.
    private var labelColor: Color {
        WellnessScorePresentation.isInsufficient(dto) ? HLText.primary : appearance.labelColor
    }

    var body: some View {
        Button(action: onTap) {
            InsightsTileSurface(appearance: appearance, glowPhaseIndex: glowPhaseIndex) {
                VStack(spacing: HLSpace.sm) {
                    ring
                        .frame(width: 96, height: 96)
                        .insightsRingEffect(
                            appearance.ringEffect,
                            fraction: WellnessScorePresentation.ringFraction(dto) ?? 0,
                            isHero: glowPhaseIndex == 0
                        )
                    Text(InsightsDerivedBlock.title(for: dto.metric))
                        // v0.14.1 polish — the label under the ring read "extrem
                        // hart"; dropped semibold→medium + (on the dark gradient
                        // tile) the calmer off-white palette label so it sits
                        // calmer beneath the ring while staying legible. On the
                        // plain mono fallback keep the default primary ink.
                        .font(.hlSubhead.weight(.medium))
                        .foregroundStyle(labelColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HLSpace.xs)
            }
        }
        .hlPressable() // QOL-AUDIT H1: press feedback
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
            // S4b (b182) — the band-boundary ticks stay dropped (they read as
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
        let title = InsightsDerivedBlock.title(for: dto.metric)
        if WellnessScorePresentation.isInsufficient(dto) {
            return String(localized: "\(title): not enough data yet")
        }
        let score = WellnessScorePresentation.scoreValueText(dto) ?? "—"
        return String(localized: "\(title) \(score) of 100")
    }
}

// MARK: - Cardio-fitness years-delta ring tile (no gauge)

/// v0.14.1 §4 — Cardio-Fitness as a half-width RING with the fitness-age delta
/// centred ("3 yr older" / "younger"), WHOLE number only — the gauge/tacho is
/// gone. Same shape as the other score tiles: ring + label below.
struct FitnessDeltaRingCard: View {
    let dto: DerivedMetricDTO
    /// S4b (b182) — the dev-switchable tile style.
    let style: InsightsTileStyle
    /// v0.14.11 — grid index for the phase-offset glow breath.
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
                    Text(InsightsDerivedBlock.title(for: dto.metric))
                        // v0.14.1 polish — calmer label (medium weight + off-white
                        // palette ink on the gradient tile, primary on mono / glass).
                        .font(.hlSubhead.weight(.medium))
                        .foregroundStyle(appearance.labelColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HLSpace.xs)
            }
        }
        .hlPressable() // QOL-AUDIT H1: press feedback
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
        let title = InsightsDerivedBlock.title(for: dto.metric)
        return "\(title), \(InsightsDerivedBlock.fitnessHeadline(dto.value?.fitnessAgeDeltaYears))"
    }
}
