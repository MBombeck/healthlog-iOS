import SwiftUI

/// W-B189 (#23) — the Insights **Recovery** special page (web `/insights/recovery`,
/// server v1.17.1).
///
/// Surfaces the SERVER-COMPUTED recovery family — strain, training-load
/// (`CARDIO_LOAD`), autonomic-charge (`ANS_CHARGE`), and the daily
/// heart-and-energy items. **Server-authoritative:** every value is decoded and
/// displayed verbatim; strain / load are NEVER recomputed on-device.
///
/// **Data-gated + HONEST-ONLY.** The page renders only the family items the
/// server returns with a value: 0–100 composites (strain / charge) as canonical
/// `HLScoreRing` ring tiles, raw readings (training-load points, kJ, bpm) as
/// stat rows. An absent / insufficient family is a calm empty state, never a
/// fabricated reading.
///
/// **Lives inside the Insights pager.** Owns no `NavigationStack` (the container
/// does). Its inner `ScrollView` reports its offset to `InsightsStripVisibility`;
/// the page wrapper pins it `.containerRelativeFrame(.horizontal)` ONLY (W44).
/// Header anatomy is the shared `InsightsPageHeader`, identical to the other
/// special + metric pages so the top region never jumps across the pager.
///
/// **Self-suppress:** the pill/page only appears when the operator HAS a
/// renderable family (gated upstream by `availableSpecials` +
/// `RecoveryInsightsStore.hasContent`); the defensive empty branch is calm.
struct InsightsRecoveryPage: View {
    @Environment(RecoveryInsightsStore.self) private var store
    @Environment(InsightsStripVisibility.self) private var stripVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// v1.18.3 — Rest Mode source. The server-authoritative `restMode` rides on
    /// the Health Score; when active (+ illness enabled) the recovery surface
    /// softens its framing into a rest-aware tone (annotate-never-mutate — the
    /// server composites are still rendered verbatim).
    @Environment(HealthScoreStore.self) private var healthScoreStore

    /// 08-11 — the recovery grid falls back to one column at accessibility text
    /// sizes through the same ``InsightsTileGrid`` policy the score block uses,
    /// so the two Insights surfaces cannot disagree about where that begins.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Two-per-row grid for the half-width ring tiles (matches the score block).
    private let columns = [
        GridItem(.flexible(), spacing: HLSpace.md),
        GridItem(.flexible(), spacing: HLSpace.md)
    ]

    /// The grid actually rendered — ``columns`` at standard text sizes, one
    /// column at an accessibility one.
    private var gridColumns: [GridItem] {
        InsightsTileGrid.columns(standard: columns, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        Group {
            if store.hasContent {
                content
            } else {
                emptyState
            }
        }
        .background(HLSurface.primary.ignoresSafeArea())
        .task {
            if store.family == nil { await store.load() }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                InsightsPageHeader(
                    "Recovery",
                    subtitle: "insights.recovery.subtitle",
                    accessibilityIdentifierSuffix: "recovery"
                )

                // Server-mirrored intro paragraph (self-suppresses when the
                // server has no `recovery` explainer copy), identical to the
                // other special pages.
                InsightsExplainerIntro(slug: InsightsLayoutTileId.recovery)

                // A360-1 M2 — discreet pointer to the "Stress and Recovery"
                // /learn guide (mirrors the server's LearnMoreLink on the
                // Resilience surface).
                HLLearnMoreLink(concept: "RESILIENCE")

                // v1.18.3 — when the server flags Rest Mode active (+ illness
                // enabled), soften the recovery framing into a rest-aware tone:
                // a calm "be gentle while you recover" note rather than a
                // push-harder cue. Self-suppresses otherwise; values untouched.
                RestModeGate(score: healthScoreStore.score) { restMode in
                    HLCard(style: .ghost) {
                        RestModeAnnotationPill(restMode: restMode, style: .caption)
                    }
                }

                let scoreItems = store.presentableItems.filter(\.isScore)
                let statItems = store.presentableItems.filter { !$0.isScore }

                if !scoreItems.isEmpty {
                    LazyVGrid(columns: gridColumns, spacing: HLSpace.md) {
                        ForEach(scoreItems) { item in
                            RecoveryRingTile(item: item)
                        }
                    }
                }

                // C3 — the stat archetype now speaks the family's vocabulary.
                // `InsightsMetricStatusCard` is the shape `InsightsMetricScreen`
                // uses for „what is this number and how am I doing", and it is
                // REUSED here rather than forked: the canonical card already
                // self-suppresses per slot, so recovery fills the slots its
                // payload can back (latest reading, unit, the band's on-target
                // chip) and stays silent on the ones it cannot (no in-target
                // share, no window label, no target band, no series). See
                // `RecoverySchema` for the field-by-field reasoning.
                if !statItems.isEmpty {
                    VStack(spacing: HLSpace.md) {
                        ForEach(statItems) { item in
                            if let descriptor = RecoverySchema.descriptor(for: item) {
                                InsightsMetricStatusCard(descriptor: descriptor)
                            }
                        }
                    }
                }

                // C3's honesty half. The gap is stated rather than left to be
                // read as an oversight — „no 30-day figure here, and here is
                // why". It renders off `RecoverySchema.publishesWindowedAggregate`,
                // so the day the C3/C4 server ask is answered and the DTO grows
                // the field, this line disappears by itself instead of having to
                // be remembered.
                if !RecoverySchema.publishesWindowedAggregate, !store.presentableItems.isEmpty {
                    Text("insights.recovery.noAggregate")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, HLSpace.xs)
                        .accessibilityIdentifier("insights.recovery.noAggregate")
                }

                if let asOf = store.family?.asOf {
                    Text("insights.recovery.asOf \(HLDateFormat.dateTime(asOf, style: .abbreviated))")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .padding(.horizontal, HLSpace.xs)
                        .accessibilityIdentifier("insights.recovery.asOf")
                }

                // Canonical sync-status footer (self-suppressing).
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxl)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newOffset in
            stripVisibility.report(offset: newOffset)
        }
        .hlScrollEdgeSoft()
        .hlPullToRefresh { await store.refresh() }
    }

    /// Calm honest empty / unavailable state. Shown only once a load has settled
    /// with no renderable family (route absent, or below the server data gate) —
    /// never a dead box, never a fabricated value.
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: HLSpace.lg) {
                HLEmptyState(
                    icon: "bolt.heart",
                    title: "insights.recovery.empty.title",
                    message: "insights.recovery.empty.body"
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.top, HLSpace.xxxl)
            .padding(.bottom, HLSpace.xxxl)
        }
        .refreshable { await store.refresh() }
        .accessibilityIdentifier("insights.recovery.empty")
    }
}

// MARK: - Ring tile (score archetype: strain / autonomic-charge)

/// A half-width canonical `HLScoreRing` tile for a 0–100 recovery composite
/// (strain / autonomic-charge). Server-authoritative: the ring fraction + value
/// are the server `score`; the single signal cap dot is the server `band`.
private struct RecoveryRingTile: View {
    let item: RecoveryInsightsDTO.Item

    /// 08-11 — the tile's own caps are a standard-size density decision. At an
    /// accessibility size the tile has the full row to itself, so the label is
    /// allowed as many lines as it needs and is never shrunk below the size the
    /// user asked for.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var fraction: Double {
        guard let score = item.score else { return 0 }
        return max(0, min(1, score / 100))
    }

    private var valueText: String {
        item.score.map { "\(Int($0.rounded()))" } ?? "—"
    }

    private var signal: HLScoreRing.HLSignal? {
        HLScoreRing.ScorePresentation.signal(forBand: item.band)
    }

    var body: some View {
        HLCard {
            VStack(spacing: HLSpace.sm) {
                HLScoreRing(
                    fraction: fraction,
                    value: valueText,
                    signal: signal,
                    accessibilityLabel: accessibilityLabel
                )
                .frame(width: 96, height: 96)

                Text(RecoveryFamilyLabels.label(for: item))
                    .font(.hlSubhead.weight(.medium))
                    .foregroundStyle(HLText.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.85)

                if let trend = trendLine {
                    Text(trend)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLSpace.xs)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier("insights.recovery.ring.\(item.id)")
    }

    /// Server-computed trend delta, rendered honestly (no fabrication). `nil`
    /// when the server returned no baseline delta.
    private var trendLine: String? {
        guard let delta = item.trendDelta, delta != 0, let rounded = Int(safeServer: delta) else { return nil }
        let signed = rounded > 0 ? "+\(rounded)" : "\(rounded)"
        return String(localized: "insights.recovery.trend \(signed)")
    }

    private var accessibilityLabel: String {
        let title = RecoveryFamilyLabels.label(for: item)
        guard let score = item.score, let safeScore = Int(safeServer: score) else {
            return String(localized: "\(title): not enough data yet")
        }
        let scoreText = "\(safeScore)"
        return String(localized: "\(title) \(scoreText) of 100")
    }
}

// MARK: - Stat row — REPLACED by the canonical family card (C3, 2026-08-23)

// `RecoveryStatRow` rendered one raw reading per line: a label, the server value
// and a signal dot. Nothing about it was wrong; it simply was not the shape the
// rest of the app uses to say „what is this number and how am I doing", and that
// difference is the whole of C3. The stat archetype now renders through
// `InsightsMetricStatusCard` via `RecoverySchema.descriptor(for:)`, which is the
// SAME component the curated metric pages use — reused, not forked, because the
// canonical shape exists precisely because of an earlier complaint of this kind.
//
// The formatting rules the row carried are not lost: whole-vs-fractional
// rendering and the `Int(safeServer:)` crash-guard (W-CRASHGUARD — `+infinity`
// and `1e30` both equal their own `rounded()` and would trap a bare `Int(value)`)
// moved into `RecoverySchema.headlineValue(for:)` with their reasoning.

// MARK: - Localized family labels

/// Resolves a localized display label for a recovery-family item. The server
/// may emit its own `label` (used verbatim when present); otherwise a known id
/// maps to a localized `insights.recovery.*` string, and an UNKNOWN id falls
/// back to its raw id so a server addition still renders (never a blank row).
enum RecoveryFamilyLabels {
    static func label(for item: RecoveryInsightsDTO.Item) -> String {
        if let serverLabel = item.label, !serverLabel.isEmpty {
            return serverLabel
        }
        switch item.id.uppercased() {
        case "STRAIN", "STRAIN_SCORE": return String(localized: "insights.recovery.label.strain")
        case "CARDIO_LOAD", "TRAINING_LOAD": return String(localized: "insights.recovery.label.trainingLoad")
        case "ANS_CHARGE", "AUTONOMIC_CHARGE": return String(localized: "insights.recovery.label.autonomicCharge")
        case "RECOVERY", "RECOVERY_SCORE": return String(localized: "insights.recovery.label.recovery")
        case "HEART_RATE", "RESTING_HEART_RATE": return String(localized: "insights.recovery.label.heartRate")
        case "ACTIVE_ENERGY", "ENERGY": return String(localized: "insights.recovery.label.energy")
        default:
            // Unknown server id — render its raw token rather than a blank row.
            return item.id
        }
    }
}
