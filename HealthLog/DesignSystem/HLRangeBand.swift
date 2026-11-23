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

/// The measures of the one in-target rail.
public enum HLRangeBandMetrics {
    /// Height of the rail.
    public static let railHeight: CGFloat = 8
    /// Corner radius of the rail. Tighter than the token grid on purpose: an
    /// 8 pt rail reads cleaner with a 4 pt round.
    public static let cornerRadius: CGFloat = 4
    /// The empty part of the rail.
    public static var trackTone: Color {
        HLColor.backgroundEleva
    }
}

/// **The one in-target rail of the app.** An 8 pt status-toned rail under one
/// line: what is measured on the left, the share in the band on the right.
///
/// Two headings, one rail:
/// - `RangeBandRow(band:)` names the band ("Ziel 71 bis 74 kg"), as on a tile
///   on Heute.
/// - `RangeBandRow(share:window:)` names the share ("Im Zielbereich (30 T)"),
///   as in the status card of a metric page, where the band stands elsewhere.
///
/// The fill and the percentage share the tone of ``RangeBand/tone(pct:)``
/// (from 80 % good, from 50 % watch, below that bad).
public struct RangeBandRow: View {
    /// What the line above the rail says.
    public enum Heading: Equatable, Sendable {
        /// The band itself.
        case band(RangeBand)
        /// "In range", with the window the share is measured over.
        case share(pct: Int, window: String?)
    }

    let heading: Heading
    /// Animate the fill width when the in-range % updates; static
    /// under reduce-motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(band: RangeBand) {
        heading = .band(band)
    }

    /// The rail headed by "In range" and the window ("30 T"), for a page that
    /// shows the band elsewhere. `pct` is clamped to 0…100 on render.
    public init(share pct: Int, window: String? = nil) {
        heading = .share(pct: pct, window: window)
    }

    /// The share inside the band, clamped to 0…100.
    var pct: Int {
        switch heading {
        case let .band(band): min(100, max(0, band.pctInRange))
        case let .share(pct, _): min(100, max(0, pct))
        }
    }

    /// The words left of the percentage.
    var title: String {
        switch heading {
        case let .band(band): return band.targetLine
        case let .share(_, window):
            let base = String(localized: "In range")
            guard let window else { return base }
            return "\(base) (\(window))"
        }
    }

    /// What VoiceOver reads for the whole row.
    var spokenText: String {
        switch heading {
        case .band:
            return String(localized: "\(pct) of 30 days in target range")
        case let .share(_, window):
            guard let window else { return String(localized: "\(pct) percent of measurements in range") }
            return String(localized: "\(pct) percent of measurements in range over \(window)")
        }
    }

    /// From the accessibility sizes on the share stands under the words, so
    /// the band they name ("Ziel 61,9 bis 64 kg") is never cut.
    nonisolated static func stacks(at typeSize: DynamicTypeSize) -> Bool {
        typeSize.isAccessibilitySize
    }

    private var titleText: some View {
        Text(title)
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
    }

    private func shareText(_ tone: Color) -> some View {
        Text(HLNumberFormat.percent(pct))
            .font(.hlCaption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tone)
    }

    public var body: some View {
        let tone = RangeBand.tone(pct: pct).color
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            if Self.stacks(at: dynamicTypeSize) {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    titleText.fixedSize(horizontal: false, vertical: true)
                    shareText(tone)
                }
            } else {
                HStack {
                    titleText.lineLimit(1)
                    Spacer()
                    shareText(tone)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: HLRangeBandMetrics.cornerRadius)
                        .fill(HLRangeBandMetrics.trackTone)
                        .frame(height: HLRangeBandMetrics.railHeight)
                    RoundedRectangle(cornerRadius: HLRangeBandMetrics.cornerRadius)
                        .fill(tone)
                        .frame(
                            width: geo.size.width * RangeBand.fillFraction(pct: pct),
                            height: HLRangeBandMetrics.railHeight
                        )
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: pct)
                }
            }
            .frame(height: HLRangeBandMetrics.railHeight)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: spokenText))
    }
}

#Preview("RangeBandRow — in range") {
    VStack(spacing: HLSpace.lg) {
        RangeBandRow(band: RangeBand(lowerLabel: "71", upperLabel: "74", unit: "kg", pctInRange: 88))
        RangeBandRow(band: RangeBand(lowerLabel: "120/70", upperLabel: "129/79", unit: "mmHg", pctInRange: 62))
        RangeBandRow(band: RangeBand(lowerLabel: "60", upperLabel: "70", unit: "bpm", pctInRange: 34))
        RangeBandRow(share: 84, window: "90 T")
    }
    .padding()
    .background(HLSurface.secondary)
}
