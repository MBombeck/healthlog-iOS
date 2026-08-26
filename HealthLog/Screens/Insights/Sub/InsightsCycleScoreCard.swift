import SwiftUI

/// **v0.14.11 Task B — the CYCLE ring tile inside the "Deine Gesundheitswerte"
/// grid.**
///
/// A half-width tile that visually matches its score-ring siblings
/// (``WellnessGradientCard`` chrome: tinted-dark field + faint white glow +
/// hairline border + soft shadow), but carries the native cycle ring
/// (``HLCycleRing``) instead of a 0–100 score ring. The cycle ring keeps its own
/// warm phase palette — the ONE sanctioned warm accent on the surface — so the
/// tile's dark backdrop is tinted from the CURRENT phase hue (not a metric hue),
/// letting the warm arcs read as the protagonist.
///
/// **Hard-gated upstream.** The host (`InsightsScoreCardsBlock`) only appends a
/// `.cycle` tile when `cycleGate.isCycleTrackingAvailable` is true and the store
/// isn't disabled — so this view is never mounted for men / opt-in-off users.
/// This view ADDITIONALLY self-suppresses (renders nothing) while the cycle is
/// still learning (no resolvable current phase), so a cycle-eligible-but-no-
/// prediction user sees no hollow tile — consistent with `InsightsCycleTile`.
///
/// Tapping pushes the full ``CycleScreen`` on the shared Insights nav stack
/// (same destination as `InsightsCycleTile`). **Privacy:** logs nothing.
struct CycleScoreRingCard: View {
    let store: CycleStore

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let model = ringModel, let phase = currentPhase {
            NavigationLink {
                CycleScreen()
            } label: {
                tile(model: model, phase: phase)
            }
            .hlPressable() // QOL-AUDIT H1: press feedback
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(accessibilityLabel(phase: phase)))
            .accessibilityHint(Text(String(localized: "Double-tap for the breakdown")))
            .accessibilityIdentifier("insights.scoreCard.CYCLE")
            .task { await store.load() }
        } else {
            // Eligible but still learning — warm the store so the tile appears
            // once a prediction lands, without rendering a hollow card.
            Color.clear.frame(height: 0).task { await store.load() }
        }
    }

    private func tile(model: HLCycleRing.Model, phase: CyclePhasePalette.Phase) -> some View {
        WellnessGradientCard(gradient: nil, customGradient: tileGradient(for: phase)) {
            VStack(spacing: HLSpace.sm) {
                // The cycle ring carries its OWN warm palette (the sanctioned
                // accent). `.none` motion + `.off` glow keep the ring itself
                // static like the score rings — only the tile glow breathes
                // (Task C), so the cycle tile is consistent with its siblings.
                HLCycleRing(
                    model: model,
                    motion: .none,
                    glow: .off,
                    accessibilityLabel: String(localized: "cycle.home.title"),
                    accessibilityValue: model.centerSubtitle
                )
                .frame(width: 96, height: 96)
                Text(label(for: phase))
                    .font(.hlSubhead.weight(.medium))
                    .foregroundStyle(WellnessRingPalette.label)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLSpace.xs)
        }
    }

    /// The tile's tinted-dark backdrop, derived from the CURRENT phase warm tint
    /// (not a metric hue) using the same hue→near-black blend recipe the score
    /// tiles use — so the cycle tile sits in the same dark monochrome tone, only
    /// faintly warm, with the warm ring arcs reading as the accent on top.
    private func tileGradient(for phase: CyclePhasePalette.Phase) -> LinearGradient {
        let tint = CyclePhasePalette.tint(for: phase, scheme: colorScheme)
        let tinted = tint.blended(with: HLColor.wellnessGradientDark, fraction: WellnessGradient.darkenTowardBase)
        return LinearGradient(
            stops: [
                .init(color: tinted, location: 0),
                .init(color: tinted.blended(with: HLColor.wellnessGradientDark, fraction: 0.5), location: 0.5),
                .init(color: HLColor.wellnessGradientDark, location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Model derivation (reuses CycleScreenModel — no new prediction logic)

    private var verdict: CycleVerdictDTO? {
        store.verdict?.verdict
    }

    /// The hero ring model for the current cycle (delegates to the SAME
    /// `CycleScreenModel.ringModel` the full `CycleScreen` uses). `nil` while
    /// learning → the tile self-suppresses.
    private var ringModel: HLCycleRing.Model? {
        guard let verdict else { return nil }
        return CycleScreenModel.ringModel(
            verdict: verdict,
            prediction: store.prediction,
            centerTitle: centerTitle,
            centerSubtitle: centerSubtitle
        )
    }

    /// Z1 (#72) — the SERVER's phase. `nil` in OVERDUE / INSUFFICIENT_DATA, and
    /// this half-width glance tile then self-suppresses: it carries no room for
    /// the caption an overdue state needs, and the full `CycleScreen` is one tap
    /// away with the whole picture.
    private var currentPhase: CyclePhasePalette.Phase? {
        CycleScreenModel.phase(verdict)
    }

    /// Compact centre title for the 96 pt ring — the "in N days" count, mirroring
    /// the hero. Falls back to the learning copy when no next-period date.
    private var centerTitle: String {
        guard let n = verdict?.daysUntilNext else {
            return String(localized: "cycle.home.center.learning.title")
        }
        if n == 0 { return String(localized: "cycle.home.center.dueToday") }
        return String(format: String(localized: "cycle.home.center.inDays"), n)
    }

    private var centerSubtitle: String {
        if let day = verdict?.dayOfCycle {
            return String(format: String(localized: "cycle.home.center.cycleDay"), day)
        }
        return String(localized: "cycle.insights.tile.learning")
    }

    /// The under-ring label: "Zyklus · <Phase>" so the tile reads as a sibling
    /// with a short caption, matching the score tiles' single label line.
    private func label(for phase: CyclePhasePalette.Phase) -> String {
        let phaseName = String(localized: CyclePhaseExplainer.nameKey(for: phase))
        return String(format: String(localized: "insights.scoreCard.cycle.label"), phaseName)
    }

    private func accessibilityLabel(phase: CyclePhasePalette.Phase) -> String {
        let phaseName = String(localized: CyclePhaseExplainer.nameKey(for: phase))
        return "\(String(localized: "cycle.home.title")), \(phaseName), \(centerTitle)"
    }
}
