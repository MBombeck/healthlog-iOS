import SwiftUI

/// v0.10.0 W-Insights (R2 §3.1/§3.2) — the "deep" element generalized from
/// `BPStatusCard.bpInTargetBar`. A thin (8 pt) rounded rail with a
/// status-toned fill representing `% of the last 30 days in the target band`,
/// plus a one-line target-band label. This is the single biggest felt upgrade
/// of the Insights redesign: it carries BP-level depth to every tile that has
/// a reference range. Tiles without a configured range simply omit the band —
/// exactly as BP omits it when `targets == nil`.
///
/// **Monochrome doctrine (handbook §1.2 / §9):** the rail track is mono
/// (`HLColor.backgroundEleva`); the only color is the status-toned fill +
/// the percentage label, which reuse the SAME `statusOK / statusWarn /
/// statusBad` tones already sanctioned on the BP card.
///
/// **Reusable by W-Mood:** the value type + rail view are self-contained
/// (no Insights-screen state). The mood-detail surface can render the exact
/// same rail by handing in a `RangeBand`.
public struct RangeBand: Sendable, Equatable {
    /// Lower bound label (e.g. `"71"`, `"120/70"`). Free-form so callers
    /// format per metric.
    public let lowerLabel: String
    /// Upper bound label (e.g. `"74"`, `"129/79"`).
    public let upperLabel: String
    /// Optional unit appended after the band (e.g. `"kg"`, `"mmHg"`).
    public let unit: String?
    /// Percentage of the last 30 days inside the target band, 0…100. Clamped
    /// on render so a malformed server payload can never render "131 %".
    public let pctInRange: Int

    public init(lowerLabel: String, upperLabel: String, unit: String? = nil, pctInRange: Int) {
        self.lowerLabel = lowerLabel
        self.upperLabel = upperLabel
        self.unit = unit
        self.pctInRange = pctInRange
    }

    /// Pure pct→fill-fraction helper (0…1). `nonisolated static` so the
    /// clamping contract is unit-testable without a SwiftUI render pass.
    public nonisolated static func fillFraction(pct: Int) -> CGFloat {
        CGFloat(min(100, max(0, pct))) / 100
    }

    /// Status tone for the fill + percentage label. Mirrors
    /// `BPStatusCard.targetTone` verbatim (≥80 OK · 50–79 warn · <50 bad) so
    /// BP folds into the unified tile without a visual change.
    public nonisolated static func tone(pct: Int) -> RangeBandTone {
        switch pct {
        case 80...: .ok
        case 50 ..< 80: .warn
        default: .bad
        }
    }

    /// The localized "Target 71–74 kg" line. Built here so callers and tests
    /// share one format.
    public var targetLine: String {
        if let unit, !unit.isEmpty {
            String(localized: "Target \(lowerLabel)–\(upperLabel) \(unit)")
        } else {
            String(localized: "Target \(lowerLabel)–\(upperLabel)")
        }
    }
}

/// Status tone abstraction so the pure `RangeBand` value type stays free of
/// `SwiftUI.Color` (keeps it `Sendable` + unit-testable in isolation). The
/// view resolves the actual signal color.
public enum RangeBandTone: Sendable, Equatable {
    case ok
    case warn
    case bad

    var color: Color {
        switch self {
        case .ok: HLColor.statusOK
        case .warn: HLColor.statusWarn
        case .bad: HLColor.statusBad
        }
    }
}

/// The 8 pt status-toned rail + percentage header + target-band label.
/// Verbatim of `BPStatusCard.bpInTargetBar` so BP and every ranged tile read
/// identically (handbook cross-screen consistency).
public struct RangeBandRow: View {
    let band: RangeBand
    /// v0.10.0 — animate the fill width when the in-range % updates; static
    /// under reduce-motion (R2 §6.6).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(band: RangeBand) {
        self.band = band
    }

    public var body: some View {
        let pct = min(100, max(0, band.pctInRange))
        let tone = RangeBand.tone(pct: band.pctInRange).color
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack {
                Text(String(localized: "In range"))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                Spacer()
                Text(HLNumberFormat.percent(pct))
                    .font(.hlCaption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tone)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // DRIFT-8 — share the ONE empty-track token + corner radius
                    // with `InsightsInTargetBar` so every Insights percentage rail
                    // reads as one family.
                    RoundedRectangle(cornerRadius: InsightsInTargetBar.cornerRadius)
                        .fill(InsightsInTargetBar.trackTone)
                        .frame(height: InsightsInTargetBar.railHeight)
                    RoundedRectangle(cornerRadius: InsightsInTargetBar.cornerRadius)
                        .fill(tone)
                        .frame(
                            width: geo.size.width * RangeBand.fillFraction(pct: pct),
                            height: InsightsInTargetBar.railHeight
                        )
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: pct)
                }
            }
            .frame(height: InsightsInTargetBar.railHeight)
            Text(band.targetLine)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(pct) of 30 days in target range"))
    }
}

#Preview("RangeBandRow — in range") {
    VStack(spacing: HLSpace.lg) {
        RangeBandRow(band: RangeBand(lowerLabel: "71", upperLabel: "74", unit: "kg", pctInRange: 88))
        RangeBandRow(band: RangeBand(lowerLabel: "120/70", upperLabel: "129/79", unit: "mmHg", pctInRange: 62))
        RangeBandRow(band: RangeBand(lowerLabel: "60", upperLabel: "70", unit: "bpm", pctInRange: 34))
    }
    .padding()
    .background(HLSurface.secondary)
}
