import Foundation

/// How the system is drawing a widget, reduced to what the layout decides on.
///
/// `accented` covers the tinted and the clear Home Screen and most watch faces:
/// the system drops every hue, paints the accent group in the tint and the rest
/// in one primary tone. `vibrant` is the Lock Screen: luminance only.
public enum WidgetTint: Sendable, Equatable {
    case fullColor
    case accented
    case vibrant

    /// Status colours survive only in full colour. Anywhere else a state that a
    /// colour carries needs a symbol, a shape, or a word as well.
    public var keepsStatusColor: Bool {
        self == .fullColor
    }
}

/// The visual layers a widget is built from.
public enum WidgetLayer: String, CaseIterable, Sendable {
    /// The filled part of a ring or gauge.
    case ringProgress
    /// The hairline track behind a ring.
    case ringTrack
    /// A glyph that states something (taken, stale, mood face, score band).
    case statusSymbol
    /// The number or name the widget exists to show.
    case primaryValue
    /// The small symbol in front of the widget title.
    case headerIcon
    /// The widget title.
    case headerTitle
    /// Captions, times, units.
    case secondaryText
    /// The trend line of a measurement widget.
    case trendLine
    /// A tappable control drawn by the widget.
    case actionButton
}

/// Every widget and complication the app ships.
public enum WidgetSurface: String, CaseIterable, Sendable {
    case nextDose
    case compliance
    case mood
    case healthScore
    case latestMeasurement
    case watchNextDose
    case watchHealthScore
    case watchLatestMeasurement
}

/// Which layers join the accent group in tinted and clear rendering.
///
/// One accent group per widget keeps the tinted look calm: the ring and the
/// status glyph take the tint, the value stays in the primary tone so it keeps
/// the highest contrast. Tracks and captions never join, or they would compete
/// with what they frame.
public enum WidgetTintPolicy {
    public static func accentLayers(for surface: WidgetSurface) -> Set<WidgetLayer> {
        switch surface {
        case .nextDose: [.headerIcon, .statusSymbol, .actionButton]
        case .compliance: [.headerIcon, .ringProgress, .statusSymbol]
        case .mood: [.headerIcon, .statusSymbol, .actionButton]
        case .healthScore: [.headerIcon, .ringProgress, .statusSymbol]
        case .latestMeasurement: [.headerIcon, .primaryValue, .trendLine]
        case .watchNextDose: [.ringProgress, .statusSymbol]
        case .watchHealthScore: [.ringProgress, .statusSymbol]
        case .watchLatestMeasurement: [.statusSymbol, .primaryValue]
        }
    }

    public static func isAccented(_ layer: WidgetLayer, in surface: WidgetSurface) -> Bool {
        accentLayers(for: surface).contains(layer)
    }

    /// The score band as a shape, for renderings that drop the band colour.
    /// `nil` band (the server made no verdict) keeps the neutral heart.
    public static func healthScoreBandSymbol(band: String?) -> String {
        switch band {
        case "green": "checkmark.circle"
        case "yellow": "minus.circle"
        case "red": "exclamationmark.circle"
        default: "heart.fill"
        }
    }
}
