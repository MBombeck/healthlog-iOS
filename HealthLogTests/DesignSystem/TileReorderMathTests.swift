import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.8.0 W10 → v0.8.4 W-REORDER — pure ORDER math for the reorderable tile
/// grid. The drag hit-test (`targetIndex` / `hoverTarget` / dead-band +
/// debounce hysteresis) was deleted when the grid adopted the UICollectionView
/// interactive-movement engine — the layout owns the live drop geometry now,
/// so there is nothing left to unit-test there. What remains is the index
/// reorder that the engine's `didReorder` snapshot-commit and the VoiceOver
/// "Move up/down" actions run.
@Suite("TileReorderMath — order + move math")
struct TileReorderMathTests {
    @Test("move removes and inserts at the target slot")
    func moveReorders() {
        #expect(TileReorderMath.move(["a", "b", "c", "d"], from: 0, to: 2) == ["b", "c", "a", "d"])
        #expect(TileReorderMath.move(["a", "b", "c", "d"], from: 3, to: 0) == ["d", "a", "b", "c"])
    }

    @Test("move is a no-op when from == to")
    func moveNoOp() {
        #expect(TileReorderMath.move(["a", "b", "c"], from: 1, to: 1) == ["a", "b", "c"])
    }

    @Test("move clamps out-of-range indices instead of trapping")
    func moveClamps() {
        #expect(TileReorderMath.move(["a", "b"], from: 9, to: 0) == ["b", "a"])
        #expect(TileReorderMath.move(["a", "b"], from: 0, to: 9) == ["b", "a"])
    }

    @Test("move on an empty array returns it unchanged")
    func moveEmpty() {
        #expect(TileReorderMath.move([], from: 0, to: 1) == [])
    }

    @Test("moveBackward swaps one slot toward the front, no-op at index 0")
    func moveBackward() {
        #expect(TileReorderMath.moveBackward(["a", "b", "c"], index: 2) == ["a", "c", "b"])
        #expect(TileReorderMath.moveBackward(["a", "b", "c"], index: 0) == ["a", "b", "c"])
    }

    @Test("moveForward swaps one slot toward the end, no-op at last index")
    func moveForward() {
        #expect(TileReorderMath.moveForward(["a", "b", "c"], index: 0) == ["b", "a", "c"])
        #expect(TileReorderMath.moveForward(["a", "b", "c"], index: 2) == ["a", "b", "c"])
    }
}
