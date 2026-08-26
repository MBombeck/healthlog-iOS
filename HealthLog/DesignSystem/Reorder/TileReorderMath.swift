import Foundation

/// v0.8.0 W10 → v0.8.4 W-REORDER — PURE order + span-packing math for the
/// reorderable tile grid.
///
/// The hand-rolled drag hit-test (`targetIndex` / `hoverTarget` / the
/// dead-band + debounce hysteresis) was retired in v0.8.4 when the grid moved
/// to a UICollectionView interactive-movement engine (`ReorderableTileCollection`)
/// — the live geometry + drop snapping now belong to the compositional layout,
/// not to a cached frame dictionary, which is exactly what RX2 identified as
/// the structural cause of the wrong-drop bug.
///
/// What remains is genuinely pure + still in use:
///  - `move` / `moveBackward` / `moveForward` — the index reorder the engine's
///    `didReorder` snapshot commit and the VoiceOver "Move up/down" actions run.
///  - `TileSpan` + `packFlow` + `rowCount` — the span-aware row packing the
///    compositional layout's group provider consumes (full = whole row, two
///    halves side-by-side) and that the layout tests verify.
///
/// Keeping the arithmetic in a `nonisolated` enum means slot boundaries, the
/// trailing wrap, and the half/full packing stay unit-testable without a
/// running view.
public enum TileReorderMath {
    /// Reorders `ids` by removing the element at `from` and inserting it at
    /// `to`. Both indices are clamped to the valid range; a no-op (`from ==
    /// to`) returns the input unchanged. Pure — drives the optimistic order
    /// the store persists on drop + the VoiceOver move actions.
    public static func move(_ ids: [String], from: Int, to: Int) -> [String] {
        guard !ids.isEmpty else { return ids }
        let src = clamp(from, lower: 0, upper: ids.count - 1)
        let dst = clamp(to, lower: 0, upper: ids.count - 1)
        guard src != dst else { return ids }
        var out = ids
        let element = out.remove(at: src)
        out.insert(element, at: dst)
        return out
    }

    /// Swaps the element at `index` one slot toward the front (VoiceOver
    /// "Move up"). Clamped — returns the input unchanged when already first.
    public static func moveBackward(_ ids: [String], index: Int) -> [String] {
        guard index > 0, index < ids.count else { return ids }
        return move(ids, from: index, to: index - 1)
    }

    /// Swaps the element at `index` one slot toward the end (VoiceOver "Move
    /// down"). Clamped — returns the input unchanged when already last.
    public static func moveForward(_ ids: [String], index: Int) -> [String] {
        guard index >= 0, index < ids.count - 1 else { return ids }
        return move(ids, from: index, to: index + 1)
    }

    private static func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}

// MARK: - Span-aware flow packing (v0.8.1 WB)

/// The visual width a tile occupies in the span-aware grid. `full` consumes
/// the whole row (the grid's full column count); `half` consumes one column.
/// Mirrors the iOS Home Screen widget sizes (small / medium) the operator's
/// rearrange feature clones — and lets full- and half-width tiles share ONE
/// reorderable flow, so every tile (not just a uniform subset) drags.
public enum TileSpan: Sendable, Equatable {
    case full
    case half

    /// Columns this span consumes in an `columns`-wide grid. `full` always
    /// spans the entire row; `half` spans a single column. Clamped to the
    /// grid width so a `full` tile in a 1-column grid still reports 1.
    public func columnSpan(in columns: Int) -> Int {
        switch self {
        case .full: max(1, columns)
        case .half: 1
        }
    }
}

public extension TileReorderMath {
    /// One placed item in the flow: the slot's column count plus its row +
    /// leading-column position (both 0-based). Pure value so the L→R packing
    /// can be unit-tested without a running `Layout`.
    struct FlowSlot: Sendable, Equatable {
        public let row: Int
        public let column: Int
        public let columnSpan: Int

        public init(row: Int, column: Int, columnSpan: Int) {
            self.row = row
            self.column = column
            self.columnSpan = columnSpan
        }
    }

    /// Greedy left-to-right packing of `spans` into a grid `columns` wide,
    /// honouring per-item column span. A `full` item that does not fit the
    /// remaining row width starts a fresh row (Home-Screen re-packing). The
    /// result has one `FlowSlot` per input item, in input order — so the slot
    /// at index *i* describes where item *i* lands, independent of the array's
    /// reorder identity. Drives the compositional layout's per-row group
    /// provider (`ReorderableTileCollection`) and is the unit the all-sizes
    /// reorder layout is verified against.
    static func packFlow(spans: [TileSpan], columns: Int) -> [FlowSlot] {
        let cols = max(1, columns)
        var slots: [FlowSlot] = []
        slots.reserveCapacity(spans.count)
        var row = 0
        var cursor = 0 // next free leading column in the current row
        for span in spans {
            let width = span.columnSpan(in: cols)
            if cursor + width > cols, cursor > 0 {
                // Doesn't fit the rest of this row → wrap to a new row.
                row += 1
                cursor = 0
            }
            slots.append(FlowSlot(row: row, column: cursor, columnSpan: width))
            cursor += width
            if cursor >= cols {
                row += 1
                cursor = 0
            }
        }
        return slots
    }

    /// Number of rows the packing produces — `0` for an empty input.
    static func rowCount(spans: [TileSpan], columns: Int) -> Int {
        guard let last = packFlow(spans: spans, columns: columns).last else { return 0 }
        // The last slot's row index is 0-based; its row count is +1.
        return last.row + 1
    }

    /// Per-row item COUNTS for the packed `spans` — `[2, 1]` means "two halves
    /// share row 0, one full fills row 1". The `ReorderableTileCollection`
    /// compositional layout consumes this to build one horizontal group per
    /// row (count 1 → full-width item, count 2 → two half-width items + gap).
    /// Pure so the span → row-group mapping is unit-testable without UIKit.
    static func rowItemCounts(spans: [TileSpan], columns: Int) -> [Int] {
        let slots = packFlow(spans: spans, columns: columns)
        guard let lastRow = slots.last?.row else { return [] }
        var counts = Array(repeating: 0, count: lastRow + 1)
        for slot in slots {
            counts[slot.row] += 1
        }
        return counts
    }
}
