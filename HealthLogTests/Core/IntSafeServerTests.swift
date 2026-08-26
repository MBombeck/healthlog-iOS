import Foundation
@testable import HealthLog
import Testing

/// Contract tests for `Int(safeServer:)` (W-CRASHGUARD, AUDIT-RELIABILITY
/// C1/C2/H1).
///
/// The stdlib `Int(_ source: Double)` initializer **traps** on a non-finite or
/// out-of-`Int.range` argument; this factory must return `nil` for exactly those
/// inputs so callers render the em-dash placeholder instead of crashing. Every
/// row here would have trapped the process under the old `Int(x.rounded())`.
@Suite("Int(safeServer:)")
struct IntSafeServerTests {
    @Test("Non-finite doubles return nil")
    func nonFiniteReturnsNil() {
        #expect(Int(safeServer: .nan) == nil)
        #expect(Int(safeServer: .infinity) == nil)
        #expect(Int(safeServer: -.infinity) == nil)
        #expect(Int(safeServer: .signalingNaN) == nil)
    }

    @Test("Finite-but-out-of-Int.range doubles return nil")
    func outOfRangeReturnsNil() {
        #expect(Int(safeServer: 1e30) == nil)
        #expect(Int(safeServer: -1e30) == nil)
        #expect(Int(safeServer: 1e308) == nil)
        #expect(Int(safeServer: -1e308) == nil)
        #expect(Int(safeServer: .greatestFiniteMagnitude) == nil)
        #expect(Int(safeServer: -.greatestFiniteMagnitude) == nil)
        // Exactly `2^63` rounds to a Double that is NOT representable as Int → nil.
        #expect(Int(safeServer: Double(Int.max)) == nil)
    }

    @Test("Normal in-range doubles round half-away-from-zero to the right Int")
    func normalRounds() {
        // `.rounded()` is `.toNearestOrAwayFromZero` (Foundation default).
        #expect(Int(safeServer: 0) == 0)
        #expect(Int(safeServer: 42) == 42)
        #expect(Int(safeServer: -7) == -7)
        #expect(Int(safeServer: 432.4999) == 432)
        #expect(Int(safeServer: 432.5) == 433) // half away from zero
        #expect(Int(safeServer: -432.5) == -433) // half away from zero
        #expect(Int(safeServer: -0.4) == 0)
        #expect(Int(safeServer: 99.9) == 100)
    }

    @Test("Boundary values just inside Int.range are accepted")
    func boundariesInRange() {
        // `Int.min` IS exactly representable as a Double (`-2^63`) → accepted.
        #expect(Int(safeServer: Double(Int.min)) == Int.min)
        // A large-but-representable in-range value.
        #expect(Int(safeServer: 9_007_199_254_740_992) == 9_007_199_254_740_992)
    }
}
