import SwiftUI

/// First-paint placeholder when `DashboardStore.summary` is nil. Extracted
/// out of `DashboardScreen.swift` so the parent screen stays under the
/// 600-line swiftlint `file_length` warning threshold.
///
/// **v0.5.5.1 — `HLSkeleton` adoption (W-IMPL-SKELETON):** the placeholder
/// silhouette mirrors the actual dashboard layout using the design-system
/// `HLSkeleton` primitive — shape-aware shimmer that respects
/// `accessibilityReduceMotion` at the token layer.
///
/// **v0.12 W3-4 — silhouette-match fix:** the tile region previously rendered
/// a 2-column `LazyVGrid`, but the live dashboard tiles render as a full-width
/// `LazyVStack` (`DashboardScreen.tileColumn`). On cold launch the 2-up grid
/// reflowed into a 1-up column the instant data landed — a visible layout jump
/// on the primary entry screen. The placeholder now renders a full-width
/// `LazyVStack` of `HLCard` placeholders mirroring `.cards`, so the skeleton
/// and the live grid occupy the same boxes and the data-arrival is a pure
/// cross-fade, not a re-flow.
struct SkeletonContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            // HealthScore + briefing hero. The live tile renders a 92pt
            // compliance ring on the left, score value + caption on the
            // right. We mirror that silhouette so cold-launch doesn't
            // collapse into a single blank slab.
            HLCard {
                HStack(spacing: HLSpace.lg) {
                    HLSkeleton(.circle, width: 92, height: 92)
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        HLSkeleton(.capsule, width: 140, height: 14)
                        HLSkeleton(.capsule, width: 100, height: 28)
                        HLSkeleton(.capsule, width: 180, height: 12)
                    }
                    Spacer(minLength: 0)
                }
            }

            // Full-width metric-tile stack — mirrors the live full-width
            // `LazyVStack` rhythm (one card per row, edge-to-edge). Five
            // placeholders covers the typical above-the-fold density
            // (Gewicht, Puls, BP, Schlaf, Schritte) without over-promising.
            LazyVStack(spacing: HLSpace.md) {
                ForEach(0 ..< 5, id: \.self) { _ in
                    HLCard {
                        HStack(spacing: HLSpace.md) {
                            HLSkeleton(.circle, width: 28, height: 28)
                            VStack(alignment: .leading, spacing: HLSpace.sm) {
                                HLSkeleton(.capsule, width: 90, height: 12)
                                HLSkeleton(.capsule, width: 130, height: 24)
                            }
                            Spacer(minLength: 0)
                            HLSkeleton(.capsule, width: 44, height: 12)
                        }
                    }
                }
            }
        }
    }
}
