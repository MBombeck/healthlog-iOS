import Foundation

/// Pure policy behind the v0150 nav-scroll fixes (Illness journal drift + Home
/// return-jump). RCA: `.planning/v0150-felt-parity/RCA-nav-scroll.md`.
///
/// **The rule.** A scroll container preserves its restored content offset across
/// an async data refresh **iff its node spine is stable** — i.e. the count and
/// order of its top-level child nodes (sections / cards) do not change; only leaf
/// *content* may change. When a refresh INSERTS or REMOVES a node above the user's
/// scroll position (e.g. a section appears because `activeEpisodes` flipped
/// non-empty, or a `HighlightInsightCard` hydrates and inserts above the grid),
/// SwiftUI keeps the content origin pinned, so the visible frame shifts — read as
/// the operator's "rutscht runter" / "springt hoch".
///
/// The decidable consequence, encoded here and unit-tested, is the design contract
/// the SwiftUI views are built to satisfy: **build a stable spine of always-present
/// nodes and hide their rows when empty, rather than conditionally inserting whole
/// nodes.** `isStable(before:after:)` returns whether two spine snapshots would let
/// the scroll offset survive; the views are structured so this is always `true`
/// across a reload.
public enum ScrollSpineStability {
    /// `true` when the two spines have the SAME ordered node identities — a reload
    /// that satisfies this leaves the restored scroll offset valid. Differing
    /// count or order means a node was inserted/removed/reordered (offset
    /// perturbed).
    public static func isStable(before: [String], after: [String]) -> Bool {
        before == after
    }

    /// Convenience: would adding/removing the `optional` node (depending on a
    /// predicate) DESTABILISE the spine? `true` when the node's presence flips,
    /// which is exactly the insert/remove the views must avoid. Use to reason
    /// about a single conditional node (e.g. a Highlight card or a journal
    /// section) without enumerating the whole spine.
    public static func presenceFlips(wasPresent: Bool, isPresent: Bool) -> Bool {
        wasPresent != isPresent
    }

    // MARK: - RCA-2: stable scroll ROOT from the first frame

    /// The kind of root container a screen renders in a given phase. The RCA-2 bug
    /// (`.planning/v0151-audit/RCA-nav-scroll-2.md`) is a screen whose ROOT swaps
    /// from a non-scrolling `ProgressView` placeholder to a scrollable
    /// `List`/`ScrollView` AFTER an async load — under a `.large` title that re-binds
    /// its collapse + content-insets to the late-appearing scroll view, shifting the
    /// content down.
    public enum RootContainerKind: Equatable {
        /// A scrollable root (`List` / `ScrollView`). Binds the large-title bar.
        case scrollable
        /// A non-scrolling placeholder root (`ProgressView`, a centered card). Does
        /// NOT bind the large-title bar — if this is the first-frame root and the
        /// loaded root is `.scrollable`, the bar re-binds post-load (the bug).
        case nonScrolling
    }

    /// `true` iff the screen presents a SCROLLABLE root in BOTH the loading phase
    /// and the loaded phase — i.e. the scroll container is present from the first
    /// frame and is never a `ProgressView` that later swaps to a `List`/`ScrollView`.
    ///
    /// This is the decidable contract the RCA-2 fix is built to satisfy: the
    /// converted screens (`LabsScreen`, `IllnessJournalScreen`, `CoachMemoryScreen`)
    /// render the `List` root in every phase (skeleton rows while loading), so the
    /// large-title bar binds once and never re-resolves the offset after load.
    ///
    /// A screen that returns `.nonScrolling` for its loading phase and `.scrollable`
    /// for its loaded phase fails this predicate — exactly the pre-fix shape.
    public static func rootContainerIsScrollableFromFirstFrame(
        loadingPhase: RootContainerKind,
        loadedPhase: RootContainerKind
    ) -> Bool {
        loadingPhase == .scrollable && loadedPhase == .scrollable
    }
}
