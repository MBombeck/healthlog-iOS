import Foundation

/// Pure resolver for the **catalog titration ladder** "you-are-here"
/// timeline — the iOS mirror of the web v1.18.5 titration-plan surface
/// (`src/components/medications/titration-timeline.tsx`).
///
/// Where `TitrationLadderStore.mergedTimeline` renders the user's recorded
/// dose-CHANGE history (server + local journal rows with editable dates),
/// this resolver renders the drug's *standard escalation ladder* from the
/// EMA-sourced catalog (`GLP1DrugCatalog.titrationStepsMg`, e.g. 2.5 → 5 →
/// 7.5 → 10 → 12.5 → 15 mg) and marks where the user's CURRENT dose sits on
/// it: completed steps behind, the current step highlighted, upcoming steps
/// dimmed. No dates — the ladder is the manufacturer's planned sequence, not
/// a per-user schedule (MDR boundary: informational, never autonomous
/// escalation guidance — see `GLP1DrugCatalog` GROUND RULE 9).
///
/// Self-suppressing: a non-titrating med (no catalog drug, < 2 ladder steps,
/// or no resolvable current dose) yields an empty step list so the view can
/// omit itself entirely.
public enum TitrationCatalogTimeline {
    /// One rung of the standard ladder, classified against the current dose.
    public struct Step: Equatable, Sendable, Identifiable {
        /// Stable id = the ladder index (the ladder is fixed per drug).
        public let id: Int
        public let doseMg: Double
        /// Below the current dose — already escalated past (checkmark).
        public let isPast: Bool
        /// The rung at (or nearest at-or-below) the current dose — the
        /// single "you are here" marker.
        public let isCurrent: Bool
        /// Above the current dose — planned / upcoming (dimmed, dashed).
        public var isUpcoming: Bool {
            !isPast && !isCurrent
        }

        public init(id: Int, doseMg: Double, isPast: Bool, isCurrent: Bool) {
            self.id = id
            self.doseMg = doseMg
            self.isPast = isPast
            self.isCurrent = isCurrent
        }
    }

    /// Classify the catalog ladder against the current dose.
    ///
    /// - Parameters:
    ///   - ladderMg: the drug's `titrationStepsMg` (strictly ascending mg).
    ///   - currentDoseMg: the user's current dose in mg, or `nil` when
    ///     unknown.
    /// - Returns: one `Step` per ladder rung. The **current** rung is the
    ///   highest ladder value that is `<= currentDoseMg` (so an off-ladder
    ///   in-between dose, e.g. 6 mg on a 5/7.5 ladder, marks 5 mg as current
    ///   and 7.5 mg as upcoming). When `currentDoseMg` exactly matches a
    ///   rung, that rung is current. When the current dose is below the first
    ///   rung (or unknown), no rung is current and every rung is upcoming
    ///   (the marker view renders "you are here" before the first step).
    ///
    /// Returns an **empty array** — the self-suppress signal — when the
    /// ladder has fewer than two rungs (a lone rung is just the current dose;
    /// there is no escalation plan to read).
    public static func resolve(
        ladderMg: [Double],
        currentDoseMg: Double?
    ) -> [Step] {
        // Defensive: only finite, strictly-positive rungs, ascending.
        let rungs = ladderMg
            .filter { $0.isFinite && $0 > 0 }
            .sorted()
        guard rungs.count >= 2 else { return [] }

        // The current rung is the last one at-or-below the current dose.
        var currentIndex = -1
        if let current = currentDoseMg, current.isFinite {
            for (i, rung) in rungs.enumerated() where rung <= current + Self.epsilon {
                currentIndex = i
            }
        }

        return rungs.enumerated().map { i, mg in
            Step(
                id: i,
                doseMg: mg,
                isPast: i < currentIndex,
                isCurrent: i == currentIndex
            )
        }
    }

    /// Index in the resolved step list AFTER which the "you are here" marker
    /// sits. `-1` means the marker sits before the first step (nothing in
    /// effect yet). Mirrors the web `markerAfter` placement.
    public static func markerAfterIndex(_ steps: [Step]) -> Int {
        steps.firstIndex(where: \.isCurrent) ?? -1
    }

    /// Float tolerance for the at-or-below comparison so a dose stored as
    /// `5.000000001` still matches the `5` rung.
    private static let epsilon = 1e-6
}
