import SwiftUI

// **v0.14.9 §2 — the re-frame ring tiles promoted from "More from your data".**
//
// The operator asked for EVERYTHING in the "More from your data" rubric to
// become a proper Gesundheitswerte ring tile, not just RECOVERY/STRESS. The two
// remaining re-frames were Vascular age (a years-delta, like Cardio-Fitness) and
// HRV balance (a server band, no 0–100 score). Both now render as half-width
// ring tiles in the same `ScoreRingCard` grid via these two cards, reusing the
// shared `WellnessGradientCard` surface + the white `WellnessRingPalette` ring
// (with the dark-shadow legibility safeguard). With both promoted, the "More
// from your data" text lane (`InsightsDerivedBlock`) has nothing left to render
// and self-suppresses on the overview composition.
//
// Monochrome doctrine: the only colour is the softened convergent wellness
// gradient (the sanctioned sparse warm accent). The ring + value + label are
// white on the gradient, dark-shadowed for legibility.

// MARK: - Vascular-age years-delta ring tile

/// v0.14.9 §2 — Vascular age as a half-width RING with the years-delta centred
/// ("3 yr above" / "below" / "in line"), WHOLE number only — the exact shape of
/// the Cardio-Fitness `FitnessDeltaRingCard`, so the two age re-frames read as
/// siblings. Tap → the same wellness detail sheet.
struct VascularDeltaRingCard: View {
    let dto: DerivedMetricDTO
    /// S4b (b182) — the dev-switchable tile style.
    let style: InsightsTileStyle
    /// v0.14.11 — grid index for the phase-offset glow breath.
    var glowPhaseIndex: Int = 0
    let onTap: () -> Void

    /// Vascular age is a years-delta with no green/yellow/red band, so the cap
    /// dot stays off (pure mono) on every style — the read is direction by
    /// position, not a status colour.
    private var appearance: InsightsTileAppearance {
        style.appearance(signal: nil)
    }

    var body: some View {
        Button(action: onTap) {
            InsightsTileSurface(appearance: appearance, glowPhaseIndex: glowPhaseIndex) {
                VStack(spacing: HLSpace.sm) {
                    HLScoreRing(
                        fraction: WellnessScorePresentation.vascularDeltaFraction(dto),
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
                        fraction: WellnessScorePresentation.vascularDeltaFraction(dto),
                        isHero: glowPhaseIndex == 0
                    )
                    .modifier(WellnessRingShadow(active: appearance.ringShadowActive))
                    Text(InsightsDerivedBlock.title(for: dto.metric))
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
        .accessibilityIdentifier("insights.scoreCard.VASCULAR_AGE_DELTA")
    }

    /// The whole-number years-delta magnitude centred in the ring ("3"), or "0"
    /// when the server carries no delta (the "in line" read-out).
    private var deltaValue: String {
        guard let years = dto.value?.deltaYears, years.rounded() != 0,
              let mag = Int(safeServer: abs(years)) else
        {
            return "0"
        }
        return "\(mag)"
    }

    /// The unit line under the centred number: "yr above" / "yr below" / "in
    /// line" — so the ring reads "3 / yr above". Honest, whole-number framing.
    private var deltaUnit: String {
        guard let years = dto.value?.deltaYears, years.rounded() != 0 else {
            return String(localized: "yr in line")
        }
        return years < 0
            ? String(localized: "yr below")
            : String(localized: "yr above")
    }

    private var accessibilityLabel: String {
        let title = InsightsDerivedBlock.title(for: dto.metric)
        return "\(title), \(InsightsDerivedBlock.vascularHeadline(dto.value?.deltaYears))"
    }
}

// MARK: - HRV-balance band ring tile

/// v0.14.9 §2 — HRV balance as a half-width RING with the server band word
/// centred ("Balanced" / "High" / "Low"). HRV balance carries NO 0–100 score —
/// only a band — so the band is positioned on the arc (balanced ≈ centred fill)
/// and the word is the centre value. Honest: the band is the server's own, never
/// reinterpreted. Tap → the same wellness detail sheet.
struct HrvBalanceRingCard: View {
    let dto: DerivedMetricDTO
    /// S4b (b182) — the dev-switchable tile style.
    let style: InsightsTileStyle
    /// v0.14.11 — grid index for the phase-offset glow breath.
    var glowPhaseIndex: Int = 0
    let onTap: () -> Void

    /// HRV balance carries a server band → it maps to a signal cap dot (the only
    /// colour = meaning) across the switchable concepts.
    private var appearance: InsightsTileAppearance {
        style.appearance(signal: WellnessScorePresentation.signal(dto))
    }

    var body: some View {
        Button(action: onTap) {
            InsightsTileSurface(appearance: appearance, glowPhaseIndex: glowPhaseIndex) {
                VStack(spacing: HLSpace.sm) {
                    HLScoreRing(
                        fraction: WellnessScorePresentation.hrvBalanceFraction(dto) ?? 0,
                        value: bandWord,
                        signal: appearance.ringSignal,
                        fillColor: appearance.ringFill,
                        trackColor: appearance.ringTrack,
                        centreValueColor: appearance.ringValueColor,
                        centreLabelColor: appearance.ringLabelColor,
                        accessibilityLabel: accessibilityLabel
                    )
                    .frame(width: 96, height: 96)
                    .insightsRingEffect(
                        appearance.ringEffect,
                        fraction: WellnessScorePresentation.hrvBalanceFraction(dto) ?? 0,
                        isHero: glowPhaseIndex == 0
                    )
                    .modifier(WellnessRingShadow(active: appearance.ringShadowActive))
                    Text(InsightsDerivedBlock.title(for: dto.metric))
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
        .accessibilityIdentifier("insights.scoreCard.HRV_BALANCE")
    }

    /// The server band word centred in the ring ("Balanced" / "High" / "Low"),
    /// or "—" when the server carries no band (defensive; the card is gated on a
    /// non-nil band at the call site).
    private var bandWord: String {
        WellnessScorePresentation.hrvBalanceValueText(dto) ?? "—"
    }

    private var accessibilityLabel: String {
        let title = InsightsDerivedBlock.title(for: dto.metric)
        let headline = InsightsDerivedBlock.hrvHeadline(dto.value?.band) ?? bandWord
        return "\(title), \(headline)"
    }
}
