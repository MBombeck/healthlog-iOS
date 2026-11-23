import SwiftUI

/// **S4b (marathon b182) — the shared leaf-tile SURFACE for the switchable
/// Insights score tiles.**
///
/// One helper all five ring cards wrap their lockup in, so the per-style surface
/// branch (mono `HLCard` / one shared neutral gradient) lives in
/// exactly ONE place. The content lockup (ring / number / label) is supplied by
/// the card; this view only decides the chrome. Removability post-selection is
/// mechanical: inline the winning branch and delete the rest.
///
/// - **mono** (A / B / D / E): the plain `HLCard` surface — identical chrome to
///   every other card in the app (kills the R5 cross-screen inconsistency).
/// - The glass surfaces (C, P4) are gone: a tile is content, and glass only
///   floats above content.
/// - **restrainedGradient** (F): ONE shared very-subtle warm-neutral gradient on
///   every tile (drops the eight per-metric hues), reusing the existing glow +
///   border + shadow chrome from `WellnessGradientCard` so the grid reads as one
///   calm field with gentle depth instead of a rainbow.
struct InsightsTileSurface<Content: View>: View {
    let appearance: InsightsTileAppearance
    /// Grid index — phase-offsets the restrained-gradient "living light" breath so
    /// neighbouring tiles never pulse in unison (reused from `WellnessTileMotion`).
    var glowPhaseIndex: Int = 0
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `false` once the overview's motion window has closed.
    @Environment(\.insightsRingMotionActive) private var motionActive

    /// Live Low-Power read — the breath drops to its static mid value when on,
    /// mirroring the canonical gate on the prism/cycle-glow drivers
    /// (`InsightsPrismShader.swift`, `InsightsRingEffects.swift`).
    private var lowPower: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
    }

    var body: some View {
        switch appearance.surface {
        case .mono:
            // Fills the height its grid row offers, so the tiles of a row
            // stand equally tall. Outside a row nothing offers more height.
            HLCard { content.frame(maxHeight: .infinity) }
        case .restrainedGradient:
            gradientSurface
        }
    }

    /// Concept F — one shared neutral warm gradient on every tile, with the same
    /// breathing white radial lift + border + shadow as `WellnessGradientCard` so
    /// the depth reads as quiet life, not decoration.
    private var gradientSurface: some View {
        content
            .padding(HLSpace.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Self.sharedNeutralGradient
                    glow
                }
            }
            .clipShape(cardShape)
            .overlay(
                cardShape.strokeBorder(HLColor.wellnessTileBorder, lineWidth: 1)
            )
            .hlShadow(HLShadow.cardLight)
    }

    /// The SINGLE shared neutral gradient for Concept F — a hair-lighter top
    /// corner blending to the shared near-black `wellnessGradientDark` base. One
    /// tone on every tile, so the grid reads as one calm field, not a rainbow.
    static var sharedNeutralGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(
                    color: HLColor.wellnessGradientDark.blended(with: .white, fraction: 0.06),
                    location: 0
                ),
                .init(color: HLColor.wellnessGradientDark, location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The breathing white radial lift (reused from `WellnessGradientCard`).
    /// Static at the mid (`breath == 0`) value under Reduce Motion OR Low-Power;
    /// otherwise a slow sine breath phase-offset per tile. The `TimelineView` is
    /// capped to the canonical 20 fps driver interval (matching the prism /
    /// cycle-glow drivers) instead of running at full display refresh, and
    /// `paused:` collapses it to its still frame when gated.
    @ViewBuilder
    private var glow: some View {
        let paused = WellnessTileMotion.isPaused(reduceMotion: reduceMotion, lowPower: lowPower, atRest: !motionActive)
        TimelineView(.animation(minimumInterval: WellnessTileMotion.frameInterval, paused: paused)) { context in
            let b = paused
                ? 0
                : WellnessTileMotion.breath(
                    seconds: context.date.timeIntervalSinceReferenceDate,
                    index: glowPhaseIndex
                )
            radialGlow(
                opacityScale: WellnessTileMotion.opacityScale(breath: b),
                endRadius: WellnessTileMotion.endRadius(breath: b)
            )
        }
    }

    private func radialGlow(opacityScale: Double, endRadius: CGFloat) -> some View {
        RadialGradient(
            colors: [HLColor.wellnessTileGlow.opacity(opacityScale), Color.clear],
            center: .center,
            startRadius: 0,
            endRadius: endRadius
        )
    }
}

// MARK: - The grid tiles stand in

/// The grid the tiles of Today and Insights stand in.
///
/// The column count is ``HLAdaptiveGrid``'s: as many columns as tiles of
/// `minimumTileWidth` fit, at most `maximumColumns`, even where asked. Every
/// tile of a row is as tall as the tallest. A single column fills the width
/// it is given, like every card beside it, so on the phone the tiles stand as
/// they always did.
///
/// With `maximumTileWidth` (the score rings of Insights, ``HLLayout/tileMaxWidth``)
/// a wider row stands centred, so a ring never floats in an empty tile.
/// Without it (the metric tiles of Today) the row fills its width, so its
/// edges line up with the cards above it in the same column.
///
/// One grid with these two choices instead of a second layout: everything
/// else is ``HLAdaptiveGrid``'s rule.
struct HLTileGrid: Layout {
    /// The smallest a ring tile (ring, value, name) may get: the phone's two
    /// columns at every width down to a 320 pt window (136 pt each there),
    /// and five scores in one row from the iPad mini on (712 pt of content
    /// with the 16 pt tile gap). With even columns the folded Duo stays at two.
    static let ringTileMinimumWidth: CGFloat = 128

    let minimumTileWidth: CGFloat
    let maximumColumns: Int
    let evenColumns: Bool
    let maximumTileWidth: CGFloat?
    let spacing: CGFloat
    /// Whether the count is chosen so no tile stands alone in the last row
    /// (``columns(width:itemCount:)``).
    let avoidsLoneTile: Bool
    /// Whether a tile left alone in the last row anyway (an odd count in
    /// even columns, five scores on the phone) takes the whole row instead
    /// of standing beside a hole.
    let spansLoneTile: Bool

    init(
        minimumTileWidth: CGFloat,
        maximumColumns: Int,
        evenColumns: Bool = false,
        maximumTileWidth: CGFloat? = HLLayout.tileMaxWidth,
        spacing: CGFloat = HLLayout.tileGap,
        avoidsLoneTile: Bool = false,
        spansLoneTile: Bool = false
    ) {
        self.minimumTileWidth = minimumTileWidth
        self.maximumColumns = maximumColumns
        self.evenColumns = evenColumns
        self.maximumTileWidth = maximumTileWidth
        self.spacing = spacing
        self.avoidsLoneTile = avoidsLoneTile
        self.spansLoneTile = spansLoneTile
    }

    /// The width of the tile at `index` of `itemCount` in `count` columns:
    /// the row's width for a lone last tile where the grid spans it, the
    /// column's otherwise.
    func tileWidth(width: CGFloat, count: Int, index: Int, itemCount: Int) -> CGFloat {
        let isLoneLast = count > 1 && index == itemCount - 1 && itemCount % count == 1
        return spansLoneTile && isLoneLast ? rowWidth(width: width, count: count) : tileWidth(width: width, count: count)
    }

    /// The number of columns for `itemCount` tiles at `width`. Without
    /// `avoidsLoneTile`, or where the last row is not a single tile, it is
    /// ``columns(width:)``. Otherwise every tile stands in one row where the
    /// width holds them all (an odd count with even columns only from
    /// ``oddRowMinimumWidth`` on); else fewer columns, even ones staying even,
    /// until no tile is left alone. Where none helps (an odd count in even columns,
    /// the open Duo) the count stays.
    func columns(width: CGFloat, itemCount: Int) -> Int {
        let base = columns(width: width)
        guard avoidsLoneTile, Self.leavesLoneTile(itemCount: itemCount, columns: base) else { return base }
        let fitting = HLAdaptiveGrid.columns(
            width: width,
            minimum: minimumTileWidth,
            maximum: maximumColumns,
            spacing: spacing
        )
        if itemCount <= fitting, !evenColumns || itemCount.isMultiple(of: 2) || width >= Self.oddRowMinimumWidth {
            return itemCount
        }
        let step = evenColumns ? 2 : 1
        for candidate in stride(from: base - step, through: 2, by: -step)
            where !Self.leavesLoneTile(itemCount: itemCount, columns: candidate)
        {
            return candidate
        }
        return base
    }

    /// From this width on an odd count may stand in one row although the
    /// grid asks for even columns: wider than the open Duo's page (637 pt), so
    /// no fold runs through the row's middle tile. Hausregel.
    static let oddRowMinimumWidth: CGFloat = 700

    /// Whether `itemCount` tiles in `columns` columns leave one tile alone in
    /// the last row.
    static func leavesLoneTile(itemCount: Int, columns: Int) -> Bool {
        columns > 1 && itemCount > columns && itemCount % columns == 1
    }

    /// The number of columns at `width`, the width the grid is given.
    func columns(width: CGFloat) -> Int {
        HLAdaptiveGrid.columns(
            width: width,
            minimum: minimumTileWidth,
            maximum: maximumColumns,
            spacing: spacing,
            even: evenColumns
        )
    }

    /// The width of one tile at `width`: the full width in one column, the
    /// even share of the row otherwise, capped where a cap is set.
    func tileWidth(width: CGFloat) -> CGFloat {
        tileWidth(width: width, count: columns(width: width))
    }

    /// How wide the row stands at `width`; the rest is shared on both sides.
    func rowWidth(width: CGFloat) -> CGFloat {
        rowWidth(width: width, count: columns(width: width))
    }

    func tileWidth(width: CGFloat, count: Int) -> CGFloat {
        guard count > 1 else { return max(0, width) }
        let share = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return max(0, min(maximumTileWidth ?? share, share))
    }

    func rowWidth(width: CGFloat, count: Int) -> CGFloat {
        tileWidth(width: width, count: count) * CGFloat(count) + spacing * CGFloat(count - 1)
    }

    struct Cache {
        var width: CGFloat = -1
        var rowHeights: [CGFloat] = []
    }

    func makeCache(subviews _: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews _: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? idealWidth
        measure(width: width, subviews: subviews, cache: &cache)
        let rows = CGFloat(cache.rowHeights.count)
        return CGSize(width: width, height: cache.rowHeights.reduce(0, +) + spacing * max(0, rows - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        measure(width: bounds.width, subviews: subviews, cache: &cache)
        let count = columns(width: bounds.width, itemCount: subviews.count)
        let tile = tileWidth(width: bounds.width, count: count)
        let leading = bounds.minX + max(0, (bounds.width - rowWidth(width: bounds.width, count: count)) / 2)
        var y = bounds.minY
        for (row, height) in cache.rowHeights.enumerated() {
            for column in 0 ..< count where row * count + column < subviews.count {
                let index = row * count + column
                let width = tileWidth(width: bounds.width, count: count, index: index, itemCount: subviews.count)
                // One column: the tile's own height; a row: the tallest one's.
                let proposed = count > 1 ? height : nil
                subviews[index].place(
                    at: CGPoint(x: leading + CGFloat(column) * (tile + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: proposed)
                )
            }
            y += height + spacing
        }
    }

    private func measure(width: CGFloat, subviews: Subviews, cache: inout Cache) {
        guard cache.width != width else { return }
        let count = columns(width: width, itemCount: subviews.count)
        cache.width = width
        cache.rowHeights = stride(from: 0, to: subviews.count, by: count).map { first in
            (first ..< min(first + count, subviews.count))
                .map { index in
                    let tile = tileWidth(width: width, count: count, index: index, itemCount: subviews.count)
                    return subviews[index].sizeThatFits(ProposedViewSize(width: tile, height: nil)).height
                }
                .max() ?? 0
        }
    }

    /// Without a proposed width the grid asks for its maximum columns of
    /// minimum tiles.
    private var idealWidth: CGFloat {
        let count = CGFloat(max(1, maximumColumns))
        return minimumTileWidth * count + spacing * (count - 1)
    }
}

#Preview("Insights tile (P9 prismUniform)") {
    ScrollView {
        HLTileGrid(minimumTileWidth: HLTileGrid.ringTileMinimumWidth, maximumColumns: 4, evenColumns: true) {
            previewTile(style: .prismUniform, score: 84, signal: .ok, label: "Readiness", index: 0)
            previewTile(style: .prismUniform, score: 32, signal: .bad, label: "Stress", index: 1)
        }
        .padding(HLSpace.lg)
    }
    .background(HLSurface.primary)
}

@ViewBuilder
@MainActor
private func previewTile(
    style: InsightsTileStyle,
    score: Double,
    signal: HLScoreRing.HLSignal,
    label: String,
    index: Int
) -> some View {
    let appearance = style.appearance(signal: signal)
    InsightsTileSurface(appearance: appearance, glowPhaseIndex: index) {
        VStack(spacing: HLSpace.sm) {
            HLScoreRing(
                fraction: score / 100,
                value: "\(Int(score))",
                signal: appearance.ringSignal,
                fillColor: appearance.ringFill,
                trackColor: appearance.ringTrack,
                centreValueColor: appearance.ringValueColor,
                centreLabelColor: appearance.ringLabelColor
            )
            .frame(width: 96, height: 96)
            .insightsRingEffect(appearance.ringEffect, fraction: score / 100, isHero: index == 0)
            .modifier(WellnessRingShadow(active: appearance.ringShadowActive))
            Text(label)
                .font(.hlSubhead.weight(.medium))
                .foregroundStyle(appearance.labelColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpace.xs)
    }
}
