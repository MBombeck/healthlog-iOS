import Foundation

/// Inverse-aware qualitative bucket for a RATED factor's read-back. Mirrors the
/// capture slider's polarity: RIGHT/high = good for non-inverse factors
/// (work / sleep_quality); for inverse factors (sadness) a HIGH raw rating is a
/// WORSE day. Derived from the catalog `inverse` flag + scale, NOT the raw
/// number, so the displayed word always matches what the slider showed.
enum MoodRatedQuality {
    case bad
    case mid
    case good

    /// Map a raw rating (within `factor`'s own scale) onto a qualitative bucket
    /// using the same 0…1 good-ward "goodness" projection the capture slider
    /// uses (``MoodRatedFactorScale/position(forRating:)`` — already
    /// inverse-aware).
    static func resolve(rating: Int, factor: MoodTagDTO) -> MoodRatedQuality {
        let goodness = MoodRatedFactorScale(factor: factor).position(forRating: rating)
        switch goodness {
        case ..<0.34: return .bad
        case ..<0.67: return .mid
        default: return .good
        }
    }

    /// Localized one-word read-out ("schlecht"/"mittel"/"gut").
    var localizedWord: String {
        switch self {
        case .bad: String(localized: "mood.ratedFactor.quality.bad")
        case .mid: String(localized: "mood.ratedFactor.quality.mid")
        case .good: String(localized: "mood.ratedFactor.quality.good")
        }
    }
}
