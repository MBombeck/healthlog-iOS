import SwiftUI

/// Horizontal chip strip listing the provenance sources backing a visible
/// series — mirrors Apple Health's "Datenquellen" chip row above its detail
/// charts. Renders directly under the range picker so the user sees source
/// attribution before the chart, not buried at the bottom of the scroll.
///
/// **Why this exists (v0.4.1 user fix):**
/// The audit (`.planning/v041-marathon/M2-A5-trends-verlauf-sources-audit.md`
/// §5) flagged that the existing `SourcesRow` at the bottom of
/// `ChartDetailScreen` rendered a single "Alle Quellen" placeholder because
/// `ChartDetailStore.sourceBreakdown` always returned `[]`. The user reported
/// "Daten von allen Quellen aber das wird ueberhaupt nicht gezeigt".
/// `ChartDetailStore.sourceCountsForRange` now computes the breakdown
/// iOS-side from `recent(kind:)` Measurements (which DO carry `.source`),
/// and this view surfaces it as a calm Apple-Health-style chip strip.
///
/// **Interaction (future):** chips are visually tap-targets ready — the
/// strip exposes an optional `onTap` so the caller can hook a source-filter
/// without owning the layout. Today the strip is read-only.
struct SourcesChipStrip: View {
    let breakdown: [ChartDetailStore.SourceCount]
    /// Currently-active source filter (if any). The matching chip renders
    /// raised + tinted; tapping it clears the filter.
    let activeFilter: MeasurementSource?
    /// Tap-handler invoked with the tapped source. `nil` if read-only.
    let onTap: ((MeasurementSource) -> Void)?

    init(
        breakdown: [ChartDetailStore.SourceCount],
        activeFilter: MeasurementSource? = nil,
        onTap: ((MeasurementSource) -> Void)? = nil
    ) {
        self.breakdown = breakdown
        self.activeFilter = activeFilter
        self.onTap = onTap
    }

    var body: some View {
        if breakdown.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HLSpace.sm) {
                    ForEach(breakdown) { entry in
                        SourceChip(
                            source: entry.source,
                            count: entry.count,
                            isActive: activeFilter == entry.source,
                            onTap: onTap.map { handler in
                                { handler(entry.source) }
                            }
                        )
                    }
                }
                .padding(.horizontal, HLSpace.hair) // hairline so chip-borders aren't clipped
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Data sources"))
        }
    }
}

/// Single chip in the strip — provenance icon + label + count badge.
private struct SourceChip: View {
    let source: MeasurementSource
    let count: Int
    let isActive: Bool
    let onTap: (() -> Void)?

    /// A2-3 (v0.11) — monochrome accent. The accent picker was retired in
    /// v0.6.1 (monochrome freeze) and nothing writes `preferredTint` anymore, so
    /// the former `settingsStore.preferredTint.color` read always resolved to
    /// the brand-purple default — a rogue colour on an otherwise monochrome
    /// surface. The active-filter chip now paints the canonical monochrome
    /// accent (`HLText.primary`), matching every other chrome surface.
    private var accent: Color {
        HLText.primary
    }

    var body: some View {
        // Theme-2.0 mono-rest, Accent-Picker-Expansion active. Every chip
        // paints mono at rest — icon + label + count all sit in `HLText.*`
        // tier. The single accent fires ONLY when the chip is the active
        // filter, paint matches the user's HLTint pick. Rainbow per-source
        // tints (.appleHealth=pink, .withings=cyan etc.) are gone; provenance
        // is signaled by the SF Symbol shape, not by colour.
        let iconColor = isActive ? accent : HLText.secondary
        let chip = HStack(spacing: HLSpace.xs) {
            Image(systemName: iconName)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(iconColor)
            Text(label)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.primary)
            Text("\(count)")
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .monospacedDigit()
                .padding(.horizontal, HLSpace.xs)
                .padding(.vertical, HLSpace.hair)
                .background(
                    Capsule().fill(HLSurface.tertiary)
                )
        }
        .padding(.horizontal, HLSpace.md)
        .padding(.vertical, HLSpace.sm)
        .background(
            Capsule().fill(isActive ? accent.opacity(HLOpacity.surfaceTintStrong) : HLSurface.secondary)
        )
        .overlay(
            Capsule().stroke(isActive ? accent.opacity(0.4) : Color.clear, lineWidth: 1)
        )

        if let onTap {
            Button(action: onTap) { chip }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(label), \(count) entries"))
                .accessibilityHint(Text(isActive
                        ? String(localized: "Double-tap to clear the filter")
                        : String(localized: "Double-tap to filter by this source")))
                .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        } else {
            chip
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(label), \(count) entries"))
        }
    }

    private var iconName: String {
        switch source {
        case .appleHealth: "heart.text.square.fill"
        case .withings: "scale.3d"
        case .whoop: "bolt.heart.fill"
        case .fitbit: "figure.run"
        case .googleHealth: "waveform.path.ecg"
        case .strava: "figure.outdoor.cycle"
        case .oura: "circle.circle.fill"
        case .polar: "heart.circle.fill"
        case .nightscout: "drop.fill"
        case .manual: "pencil.tip.crop.circle"
        case .computed: "function"
        case .import_: "square.and.arrow.down.fill"
        }
    }

    private var label: String {
        switch source {
        case .appleHealth: String(localized: "Apple Health")
        case .withings: String(localized: "Withings")
        case .whoop: String(localized: "WHOOP")
        case .fitbit: String(localized: "Fitbit")
        case .googleHealth: String(localized: "Google Health")
        case .strava: String(localized: "Strava")
        case .oura: String(localized: "Oura")
        case .polar: String(localized: "Polar")
        case .nightscout: String(localized: "Nightscout")
        case .manual: String(localized: "Manual")
        case .computed: String(localized: "measurement.source.computed")
        case .import_: String(localized: "Import")
        }
    }
}
