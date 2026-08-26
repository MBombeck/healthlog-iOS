import Foundation

/// **Cycle prediction maturity gate (C1 — trust + §1.4.1 / EU-MDR).**
///
/// A render-time predicate that decides whether the app may paint a *concrete*
/// fertile-window / ovulation prediction. From ≤ 2 confirmed cycles the server
/// (and the offline ``CyclePredictionEngine``) still emit a fertile window +
/// ovulation date derived from a 28/14 *population prior* at low confidence — a
/// guess, not the user's data. Painting that guess as fact is a trust hazard and
/// a fertility-claim compliance risk (the same doctrine behind the b182
/// fertility disclaimer). Until enough cycles are observed we suppress the
/// fertile/ovulation markers on every surface; the next-period estimate, the
/// "still learning" caption and the disclaimer stay (those are honest).
///
/// This is **not** an availability gate — that is ``CycleGate`` /
/// `CycleGateResolver` (gender / feature-flag). This is purely a maturity
/// predicate keyed off the observed-cycle count, kept pure + `Sendable` so it is
/// unit-testable without a SwiftUI host and shared by the calendar, the
/// prediction summary and the hero ring.
enum CycleMaturity {
    /// Minimum confirmed cycles before fertile-window / ovulation predictions are
    /// shown as concrete. Matches the server's `cyclesObserved < 3`
    /// "still learning" rule and the `stillLearning` flag (ACOG / Wilcox).
    static let minCyclesForFertility = 3

    /// Whether concrete fertile-window + ovulation predictions may be painted.
    ///
    /// - Parameters:
    ///   - cyclesObserved: confirmed (non-predicted) cycle count available at the
    ///     call site — prefer `calendar.profile.cyclesObserved`, then
    ///     `prediction.cyclesObserved`, then the confirmed-cycle count.
    ///   - stillLearning: the prediction's own `stillLearning` flag (defaults
    ///     `true` when the server/engine omits it). Treated as authoritative when
    ///     `true` even if the count would otherwise pass, so an older server that
    ///     only sends the flag still suppresses correctly.
    static func showsFertility(cyclesObserved: Int, stillLearning: Bool? = nil) -> Bool {
        if stillLearning == true { return false }
        return cyclesObserved >= minCyclesForFertility
    }

    /// Inverse convenience for call sites that thread a "suppress" boolean.
    static func suppressFertility(cyclesObserved: Int, stillLearning: Bool? = nil) -> Bool {
        !showsFertility(cyclesObserved: cyclesObserved, stillLearning: stillLearning)
    }
}
