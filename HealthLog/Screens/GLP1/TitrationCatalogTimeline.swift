import Foundation

/// Pure resolver for the **catalog titration ladder** shown under a GLP-1
/// medication.
///
/// 1.0.3 (App Review 1.4.2 — ruling R10): this used to be a forward
/// "you-are-here" plan that drew the rungs *above* the user's dose as the
/// upcoming escalation. Guideline 1.4.2 reserves drug-dosage calculators for
/// manufacturers, hospitals, universities, insurers and pharmacies, and a rung
/// list projected forward from the user's own dose is exactly that. The
/// forward projection is gone — no upcoming rungs, no "next step", no marker
/// beyond the current dose.
///
/// What remains is backward-looking and informational: the label's standard
/// schedule (`GLP1DrugCatalog.titrationStepsMg`, EMA EPAR §4.2) truncated at
/// the rung the user has actually reached, so the section reads as "this is
/// the schedule you have moved through", never "this is where you go next".
///
/// Self-suppressing: a non-titrating med (no catalog drug, < 2 ladder rungs)
/// or an unknown / below-the-first-rung dose yields an empty step list so the
/// view can omit itself entirely.
public enum TitrationCatalogTimeline {
    /// One rung of the standard ladder, up to and including the current dose.
    public struct Step: Equatable, Sendable, Identifiable {
        /// Stable id = the ladder index (the ladder is fixed per drug).
        public let id: Int
        public let doseMg: Double
        /// The rung at (or nearest at-or-below) the user's current dose — the
        /// last rung of the resolved list. Every other rung is one the user
        /// has already moved through.
        public let isCurrent: Bool

        public init(id: Int, doseMg: Double, isCurrent: Bool) {
            self.id = id
            self.doseMg = doseMg
            self.isCurrent = isCurrent
        }
    }

    /// Resolve the catalog ladder against the current dose, truncated at that
    /// dose.
    ///
    /// - Parameters:
    ///   - ladderMg: the drug's `titrationStepsMg` (strictly ascending mg).
    ///   - currentDoseMg: the user's current dose in mg, or `nil` when
    ///     unknown.
    /// - Returns: one `Step` per ladder rung **at or below** the current dose.
    ///   The last element is the current rung: the highest ladder value that
    ///   is `<= currentDoseMg` (so an off-ladder in-between dose, e.g. 6 mg on
    ///   a 5 / 7.5 ladder, ends the list at 5 mg). Rungs above the current
    ///   dose are never returned.
    ///
    /// Returns an **empty array** — the self-suppress signal — when the ladder
    /// has fewer than two rungs (a lone rung is just the current dose; there
    /// is no schedule to read), or when no rung is at-or-below the current
    /// dose (unknown dose, or a dose below the first rung).
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
        guard currentIndex >= 0 else { return [] }

        return rungs.prefix(currentIndex + 1).enumerated().map { i, mg in
            Step(id: i, doseMg: mg, isCurrent: i == currentIndex)
        }
    }

    /// Float tolerance for the at-or-below comparison so a dose stored as
    /// `5.000000001` still matches the `5` rung.
    private static let epsilon = 1e-6
}
