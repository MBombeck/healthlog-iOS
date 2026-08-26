import Foundation

/// v0.8.1 WB — shared title + SF Symbol lookup for an Insights catalogue tile
/// type (`InsightsTargetsResponseDTO.TargetItem.type`). Extracted from
/// `InsightsTargetTileGrid` so the in-edit-mode "+" add-tile sheet labels
/// hidden tiles identically to the grid. The returned title is the English
/// source string, which doubles as the `Localizable.xcstrings` key.
enum InsightsTileDisplay {
    static func systemImage(forCatalogueType type: String) -> String {
        switch type {
        case "WEIGHT": "scalemass"
        case "PULSE", "RESTING_HR": "heart.fill"
        case "MOOD_SCORE": "face.smiling"
        case "MOOD_STABILITY": "waveform.path.ecg"
        case "ACTIVITY_STEPS": "figure.walk"
        case "MEDICATION_COMPLIANCE": "pills.fill"
        case "SLEEP_DURATION": "moon.zzz.fill"
        case "BODY_FAT": "percent"
        default: "chart.line.uptrend.xyaxis"
        }
    }

    /// Title string. Doubles as the `LocalizedStringKey` the grid renders and
    /// the `String(localized:)` key the add-sheet resolves.
    static func title(forCatalogueType type: String) -> String {
        switch type {
        case "WEIGHT": "Weight"
        case "PULSE": "Pulse"
        case "RESTING_HR": "Resting heart rate"
        case "MOOD_SCORE": "Mood"
        case "MOOD_STABILITY": "Stability"
        case "ACTIVITY_STEPS": "Steps"
        case "MEDICATION_COMPLIANCE": "Compliance"
        case "SLEEP_DURATION": "Sleep"
        case "BODY_FAT": "Body fat"
        default: type
        }
    }

    /// Resolved (localized) title for plain-`String` consumers like the
    /// add-tile sheet. Uses the title string as the localization key.
    static func localizedTitle(forCatalogueType type: String) -> String {
        String(localized: String.LocalizationValue(title(forCatalogueType: type)))
    }
}
