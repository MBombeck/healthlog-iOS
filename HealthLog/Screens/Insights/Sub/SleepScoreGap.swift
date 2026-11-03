import Foundation

/// **#145 (server v1.43.6/7) — why the sleep score withholds a sub-score.**
///
/// `SleepScoreValue.subScores[].gap` (`docs/api/openapi.yaml` at v1.43.10)
/// sits only on a null `consistency` / `timing`:
///
/// - `few_nights`: fewer than `rhythmMinNights` nights in the window have a
///   main sleep on the clock; the count so far is `rhythmNights`.
/// - `no_main_sleep`: the latest day had only a daytime nap.
///
/// The score sheet used to drop such a row without a word. Now the row stays
/// and says why in one short line, with the server's numbers as sent. An
/// unknown token keeps the old silent gap rather than inventing a reason.
enum SleepScoreGap: String {
    case fewNights = "few_nights"
    case noMainSleep = "no_main_sleep"

    /// The line the sub-score's row shows in place of its weight.
    func reasonLine(nights: Int?, minimum: Int?) -> String {
        switch self {
        case .fewNights:
            guard let nights, let minimum, nights >= 0, minimum > nights else {
                return String(localized: "sleep.score.gap.fewNightsPlain")
            }
            return String(localized: "sleep.score.gap.fewNights \(minimum) \(nights)")
        case .noMainSleep:
            return String(localized: "sleep.score.gap.noMainSleep")
        }
    }
}
