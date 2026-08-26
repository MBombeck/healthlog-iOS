import SwiftUI

/// Shape-aware placeholder for the cold-launch Insights tab. Mirrors the
/// live composition rhythm — HealthScore hero, two insight cards, an
/// observation card with a chart well, and a recommendation row. Renders
/// only while `InsightsScreen.isShowingInitialSkeleton` is true (digest
/// missing, cards empty, trend-input measurements empty AND a fetch is
/// in-flight); a single non-empty source flips the gate back to the
/// live composition.
///
/// Lives in its own file so `InsightsScreen.swift` stays under the
/// 600-line SwiftLint `file_length` baseline once the W-IMPL-SKELETON
/// skeleton-vs-live gate splits the body into two computed branches.
struct InsightsSkeletonContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            // HealthScore hero — 92pt ring + score/caption capsules.
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

            // BMI / BP-style insight cards — title row + value strip.
            ForEach(0 ..< 2, id: \.self) { _ in
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        HLSkeleton(.capsule, width: 120, height: 16)
                        HStack(spacing: HLSpace.md) {
                            HLSkeleton(.capsule, width: 80, height: 28)
                            HLSkeleton(.capsule, width: 100, height: 12)
                            Spacer(minLength: 0)
                        }
                        HLSkeleton(.capsule, width: 220, height: 12)
                    }
                }
            }

            // Trend observation / chart card silhouette — title + tall
            // rectangle well + small caption.
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLSkeleton(.capsule, width: 160, height: 16)
                    HLSkeleton(.rect, height: HLChartStyle.heightCompact, cornerRadius: 12)
                    HLSkeleton(.capsule, width: 200, height: 12)
                }
            }

            // Recommendation row — sparkles icon + body capsules.
            HLCard {
                HStack(spacing: HLSpace.md) {
                    HLSkeleton(.circle, width: 24, height: 24)
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        HLSkeleton(.capsule, width: 200, height: 14)
                        HLSkeleton(.capsule, width: 140, height: 12)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
