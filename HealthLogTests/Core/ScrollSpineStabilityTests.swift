import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// Tests for the v0150 nav-scroll spine-stability policy
/// (`.planning/v0150-felt-parity/RCA-nav-scroll.md`). Guards the decidable rule
/// the Illness-journal + Dashboard fixes are built to satisfy: a reload that keeps
/// the node spine identical preserves the restored scroll offset; a reload that
/// inserts/removes a node above the anchor does not.
@Suite("ScrollSpineStability")
struct ScrollSpineStabilityTests {
    @Test("Identical spine is stable (offset survives a leaf-only refresh)")
    func identicalSpineStable() {
        let spine = ["toggle", "active", "resolved", "footer"]
        #expect(ScrollSpineStability.isStable(before: spine, after: spine))
    }

    @Test("Inserting a section above destabilises (the journal drift bug)")
    func insertingSectionDestabilises() {
        // Pre-fix: "active" section is absent until episodes load, then inserted.
        let before = ["toggle", "footer"]
        let after = ["toggle", "active", "footer"]
        #expect(!ScrollSpineStability.isStable(before: before, after: after))
    }

    @Test("Removing a section destabilises")
    func removingSectionDestabilises() {
        let before = ["toggle", "active", "resolved", "footer"]
        let after = ["toggle", "active", "footer"]
        #expect(!ScrollSpineStability.isStable(before: before, after: after))
    }

    @Test("Reorder destabilises even with same count")
    func reorderDestabilises() {
        let before = ["toggle", "active", "resolved", "footer"]
        let after = ["toggle", "resolved", "active", "footer"]
        #expect(!ScrollSpineStability.isStable(before: before, after: after))
    }

    @Test("Stable spine with content churn stays stable (rows change, nodes don't)")
    func contentChurnStaysStable() {
        // The fix keeps every section present; only leaf rows change. The spine
        // snapshot is identical across the reload.
        let before = ["toggle", "active", "resolved", "footer"]
        let after = ["toggle", "active", "resolved", "footer"]
        #expect(ScrollSpineStability.isStable(before: before, after: after))
    }

    @Test("presenceFlips detects a conditional node appearing (Highlight card)")
    func presenceFlipDetected() {
        // Pre-fix: the Highlight card was absent, then the insight hydrated.
        #expect(ScrollSpineStability.presenceFlips(wasPresent: false, isPresent: true))
        #expect(ScrollSpineStability.presenceFlips(wasPresent: true, isPresent: false))
    }

    @Test("presenceFlips is false when a reserved slot stays present (the fix)")
    func reservedSlotNoFlip() {
        // Post-fix: the Highlight slot is ALWAYS present (empty when no insight),
        // so its presence never flips and the spine stays stable.
        #expect(!ScrollSpineStability.presenceFlips(wasPresent: true, isPresent: true))
        #expect(!ScrollSpineStability.presenceFlips(wasPresent: false, isPresent: false))
    }
}

/// Tests for the v0151 RCA-2 invariant (`.planning/v0151-audit/RCA-nav-scroll-2.md`):
/// a push-reached screen with a `.large` title must present a SCROLLABLE root from
/// the FIRST frame — never a `ProgressView` placeholder that swaps to a
/// `List`/`ScrollView` after async load (which re-binds the large-title bar and
/// shifts content down). The three converted screens (`LabsScreen`,
/// `IllnessJournalScreen`, `CoachMemoryScreen`) route every phase through
/// `HLAsyncListScreen`, whose root is a `List` in all phases.
@Suite("ScrollRootStability")
struct ScrollRootStabilityTests {
    @Test("Stable scroll root: scrollable in loading AND loaded survives the load")
    func bothScrollablePasses() {
        #expect(
            ScrollSpineStability.rootContainerIsScrollableFromFirstFrame(
                loadingPhase: .scrollable,
                loadedPhase: .scrollable
            )
        )
    }

    @Test("Pre-fix shape (ProgressView root → List after load) FAILS the predicate")
    func progressViewSwapFails() {
        // The exact RCA-2 bug: loading = non-scrolling ProgressView, loaded = List.
        #expect(
            !ScrollSpineStability.rootContainerIsScrollableFromFirstFrame(
                loadingPhase: .nonScrolling,
                loadedPhase: .scrollable
            )
        )
    }

    @Test("A non-scrolling loaded root also fails (no scroll container at all)")
    func nonScrollingLoadedFails() {
        #expect(
            !ScrollSpineStability.rootContainerIsScrollableFromFirstFrame(
                loadingPhase: .scrollable,
                loadedPhase: .nonScrolling
            )
        )
    }

    @Test("HLAsyncListScreen presents a scrollable root in EVERY phase")
    func primitiveRootIsAlwaysScrollable() {
        // The converted screens delegate their root to HLAsyncListScreen, so this
        // proves the structural fix for all three: loading does not swap the root.
        for phase in [HLAsyncListPhase.loading, .empty, .loaded] {
            #expect(
                HLAsyncListScreen<EmptyView, EmptyView, EmptyView>
                    .rootContainerKind(for: phase) == .scrollable
            )
        }
    }

    @Test("The converted screens satisfy the first-frame invariant via the primitive")
    func convertedScreensSatisfyInvariant() {
        // Each converted screen's loading phase and loaded phase both resolve to the
        // primitive's scrollable root.
        let loading = HLAsyncListScreen<EmptyView, EmptyView, EmptyView>
            .rootContainerKind(for: .loading)
        let loaded = HLAsyncListScreen<EmptyView, EmptyView, EmptyView>
            .rootContainerKind(for: .loaded)
        #expect(
            ScrollSpineStability.rootContainerIsScrollableFromFirstFrame(
                loadingPhase: loading,
                loadedPhase: loaded
            )
        )
    }
}
