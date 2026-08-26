import SwiftUI

// MARK: - Highlight insight card

// v0.5.1-A B3 — `ComplianceRingCard` extracted to its own file so the
// per-snapshot subtitle helper doesn't push `DashboardScreen.swift` past
// the 600-line file-length lint baseline. See `ComplianceRingCard.swift`.

struct HighlightInsightCard: View {
    let insight: Insight?

    var body: some View {
        if let insight {
            HLCard(style: .elevated) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(HLText.primary)
                        Text(String(localized: "Assistant insight", comment: "Dashboard assistant insight tile title"))
                            .font(.hlCaption.weight(.semibold))
                            .foregroundStyle(HLText.secondary)
                        Spacer()
                        HLBadge(insight.providerLabel, tone: .neutral)
                    }
                    Text(insight.title)
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.primary)
                    Text(insight.summary)
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .lineLimit(3)
                    // v0.7.0 W-API-RENDER — the server sends a full `body`
                    // prose paragraph + structured `recommendations` (each
                    // with an optional `actionURL`) that the card silently
                    // dropped, showing only title + clamped summary. Render
                    // the body verbatim (MDR: never paraphrase) + an action
                    // button per recommendation that carries a deep-link.
                    if let body = insight.body,
                       !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        Text(body)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    InsightRecommendationActions(recommendations: insight.recommendations)
                }
            }
        }
    }
}

/// v0.7.0 W-API-RENDER — renders the action buttons for an insight's
/// `recommendations`. Only entries that carry an `actionURL` become tappable
/// buttons (a recommendation without a deep-link is shown as a plain bullet
/// so the prose isn't lost). Opens via the system `openURL` so the URL the
/// server emits (in-app route or external help link) is honoured verbatim.
private struct InsightRecommendationActions: View {
    let recommendations: [InsightRecommendation]
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !recommendations.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                ForEach(recommendations) { rec in
                    if let url = rec.actionURL {
                        Button {
                            openURL(url)
                        } label: {
                            HStack(spacing: HLSpace.xs) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.hlIcon(HLIconSize.sm))
                                Text(rec.label)
                                    .font(.hlSubhead.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(HLText.primary)
                            .padding(.vertical, HLSpace.xs)
                            .padding(.horizontal, HLSpace.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(HLSurface.tertiary, in: RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
                        }
                        .hlPressable() // QOL-AUDIT H1: press feedback (M1 filled pill)
                        .accessibilityHint(Text(String(localized: "Opens the recommended action")))
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                            Image(systemName: "circle.fill")
                                // swiftlint:disable:next dynamic_type_bypass
                                .font(.system(
                                    size: 4
                                )) // 4pt bullet separator dot — purely decorative, intentionally fixed below the HLIconSize.xs floor;
                                // scaling it would break the inline bullet rhythm.
                                .foregroundStyle(HLText.tertiary)
                                .accessibilityHidden(true) // decorative bullet
                            Text(rec.label)
                                .font(.hlSubhead)
                                .foregroundStyle(HLText.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.top, HLSpace.xxs)
        }
    }
}

// MARK: - Metrics grid

struct MetricsGrid: View {
    let metrics: [DashboardMetric]
    let states: [MetricKind: MetricDataState]
    /// W-IMPL-MOTION-POLISH (v0.5.5.1) — matched-geometry namespace forwarded
    /// from `DashboardScreen.matchedGeometryNamespace`. `nil` under
    /// reduce-motion so the tile + destination skip the shared-element
    /// transition entirely.
    let matchedNamespace: Namespace.ID?
    /// v0.8.7 W-NATIVE-REORDER — the raw zoom namespace (never `nil`) for the
    /// native `.matchedTransitionSource(id:in:)`. A transition source must
    /// always be registered; reduce-motion is handled at the destination push,
    /// which only adopts `.navigationTransition(.zoom)` when motion is allowed.
    let zoomNamespace: Namespace.ID
    /// v0.8.7 W-NATIVE-REORDER — true when motion is allowed; gates the subtle
    /// scroll-entrance transition. The zoom push itself stays the default
    /// system transition under reduce-motion (harmless, no extra motion).
    let allowsMotion: Bool
    /// v0.6.2.x bug-c10-ios-direct — HK-direct today step total. Forwarded
    /// into each `DashboardTileRouter`; only the Steps tile honors it.
    var liveTodayStepsOverride: Double?
    /// Build 7 / item 7.1 — digest (7-/30-day averages) + personal targets
    /// (target band) forwarded into every tile. Optional so non-7.1 call sites
    /// keep compiling with the pre-7.1 tile shape.
    var digest: ComprehensiveDigest?
    var targets: InsightsTargetsResponseDTO?
    let onTap: (MetricKind) -> Void

    /// v0.14 A — needed for the long-press "remove from Home" affordance on
    /// dashboard tiles (mirrors the Insights pin gesture).
    @Environment(\.appContainer) private var appContainer

    var body: some View {
        // v0.8.7 W-NATIVE-REORDER — the custom UICollectionView jiggle-reorder
        // engine is gone (it broke four times; the home-screen jiggle is not a
        // public Apple API). Dashboard tiles are all full-width, so a plain
        // `LazyVStack` renders them natively. Reorder / add / remove now lives
        // entirely in the native `DashboardCustomizationScreen` (List + .onMove
        // + visibility toggles), reachable from the always-on toolbar button.
        LazyVStack(spacing: HLSpace.md) {
            ForEach(metrics) { metric in
                tileButton(for: metric)
            }
        }
    }

    private func tileButton(for metric: DashboardMetric) -> some View {
        Button {
            onTap(metric.kind)
        } label: {
            DashboardTileRouter(
                metric: metric,
                dataState: states[metric.kind] ?? .unknown,
                matchedNamespace: matchedNamespace,
                liveTodayStepsOverride: liveTodayStepsOverride,
                digest: digest,
                targets: targets
            )
            // v0.11 perf: mark tile cache-paint so the ≤100 ms p95 budget is
            // measurable in Instruments. No behavioural effect.
            .hlSignpostFirstPaint(.tileCachePaint)
        }
        // W1-7: app-wide press-feedback (scaleEffect 0.97 + selection-haptic)
        .hlPressable()
        .accessibilityAddTraits(.isButton)
        // v0.8.7 W-NATIVE-REORDER — native iOS-18 zoom transition source. The
        // `navigationDestination` content applies `.navigationTransition(.zoom(
        // sourceID:in:))` with the same id + namespace, so the tile zooms into
        // the chart-detail screen. Mirrors `ChartDetailScreen`'s fullscreen
        // zoom usage.
        .matchedTransitionSource(id: metric.kind, in: zoomNamespace)
        // v0.8.7 W-TILE-DYNAMICS — subtle scroll-entrance fade + scale. Kept
        // restrained (operator wants no gamification). Neutralised under
        // reduce-motion: the modifier collapses to the identity phase.
        .scrollTransition { content, phase in
            content
                .opacity(allowsMotion ? (phase.isIdentity ? 1 : 0.0) : 1)
                .scaleEffect(allowsMotion ? (phase.isIdentity ? 1 : 0.96) : 1)
        }
        // v0.14 A — long-press an on-home tile to remove it (or re-add). Same
        // shared menu as the Insights tiles; honest-gated to widget-id metrics.
        .pinToHomeContextMenu(kind: metric.kind, container: appContainer)
    }
}
