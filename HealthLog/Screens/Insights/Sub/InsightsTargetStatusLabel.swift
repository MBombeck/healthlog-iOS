import Foundation

/// **1.5 L10N-FINAL — the target classification in the reader's language.**
///
/// `/api/insights/targets` emits `classification.category` as a canonical
/// English token ("Optimal", "Overweight", "Hypertension Grade 1"); the web
/// resolves it through `targets.status.*` (`target-status-pill.tsx`). The app
/// showed the token as is, so a German or Dutch reader saw English. This is
/// the same table, with the server's own wording in every language. A token
/// this build does not know stays as the server sent it.
enum InsightsTargetStatusLabel {
    static let keys: [String: LocalizedStringResource] = [
        "Underweight": "targets.status.underweight",
        "Normal": "targets.status.normal",
        "Overweight": "targets.status.overweight",
        "Obesity Grade I": "targets.status.obesityGrade1",
        "Obesity Grade II": "targets.status.obesityGrade2",
        "Obesity Grade III": "targets.status.obesityGrade3",
        "Optimal": "targets.status.optimal",
        "High-normal": "targets.status.highNormal",
        "Hypertension Grade 1": "targets.status.hypertensionGrade1",
        "Hypertension Grade 2": "targets.status.hypertensionGrade2",
        "Hypertension Grade 3": "targets.status.hypertensionGrade3",
        "Below typical range": "targets.status.belowTypicalRange",
        "Elevated": "targets.status.elevated",
        "Above typical range": "targets.status.aboveTypicalRange",
        "Significantly low": "targets.status.significantlyLow",
        "Slightly low": "targets.status.slightlyLow",
        "On target": "targets.status.onTarget",
        "Slightly elevated": "targets.status.slightlyElevated",
        "Significantly elevated": "targets.status.significantlyElevated",
        "Far too short": "targets.status.farTooShort",
        "Too short": "targets.status.tooShort",
        "Slightly long": "targets.status.slightlyLong",
        "Far too long": "targets.status.farTooLong",
        "Below essential": "targets.status.belowEssential",
        "Essential": "targets.status.essential",
        "Athletic": "targets.status.athletic",
        "Fitness": "targets.status.fitness",
        "Acceptable": "targets.status.acceptable",
        "Obese": "targets.status.obese",
        "Very low": "targets.status.veryLow",
        "Low active": "targets.status.lowActive",
        "Moderately active": "targets.status.moderatelyActive",
        "Active": "targets.status.active",
        "Very active": "targets.status.veryActive",
        "Good": "targets.status.good",
        "Moderate": "targets.status.moderate",
        "Low": "targets.status.low",
        "High": "targets.status.high",
        "Very good": "targets.status.veryGood",
        "Very stable": "targets.status.veryStable",
        "Stable": "targets.status.stable",
        "Fluctuating": "targets.status.fluctuating"
    ]

    static func label(for category: String) -> String {
        guard let key = keys[category] else { return category }
        return String(localized: key)
    }
}
