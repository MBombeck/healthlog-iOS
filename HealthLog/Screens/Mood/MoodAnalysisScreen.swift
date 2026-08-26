import SwiftUI

/// v0.10.0 W-Mood-A — the More → Stimmung analysis surface (DESIGN-A).
///
/// Replaces the infinite history table with a calm, scrollable 4-zone analysis
/// screen that reads top-down like a paragraph: present-state (hero) → texture
/// (heatmap) → trajectory (trend) → steadiness (stability) → drivers (tags +
/// patterns) → evidence (recent-7 + the door to everything).
///
/// **Glass discipline (DESIGN-A §2):** exactly two glass surfaces — the nav-bar
/// scroll-edge + the one floating period control. ZERO glass on content cards.
/// **Monochrome:** color is signal only (trend direction, heatmap intensity,
/// the one warmed stability/pattern dot). **Honesty gates:** every analytic
/// surface self-suppresses when sparse — the screen grows into itself.
/// **Fully offline:** all stats client-computed from `store.entries`;
/// `/api/mood/analytics` is enrichment only.
struct MoodAnalysisScreen: View {
    @Environment(MoodStore.self) private var store

    @State private var period: MoodPeriod = .days30
    @State private var editing: MoodEntry?
    @State private var showFullHistory = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                analysisScroll
            }
        }
        .hlScreenBackground()
        .navigationTitle("Mood")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) {
            if !store.entries.isEmpty {
                // DRIFT-4 — the canonical `HLFloatingPeriodControl` (was the
                // `MoodPeriodControl` thin wrapper, now retired). `MoodPeriod`
                // conforms to `HLRangeOption`, so the generic control drives it
                // directly with the same capsule chrome as every Insights page.
                HLFloatingPeriodControl(selection: $period, accessibilityLabelText: "Time range")
            }
        }
        .sheet(item: $editing) { entry in
            EditMoodSheet(entry: entry, onDismiss: { editing = nil })
                .hlSheetPresentation(.form)
        }
        .navigationDestination(isPresented: $showFullHistory) {
            MoodHistoryScreen()
        }
        .task {
            if store.entries.isEmpty { await store.load() }
        }
    }

    private var analysisScroll: some View {
        ScrollView {
            VStack(spacing: HLSpace.lg) {
                // v0.12 W4-3 — the seven analysis sub-views now live in the
                // shared `MoodAnalysisContent` (one implementation for both
                // More → Stimmung and Insights → Stimmung). This host supplies
                // the DESIGN-A staggered zone entrance via the `section`
                // decorator; the Insights host renders the same sections plain.
                MoodAnalysisContent(
                    period: period,
                    editing: $editing,
                    showFullHistory: $showFullHistory
                ) { index, content in
                    zone(index, content)
                }

                // v0.14.8 W2-SYNCUX — canonical sync-status footer (same
                // primitive as Dashboard/Insights, self-suppressing).
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxl)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: period)
        }
        .hlScrollEdgeSoft()
        // W-B184 — WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic; the handshake driving the checkmark runs in the modifier).
        .hlPullToRefresh { await store.load() }
        .onAppear {
            guard !reduceMotion else {
                appeared = true
                return
            }
            withAnimation(.easeInOut(duration: 0.18)) { appeared = true }
        }
    }

    /// One orchestrated entrance (DESIGN-A §5.1): gentle fade+rise stagger on
    /// first appear; Reduce-Motion → instant.
    private func zone(_ index: Int, _ content: AnyView) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 8)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18).delay(Double(index) * 0.04),
                value: appeared
            )
    }

    private var emptyState: some View {
        HLEmptyState(
            icon: "face.smiling",
            title: "No entries yet",
            message: "Log your first mood to see your history."
        )
        .accessibilityIdentifier("mood.analysis.empty")
        .containerCentered()
    }
}
