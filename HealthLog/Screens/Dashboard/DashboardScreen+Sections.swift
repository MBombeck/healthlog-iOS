import SwiftUI

// MARK: - Highlight insight card

// `ComplianceRingCard` extracted to its own file so the
// per-snapshot subtitle helper doesn't push `DashboardScreen.swift` past
// the 600-line file-length lint baseline. See `ComplianceRingCard.swift`.

struct HighlightInsightCard: View {
    let insight: Insight?
    /// The server's long `body` stays behind "Mehr anzeigen"; the
    /// card opens with title and summary only.
    @State private var showsBody = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The cards on this tile are rule-based since server v1.39
    /// (`insights/cards` answers `provider: "rules"`), so neither the title nor
    /// the symbol may suggest an assistant wrote them.
    static let symbolName = "lightbulb"
    static var title: String {
        String(localized: "Insight", comment: "Dashboard insight card title — rule-based server cards, not AI (#115 B6)")
    }

    var body: some View {
        if let insight {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    // Today's one card heading: the metric tiles'
                    // glyph and title. No provider badge: from
                    // server v1.39 `insights/cards` are rule-based.
                    HLTileHeaderRow(icon: Self.symbolName, title: Text(Self.title)) { EmptyView() }
                    // Title and text in the size of a card's content: the
                    // tile header above stays the card's one heading.
                    Text(insight.title)
                        .font(HLRowTitle.font)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Never cut off: the summary used to stop after
                    // three lines with the full body right under it.
                    Text(insight.summary)
                        .hlText(.factLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    // The server sends a full `body`
                    // prose paragraph + structured `recommendations` (each
                    // with an optional `actionURL`). The body renders verbatim
                    // (MDR: never paraphrase), on request.
                    if let body = insight.body,
                       !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        if showsBody {
                            Text(body)
                                .hlText(.factLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HLLinkButton(
                            showsBody ? "dashboard.highlight.showFewer" : "dashboard.highlight.showMore",
                            alignment: .leading,
                            isExpanded: showsBody
                        ) {
                            withAnimation(reduceMotion ? nil : HLMotion.spring) { showsBody.toggle() }
                        }
                        .accessibilityIdentifier("dashboard.highlight.toggle")
                    }
                    InsightRecommendationActions(recommendations: insight.recommendations)
                }
            }
        }
    }
}

/// Renders the action buttons for an insight's
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
                        // The link leaves the card for the server's target:
                        // the one external sign, in the shared button.
                        HLButton(
                            Text(verbatim: rec.label),
                            systemImage: HLRowIndicator.externalSymbol,
                            variant: .secondary
                        ) {
                            openURL(url)
                        }
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
                                .hlText(.factLabel)
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
    /// Matched-geometry namespace forwarded
    /// from `DashboardScreen.matchedGeometryNamespace`. `nil` under
    /// reduce-motion so the tile + destination skip the shared-element
    /// transition entirely.
    let matchedNamespace: Namespace.ID?
    /// The raw zoom namespace (never `nil`) for the
    /// native `.matchedTransitionSource(id:in:)`. A transition source must
    /// always be registered; reduce-motion is handled at the destination push,
    /// which only adopts `.navigationTransition(.zoom)` when motion is allowed.
    let zoomNamespace: Namespace.ID
    /// True when motion is allowed; gates the subtle
    /// scroll-entrance transition. The zoom push itself stays the default
    /// system transition under reduce-motion (harmless, no extra motion).
    let allowsMotion: Bool
    /// HK-direct today step total. Forwarded
    /// into each `DashboardTileRouter`; only the Steps tile honors it.
    var liveTodayStepsOverride: Double?
    /// Build 7 / item 7.1 — digest (7-/30-day averages) + personal targets
    /// (target band) forwarded into every tile. Optional so non-7.1 call sites
    /// keep compiling with the pre-7.1 tile shape.
    var digest: ComprehensiveDigest?
    var targets: InsightsTargetsResponseDTO?
    /// 1.5 VERDICTS — the snapshot's trend verdicts (`tiles.directions`).
    var snapshot: DashboardSnapshotBriefing?
    let onTap: (MetricKind) -> Void

    /// v0.14 A — needed for the long-press "remove from Home" affordance on
    /// dashboard tiles (mirrors the Insights pin gesture).
    @Environment(\.appContainer) private var appContainer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // The custom UICollectionView jiggle-reorder
        // engine is gone (it broke four times; the home-screen jiggle is not a
        // public Apple API). Reorder / add / remove now lives
        // entirely in the native `DashboardCustomizationScreen` (List + .onMove
        // + visibility toggles), reachable from the always-on toolbar button.
        // Tiles sit closer than cards: the grid is denser than the card run.
        // One full-width column on the phone and in a narrow column, as many
        // tiles side by side as the measured width holds elsewhere. Eager,
        // like the page around it: a handful of tiles, and a lazy stack in a
        // page has frozen the main thread before.
        let grid = TodayLayout.textSizedGrid(dynamicTypeSize)
        grid {
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
                targets: targets,
                snapshot: snapshot
            )
            // v0.11 perf: mark tile cache-paint so the ≤100 ms p95 budget is
            // measurable in Instruments. No behavioural effect.
            .hlSignpostFirstPaint(.tileCachePaint)
        }
        // App-wide press-feedback (scaleEffect 0.97 + selection-haptic); the
        // tile rises under the pointer like every card.
        .hlPressable(hover: .lift)
        .accessibilityAddTraits(.isButton)
        // Native iOS-18 zoom transition source. The
        // `navigationDestination` content applies `.navigationTransition(.zoom(
        // sourceID:in:))` with the same id + namespace, so the tile zooms into
        // the chart-detail screen. Mirrors `ChartDetailScreen`'s fullscreen
        // zoom usage.
        .matchedTransitionSource(id: metric.kind, in: zoomNamespace)
        // Subtle scroll-entrance fade + scale. Kept
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
