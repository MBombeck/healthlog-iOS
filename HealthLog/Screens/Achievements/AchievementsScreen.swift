import SwiftUI

/// Apple-Fitness-Activity-Awards-style 3-column medallion grid with a slim
/// progress strip on top. Pushed from `MoreScreen` inside the parent
/// NavigationStack — **this screen no longer wraps its own NavigationStack**
/// (Foxtrot v0.4.0) so the parent stack handles `navigationTitle` +
/// back-chevron + sheets.
///
/// POLISH-ACHIEVE (v0.5.5.6) redesign:
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
/// - `.hlScreenBackground()` for canonical color (A6 §4).
struct AchievementsScreen: View {
    @Environment(AchievementsStore.self) private var store
    /// v1.18.3 — Rest Mode source (server-authoritative via the Health Score).
    /// When active (+ illness enabled) a calm note softens the streak-pressure
    /// framing so a recovery gap never reads as a failure. Annotate-never-mutate.
    @Environment(HealthScoreStore.self) private var healthScoreStore
    @State private var selectedAchievement: Achievement?
    private let columns = [
        GridItem(.flexible(), spacing: HLSpace.md),
        GridItem(.flexible(), spacing: HLSpace.md),
        GridItem(.flexible(), spacing: HLSpace.md)
    ]

    /// Pixel-Match (28pt) bei Default-Dynamic-Type, skaliert mit Accessibility-
    /// Sizes über `@ScaledMetric` (Audit M5). Slimmer than the legacy 36pt
    /// hero number — the strip is now a quiet anchor, not a billboard.
    @ScaledMetric(relativeTo: .title2) private var progressValueSize: CGFloat = 28

    var body: some View {
        Group {
            if isShowingInitialSkeleton {
                // v0.5.5.2 W-IMPL-SKELETON: cold-launch placeholder cards
                // matching the medallion silhouette (circle + tiny title)
                skeletonGrid
            } else if store.achievements.isEmpty, !store.isLoading, store.error == nil {
                emptyState
            } else {
                grid
            }
        }
        .hlScreenBackground()
        // v0.5.x C-9 — iOS 26+ soft scroll-edge so content blurs into
        // the navigation Liquid Glass instead of clipping cleanly.
        // iOS 18-25: no-op (system stays flat-translucent).
        .hlScrollEdgeSoft()
        .navigationTitle("achievements.title")
        .task { await store.revalidateIfStale() }
        // W-B184 — WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic; the handshake driving the checkmark runs in the modifier).
        .hlPullToRefresh { await store.load() }
        .overlay(alignment: .top) {
            ErrorBanner(error: store.error) {
                Task { await store.load() }
            }
        }
        .sheet(item: $selectedAchievement) { achievement in
            AchievementDetailSheet(achievement: achievement) {
                selectedAchievement = nil
            }
            .hlSheetPresentation(.standard)
            .presentationCornerRadius(HLRadius.sheet)
            // v0.6.1 Y2 — Home-Compliance background. The .sheet(item:)
            // binding nils on drag-down dismiss, so the Schließen-removal
            // in the body still routes through SwiftUI's standard
            // dismiss-clears-the-binding semantics.
            .presentationBackground(HLColor.surface)
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

    private var skeletonGrid: some View {
        ScrollView {
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
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.md)
            .padding(.bottom, HLSpace.lg)
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

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                progressStrip
                // v1.18.3 — soften streak-pressure copy while resting. A calm,
                // monochrome acknowledgement that a recovery gap is expected and
                // doesn't undo progress. Self-suppresses when not in Rest Mode.
                RestModeGate(score: healthScoreStore.score) { restMode in
                    RestModeAnnotationPill(restMode: restMode, style: .caption)
                }
                LazyVGrid(columns: columns, spacing: HLSpace.lg) {
                    ForEach(store.achievements) { achievement in
                        AchievementMedallionButton(
                            achievement: achievement,
                            onTap: { selectedAchievement = achievement }
                        )
                    }
                }
                // v0.14.8 W2-SYNCUX — canonical sync-status footer (same
                // primitive as Dashboard/Insights, self-suppressing).
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.md)
            // Native iOS-18 `TabView` already supplies the bottom inset;
            // tighter than the legacy `HLSpace.lg` to land flush with the
            // tab-bar safe-area pad on iPhone 17 Pro.
            .padding(.bottom, HLSpace.md)
        }
    }

    /// Slim inline progress strip — replaces the legacy elevated `HLCard`.
    /// Withings-Tonal-Mono treatment: section header in uppercased
    /// `.hlFootnote`, a quiet count + percent chip, a hairline progress rail.
    private var progressStrip: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel("Progress")
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Text("\(store.unlockedCount)/\(store.totalCount)")
                    .font(.hlMetric(progressValueSize))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
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
            // v0.8.0 W6 — inherit the scene-root `.tint(preferredTint)` instead
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
        .containerCentered()
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
        let p = Int(progressValue * 100)
        return HLNumberFormat.percent(p)
    }
}
