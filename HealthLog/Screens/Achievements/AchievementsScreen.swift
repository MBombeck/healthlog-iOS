import SwiftUI

/// Apple-Fitness-Activity-Awards-style 3-column medallion grid with a slim
/// progress strip on top. Pushed from `MoreScreen` inside the parent
/// NavigationStack — **this screen no longer wraps its own NavigationStack**
/// (Foxtrot v0.4.0) so the parent stack handles `navigationTitle` +
/// back-chevron + sheets.
///
/// POLISH-ACHIEVE redesign:
/// - Old: 2-col chunky `HLCard` grid (~140pt per cell, surface chrome, in-card
///   progress bars). Read as a "stats panel".
/// - New: 3-col free-floating circular medallions. Earned cells glow with a
///   gradient-ring + accent-tinted fill (Apple Fitness "Award"); locked cells
///   render with a dotted-stroke ring + dimmed glyph + "Noch nicht
///   freigeschaltet" long-press tooltip. Reads as a "trophy shelf".
/// - Slimmer Fortschritt strip up top (was a heavy `HLCard`).
///
/// Bug-fix carry-over (A7 §1.3, user-report #9):
/// 1. **Lucide icons silent-fail** — uses Echo's `Image(lucide:)` initializer
///    so server-shaped names (`"Trophy"`, `"Flame"`, `"Pill"` …) resolve to
///    real SF Symbols via `LucideToSF.map(_:)`.
/// 2. **Tap target missing** — each medallion is a `Button` that selects the
///    achievement → presents `AchievementDetailSheet` at `.medium` detent.
/// 3. **Points display** — slim strip shows earned / total points;
///    detail sheet shows the full points block + share button (if earned).
///
/// Plus:
/// - Empty state with humane copy when the store loads zero achievements.
/// - Hidden-card opaque-placeholder render (mirrors the server's web treatment).
/// - `.hlScreenBackground()` for canonical color.
struct AchievementsScreen: View {
    @Environment(AchievementsStore.self) private var store
    @State private var selectedAchievement: Achievement?
    private let columns = [
        GridItem(.flexible(), spacing: HLSpace.md),
        GridItem(.flexible(), spacing: HLSpace.md),
        GridItem(.flexible(), spacing: HLSpace.md)
    ]

    var body: some View {
        HLPage {
            HLStateContainer(loadPhase) {
                // Cold-launch placeholder cards matching the medallion
                // silhouette (circle + tiny title).
                skeletonGrid
            } empty: {
                emptyState
            } content: {
                grid
            }
        }
        .navigationTitle("achievements.title")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.revalidateIfStale() }
        // WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic; the handshake driving the checkmark runs in the modifier).
        .hlPullToRefresh { await store.load() }
        // The banner below still presents as this overlay; this
        // reserves its height at the top so it covers nothing.
        .hlReserveErrorBannerSpace(store.error)
        .overlay(alignment: .top) {
            ErrorBanner(error: store.error) {
                Task { await store.load() }
            }
        }
        .sheet(item: $selectedAchievement) { achievement in
            AchievementDetailSheet(achievement: achievement)
        }
        // v0.5.5.1 haptic migration: replaces the per-cell
        // `UISelectionFeedbackGenerator().selectionChanged()` with a
        // declarative `.sensoryFeedback`. Fires whenever the user picks an
        // achievement (selection moves to a non-nil token) — SwiftUI handles
        // prepare-and-fire + Reduce-Motion semantics, dropping the UIKit
        // dependency from this screen entirely.
        .sensoryFeedback(.selection, trigger: selectedAchievement?.id)
    }

    /// Cold-launch gate — first load while the store is hydrating from
    /// the server and we have nothing cached locally.
    private var isShowingInitialSkeleton: Bool {
        store.isLoading && store.achievements.isEmpty && store.error == nil
    }

    private var loadPhase: HLLoadPhase {
        if isShowingInitialSkeleton { return .loading }
        if store.achievements.isEmpty, !store.isLoading, store.error == nil { return .empty }
        return .loaded
    }

    private var skeletonGrid: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            progressStripSkeleton
            LazyVGrid(columns: columns, spacing: HLSpace.lg) {
                ForEach(0 ..< 9, id: \.self) { _ in
                    VStack(spacing: HLSpace.xs) {
                        HLSkeleton(.circle, width: 72, height: 72)
                        HLSkeleton(.capsule, width: 68, height: 10)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading achievements"))
    }

    private var progressStripSkeleton: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSkeleton(.capsule, width: 96, height: 10)
            HStack(alignment: .firstTextBaseline) {
                HLSkeleton(.capsule, width: 80, height: 24)
                Spacer()
                HLSkeleton(.capsule, width: 60, height: 18)
            }
            HLSkeleton(.rect, height: 4, cornerRadius: 2)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var grid: some View {
        progressStrip
        // No rest-mode paragraph between progress and grid; the
        // note lives on Today and the recovery page.
        LazyVGrid(columns: columns, spacing: HLSpace.lg) {
            ForEach(store.achievements) { achievement in
                AchievementMedallionButton(
                    achievement: achievement,
                    onTap: { selectedAchievement = achievement }
                )
            }
        }
        // Canonical sync-status footer (same
        // primitive as Dashboard/Insights, self-suppressing).
        HLSyncStatusFooter(screenLoading: store.isLoading)
    }

    /// Slim inline progress strip — replaces the legacy elevated `HLCard`.
    /// Withings-Tonal-Mono treatment: section header in uppercased
    /// `.hlFootnote`, a quiet count + percent chip, a hairline progress rail.
    @ViewBuilder
    private var progressStrip: some View {
        HLSectionHeader("Progress", rank: .area)
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                // Unlocked over total in the tile size: a quiet anchor, not
                // the page's hero.
                HLValueText(
                    Double(store.unlockedCount),
                    Double(store.totalCount),
                    unit: .plain,
                    size: .tile,
                    fractionDigits: 0 ... 0
                )
                Spacer()
                HLBadge(percentLabel, icon: "trophy.fill", tone: .warning)
            }
            if store.totalPoints > 0 {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "star.circle.fill")
                        .foregroundStyle(HLText.secondary)
                        .font(.hlIcon(HLIconSize.sm))
                    Text("\(store.earnedPoints) / \(store.totalPoints) points")
                        .font(.hlCaption.weight(.medium))
                        .foregroundStyle(HLText.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(store.earnedPoints) of \(store.totalPoints) points earned"))
            }
            // Inherit the scene-root `.tint(preferredTint)` instead
            // of pinning the asset-catalog accent, so the live user tint drives
            // the bar.
            // v0.16 Build 7 / item 7.4 — the rail tracks POINTS (earned / total),
            // web parity with the achievements header's primary points tile.
            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .accessibilityLabel(Text("\(store.earnedPoints) of \(store.totalPoints) points earned"))
        }
    }

    /// Achievements empty surface — the canonical `HLEmptyState` lockup
    /// (audit-01 C1), centered like the system primitive was.
    private var emptyState: some View {
        HLEmptyState(
            icon: "trophy.fill",
            title: "No achievements yet",
            message: "Log values or take medications — badges unlock step by step."
        )
        .accessibilityIdentifier("achievements.empty")
    }

    // MARK: - Derived

    /// v0.16 Build 7 / item 7.4 — the top rail + its percentage badge track
    /// POINTS (earned / total), mirroring the web achievements header's primary
    /// points tile (`earnedPoints / totalPoints`) rather than the unlocked-count
    /// ratio. The unlocked count stays the hero number above for context.
    private var progressValue: Double {
        guard store.totalPoints > 0 else { return 0 }
        return Double(store.earnedPoints) / Double(store.totalPoints)
    }

    private var percentLabel: String {
        guard store.totalPoints > 0 else { return HLNumberFormat.percent(0) }
        // Rounded, not truncated (`Int(x * 100)` read 2/3 as 66 %).
        return HLNumberFormat.percent(fraction: progressValue)
    }
}
