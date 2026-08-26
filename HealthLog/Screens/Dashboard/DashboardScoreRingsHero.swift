import SwiftUI

/// **v0141 — the dashboard hero score-ring row.**
///
/// WHICH rings + order come from the server-resolved snapshot slot
/// (``DashboardSnapshotBriefing/scoreRings`` on ``DailyBriefingStore``). The
/// DERIVED ring VALUES (READINESS / RECOVERY / SLEEP score) are reconciled onto
/// the live ``DerivedInsightsStore`` — the SAME source the Insights wellness cards
/// render — so the two surfaces never disagree (see ``DashboardHeroRingReconciler``
/// for the cache-freshness root cause). `MED_COMPLIANCE` keeps its snapshot dose
/// tally (a snapshot-only value the Insights overview never shows).
///
/// The rings render BARE — no "Deine Ringe" section header, no inline edit
/// affordance. Ring selection moved to **Settings → Aussehen → "Ringe auf der
/// Startseite"** (``ScoreRingSelectionSheet``); only the entry point moved, the
/// selection still persists via the widgets PUT.
///
/// **Layout (b221):** all (up to three) rings live in ONE container ``HLCard``,
/// side-by-side in a single evenly-spaced ``HStack`` — NOT one tile per ring.
/// Each ring reuses the EXACT Insights wellness-ring visual (the P9 prism
/// ``HLScoreRing`` fill/effect/shadow + the `hlSubhead.weight(.medium)` label),
/// just at an 84 pt diameter so three fit cleanly 3-up on a narrow iPhone without
/// cropping. iOS **renders only** — every score/band is server-resolved.
/// Self-suppresses to nothing when the server returned no rings.
struct DashboardScoreRingsHost: View {
    @Environment(DailyBriefingStore.self) private var briefingStore
    @Environment(DerivedInsightsStore.self) private var derivedStore

    private var rows: [DashboardHeroRingReconciler.Row] {
        DashboardHeroRingReconciler.reconcile(
            snapshotRings: briefingStore.snapshotBriefing?.scoreRings ?? [],
            derived: derivedStore.metrics
        )
    }

    var body: some View {
        if !rows.isEmpty {
            HLCard {
                HStack(alignment: .top, spacing: HLSpace.md) {
                    // At most three rings ride the hero (server clamps to
                    // `MAX_SELECTED_SCORE_RINGS`); the prefix is belt-and-braces.
                    ForEach(Array(rows.prefix(ScoreRingID.maxSelected).enumerated()), id: \.element.id) { index, row in
                        HeroScoreRingLockup(row: row, index: index)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .task {
                // Warm the SAME live derived source the Insights cards read, so the
                // hero reconciles onto it. Best-effort + cache-backed — the snapshot
                // value stands until it lands, never a blank.
                await derivedStore.load()
            }
        }
    }
}

// MARK: - One hero ring lockup (Insights wellness-ring visual, 3-up in one card)

/// A single hero ring rendered with the Insights wellness-ring visual: the P9
/// prism ``HLScoreRing`` at 84 pt (shrunk from the Insights 96 pt so three sit
/// side-by-side in one card) with the label below in `hlSubhead.weight(.medium)`.
/// The derived rings show the server 0–100 score; MED_COMPLIANCE shows the honest
/// server dose tally ("1/3") with the progress arc behind it.
private struct HeroScoreRingLockup: View {
    let row: DashboardHeroRingReconciler.Row
    /// Position in the row — phase-offsets the shared prism glow breath and marks
    /// the first ring as the hero for the stronger prism effect (Insights parity).
    let index: Int

    /// 84 pt fits three rings 3-up inside one `HLCard` on a narrow iPhone (≈95 pt
    /// per column at 375 pt width) without cropping, while staying substantial.
    private static let ringDiameter: CGFloat = 84

    /// The shipped P9 `prismUniform` appearance — the sole Insights ring look
    /// (the arc-masked prism, no cap dot). Signal is irrelevant to this style (it
    /// draws no dot), so `nil` keeps it lean.
    private var appearance: InsightsTileAppearance {
        InsightsTileStyle.prismUniform.appearance(signal: nil)
    }

    /// Centre value: the honest dose tally for MED_COMPLIANCE, else the score.
    private var centreValue: String {
        row.ring.dosesCaption ?? "\(row.displayScore)"
    }

    /// The short label under the ring. ``ScoreRingID/label`` was built to match the
    /// Insights derived-score titles verbatim (READINESS → "Daily condition" etc.),
    /// so the hero + the Insights cards read the SAME names, and MED_COMPLIANCE
    /// resolves to a real localized label (never a raw id).
    private var label: String {
        row.id.label
    }

    var body: some View {
        VStack(spacing: HLSpace.sm) {
            HLScoreRing(
                fraction: row.fraction,
                value: centreValue,
                signal: appearance.ringSignal,
                fillColor: appearance.ringFill,
                trackColor: appearance.ringTrack,
                centreValueColor: appearance.ringValueColor,
                centreLabelColor: appearance.ringLabelColor,
                accessibilityLabel: accessibilityLabel
            )
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            .insightsRingEffect(appearance.ringEffect, fraction: row.fraction, isHero: index == 0)
            .modifier(WellnessRingShadow(active: appearance.ringShadowActive))
            Text(label)
                .font(.hlSubhead.weight(.medium))
                .foregroundStyle(appearance.labelColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier("dashboard.heroRing.\(row.id.rawValue)")
    }

    private var accessibilityLabel: String {
        if let doses = row.ring.doses {
            return String(
                localized: "\(label): \(doses.taken) of \(doses.scheduled) doses taken today",
                comment: "Hero MED_COMPLIANCE ring a11y label"
            )
        }
        // Reuse the existing "%@ %@ of 100" catalog key (score as string).
        return String(
            localized: "\(label) \(String(row.displayScore)) of 100",
            comment: "Hero score-ring a11y label"
        )
    }
}
