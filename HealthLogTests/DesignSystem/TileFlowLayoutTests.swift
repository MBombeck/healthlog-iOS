import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.8.1 WB → v0.8.4 W-REORDER — span-aware flow packing for the all-sizes
/// reorder grid. Pure row/column placement math (full = the whole row, half =
/// one column) that the `ReorderableTileCollection` compositional layout's
/// per-row group provider consumes (via `packFlow` + `rowItemCounts`). The
/// suite name is retained for history; the SwiftUI `TileFlowLayout` it once
/// drove was replaced by the UICollectionView engine.
@Suite("TileFlowLayout — span-aware flow packing")
struct TileFlowLayoutTests {
    // MARK: - Span → column count

    @Test("full spans the whole row, half spans one column")
    func columnSpanPerSize() {
        #expect(TileSpan.full.columnSpan(in: 2) == 2)
        #expect(TileSpan.half.columnSpan(in: 2) == 1)
        // full clamps to the grid width even in a 1-column grid.
        #expect(TileSpan.full.columnSpan(in: 1) == 1)
    }

    // MARK: - Uniform full-width (Dashboard 2-col parity)

    @Test("all-full items pack two per row in a 2-column grid")
    func allFullTwoPerRow() {
        let slots = TileReorderMath.packFlow(spans: [.full, .full, .full], columns: 2)
        // A full tile consumes the whole row → one per row.
        #expect(slots.map(\.row) == [0, 1, 2])
        #expect(slots.allSatisfy { $0.column == 0 })
        #expect(slots.allSatisfy { $0.columnSpan == 2 })
        #expect(TileReorderMath.rowCount(spans: [.full, .full, .full], columns: 2) == 3)
    }

    // MARK: - All-half (two per row)

    @Test("all-half items pack two per row in a 2-column grid")
    func allHalfTwoPerRow() {
        let slots = TileReorderMath.packFlow(spans: [.half, .half, .half, .half], columns: 2)
        #expect(slots.map(\.row) == [0, 0, 1, 1])
        #expect(slots.map(\.column) == [0, 1, 0, 1])
        #expect(TileReorderMath.rowCount(spans: [.half, .half, .half, .half], columns: 2) == 2)
    }

    // MARK: - Mixed sizes — the core all-sizes case

    @Test("a half pair followed by a full packs onto separate rows")
    func mixedHalfPairThenFull() {
        // [half, half, full] → row0: two halves side-by-side; row1: full.
        let slots = TileReorderMath.packFlow(spans: [.half, .half, .full], columns: 2)
        #expect(slots[0] == TileReorderMath.FlowSlot(row: 0, column: 0, columnSpan: 1))
        #expect(slots[1] == TileReorderMath.FlowSlot(row: 0, column: 1, columnSpan: 1))
        #expect(slots[2] == TileReorderMath.FlowSlot(row: 1, column: 0, columnSpan: 2))
    }

    @Test("a full after a lone half wraps the full to a fresh row")
    func fullAfterLoneHalfWraps() {
        // [half, full] → half fills col0 of row0; full can't fit the rest of
        // row0 (needs 2 cols, only 1 left) → wraps to row1.
        let slots = TileReorderMath.packFlow(spans: [.half, .full], columns: 2)
        #expect(slots[0] == TileReorderMath.FlowSlot(row: 0, column: 0, columnSpan: 1))
        #expect(slots[1] == TileReorderMath.FlowSlot(row: 1, column: 0, columnSpan: 2))
        #expect(TileReorderMath.rowCount(spans: [.half, .full], columns: 2) == 2)
    }

    @Test("full, half, half packs full on its own row then the halves pair up")
    func fullThenHalfPair() {
        let slots = TileReorderMath.packFlow(spans: [.full, .half, .half], columns: 2)
        #expect(slots[0] == TileReorderMath.FlowSlot(row: 0, column: 0, columnSpan: 2))
        #expect(slots[1] == TileReorderMath.FlowSlot(row: 1, column: 0, columnSpan: 1))
        #expect(slots[2] == TileReorderMath.FlowSlot(row: 1, column: 1, columnSpan: 1))
    }

    // MARK: - Reflow indices after a reorder (all-sizes)

    @Test("reordering a half across a full re-packs the slot positions")
    func reflowAfterReorder() {
        // Start [full, half, half] → drag the trailing half to the front.
        let start: [TileSpan] = [.full, .half, .half]
        let reorderedTypes = TileReorderMath.move(["F", "A", "B"], from: 2, to: 0)
        #expect(reorderedTypes == ["B", "F", "A"])
        // New span order corresponding to [B(half), F(full), A(half)].
        let after = TileReorderMath.packFlow(spans: [.half, .full, .half], columns: 2)
        // B is a lone half on row0; F (full) wraps to row1; A wraps to row2.
        #expect(after.map(\.row) == [0, 1, 2])
        _ = start
    }

    // MARK: - Edges

    @Test("empty input yields no slots and zero rows")
    func emptyInput() {
        #expect(TileReorderMath.packFlow(spans: [], columns: 2).isEmpty)
        #expect(TileReorderMath.rowCount(spans: [], columns: 2) == 0)
    }

    @Test("a single-column grid stacks every item, full or half, one per row")
    func singleColumnStacks() {
        let slots = TileReorderMath.packFlow(spans: [.full, .half, .full], columns: 1)
        #expect(slots.map(\.row) == [0, 1, 2])
        #expect(slots.allSatisfy { $0.column == 0 })
    }

    // MARK: - W-REORDER — row-item-counts (compositional layout group mapping)

    // The `ReorderableTileCollection` compositional layout builds one
    // horizontal group per packed row: count 1 → a full-width item, count 2 →
    // two half-width items. `rowItemCounts` is the pure span→group mapping the
    // engine consumes; these guard that a full is its own row and a mood pair
    // collapses to a single 2-item row.

    @Test("all-full spans map to one full-width item per row")
    func rowItemCountsAllFull() {
        #expect(TileReorderMath.rowItemCounts(spans: [.full, .full, .full], columns: 2) == [1, 1, 1])
    }

    @Test("a mood-style mixed layout maps to the matching per-row counts")
    func rowItemCountsMixed() {
        // [full, full, half, half, full, full] → rows: 1,1,2(pair),1,1.
        let spans: [TileSpan] = [.full, .full, .half, .half, .full, .full]
        #expect(TileReorderMath.rowItemCounts(spans: spans, columns: 2) == [1, 1, 2, 1, 1])
    }

    @Test("a lone half before a full puts the half alone then the full alone")
    func rowItemCountsLoneHalfThenFull() {
        // [half, full] → half can't pair (full needs the whole next row) → 1,1.
        #expect(TileReorderMath.rowItemCounts(spans: [.half, .full], columns: 2) == [1, 1])
    }

    @Test("two halves followed by two halves map to two paired rows")
    func rowItemCountsHalfPairs() {
        #expect(TileReorderMath.rowItemCounts(spans: [.half, .half, .half, .half], columns: 2) == [2, 2])
    }

    @Test("empty spans map to no rows")
    func rowItemCountsEmpty() {
        #expect(TileReorderMath.rowItemCounts(spans: [], columns: 2).isEmpty)
    }

    // MARK: - W-REORDER — order commit from a reordered id snapshot

    /// The engine commits a drag by reading `transaction.finalSnapshot`'s id
    /// order and forwarding it to the store. This models that hand-off: moving
    /// a mood half across a full produces the exact id order the store persists,
    /// and re-packing it keeps the surviving mood half paired only if BOTH
    /// halves stay adjacent (the host keeps the pair atomic upstream).
    @Test("reordering a half across a full yields the snapshot id order the store persists")
    func orderCommitFromSnapshot() {
        // Start: weight(full), moodA(half), moodB(half), steps(full).
        let ids = ["WEIGHT", "MOOD_SCORE", "MOOD_STABILITY", "ACTIVITY_STEPS"]
        // Drag steps (index 3) to the front (index 0) — what `finalSnapshot`
        // would report after the interactive move.
        let committed = TileReorderMath.move(ids, from: 3, to: 0)
        #expect(committed == ["ACTIVITY_STEPS", "WEIGHT", "MOOD_SCORE", "MOOD_STABILITY"])
        // The mood pair stays adjacent → still packs as a side-by-side row.
        let halves: Set = ["MOOD_SCORE", "MOOD_STABILITY"]
        let spans: [TileSpan] = committed.map { halves.contains($0) ? .half : .full }
        #expect(TileReorderMath.rowItemCounts(spans: spans, columns: 2) == [1, 1, 2])
    }
}
