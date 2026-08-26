import Foundation
import SwiftUI

/// Centralised, single-source-of-truth metadata for every `MetricKind`.
///
/// Replaces the duplicated `switch kind { … }` blocks that were scattered
/// across `DashboardScreen.swift` (icon, tint, formatter, drill-down) and
/// downstream callers. Add a kind to the enum → add one descriptor here →
/// every tile, drill-down, settings row picks it up automatically.
///
/// Cited contract anchors:
/// - Server titles + units: `src/app/api/dashboard/summary/route.ts:49-73`
/// - HK identifier mapping: `src/lib/measurements/apple-health-mapping.ts`
/// - Drill-down endpoint mapping: `MetricInsightsRepository.endpoint(for:)`
///
/// Localized title strings live in `Localizable.xcstrings`; the descriptor
/// returns the **localization key**, callers should resolve via
/// `String(localized: descriptor.titleKey)`.
public struct MetricKindDescriptor: Sendable {
    public let kind: MetricKind
    /// Apple SF Symbol identifier — used by every tile + list row.
    public let sfSymbol: String
    /// Theme-2.0 (T2-2): collapsed to `HLSurface.secondary` for every kind —
    /// the previous per-category Dracula tint (red Vitals / orange Activity /
    /// cyan Body / purple Sleep / grey Other) is gone. Icon foreground +
    /// sparkline now resolve to `HLText.*` tokens directly in the tile (chrome
    /// stays mono); chart-series resolve to `HLChartTints.series` (single
    /// accent). The field is retained on the struct for ABI stability + the
    /// `HLText.tertiary` fallback descriptor; production call-sites
    /// should NOT read `descriptor.tint` for chrome. T2-5 will delete the
    /// field once every remaining reader is audited.
    public let tint: Color
    /// Localized display title (DE primary, EN parity). Compact form for tiles.
    public let title: LocalizedStringResource
    /// Compact title for narrow tiles (defaults to `title` if not specified).
    public let titleCompact: LocalizedStringResource
    /// User-facing unit (e.g. "kg", "bpm", "mg/dL"). Localized.
    public let unitLabel: LocalizedStringResource
    /// Polarity of the trend arrow w.r.t. user-desired direction. Drives the
    /// trend-chip colour: a "higherIsBetter" metric with `.up` shows green.
    public let trendPolarity: TrendPolarity
    /// Tile render style. Most are `.scalar`; BP is `.composite`; sleep gets
    /// a stages indicator; audio exposure is the dual-row composite.
    public let renderHint: TileRenderHint
    /// True when tapping the tile pushes a chart-detail screen. Always true
    /// for kinds the server emits today; reserved for future kinds that
    /// would have no detail backing.
    public let supportsDrillDown: Bool
    /// Display formatter strategy — produces the primary value string.
    public let formatStyle: FormatStyle
    /// Localized empty-state copy (CTA / explainer text).
    public let emptyStateCopy: LocalizedStringResource
    /// Optional secondary-line affordance ("Bestwert: 72", "Letzte Nacht").
    public let secondaryHint: LocalizedStringResource?

    public init(
        kind: MetricKind,
        sfSymbol: String,
        tint: Color,
        title: LocalizedStringResource,
        titleCompact: LocalizedStringResource? = nil,
        unitLabel: LocalizedStringResource,
        trendPolarity: TrendPolarity,
        renderHint: TileRenderHint,
        supportsDrillDown: Bool,
        formatStyle: FormatStyle,
        emptyStateCopy: LocalizedStringResource,
        secondaryHint: LocalizedStringResource? = nil
    ) {
        self.kind = kind
        self.sfSymbol = sfSymbol
        self.tint = tint
        self.title = title
        self.titleCompact = titleCompact ?? title
        self.unitLabel = unitLabel
        self.trendPolarity = trendPolarity
        self.renderHint = renderHint
        self.supportsDrillDown = supportsDrillDown
        self.formatStyle = formatStyle
        self.emptyStateCopy = emptyStateCopy
        self.secondaryHint = secondaryHint
    }

    public enum TrendPolarity: Sendable, Hashable {
        /// Increasing value is desirable (steps, HRV, time-in-daylight).
        case higherIsBetter
        /// Decreasing value is desirable (weight, resting-HR, audio-exposure).
        case lowerIsBetter
        /// Either direction is neutral — show the trend symbol without a
        /// status colour (glucose, sleep duration mostly).
        case neutral
    }

    public enum TileRenderHint: Sendable, Hashable {
        /// One primary number + unit + sparkline. Default for almost every kind.
        case scalar
        /// Two coupled values (BP `sys/dia`). Primary slot renders both.
        case dualValue
        /// Sleep — duration formatted as `H'h' m'm'` plus optional stages strip.
        case sleepDuration
        /// Audio Exposure composite — env + headphones as paired bars. Reserved
        /// for the future composite tile (server emit pending).
        case audioExposure
    }

    public enum FormatStyle: Sendable, Hashable {
        /// `latestValue` rendered with 0 fractional digits (steps, pulse, dBA).
        case integer
        /// 1 fractional digit (weight, body-fat).
        case decimal1
        /// 2 fractional digits (VO2 Max, HRV).
        case decimal2
        /// BP composite `sys/dia` (integers).
        case bloodPressureCompound
        /// Duration formatter (hours + minutes; sleep tile).
        case durationHM
        /// Grouped integer with thousands separator (steps).
        case groupedInteger
        /// W-B189 (#23) — SIGNED 1-fraction-digit value with an explicit `+`/`−`
        /// prefix, used by `bodyTemperatureDeviation` (Oura's signed °C offset
        /// from baseline). The value is a DEVIATION, not an absolute reading, so
        /// it MUST carry its sign: `+0.3` shows `+0.3`, `−0.2` shows `−0.2`,
        /// `0.0` shows `0.0`. Never display it as an absolute temperature
        /// (`37.x`). Formatted via `MetricKindDescriptor.formatSignedDecimal1`.
        case signedDecimal1
    }
}
