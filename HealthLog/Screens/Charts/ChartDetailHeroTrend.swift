import SwiftUI

// HeroStrip trend decoration extracted from
// `ChartDetailScreen.swift` so the host file stays under the SwiftLint
// 1000-line ceiling (handbook convention: peel sub-components into a
// sibling file rather than grow the screen file unbounded — same pattern
// as `ComplianceRingCard.swift` / `MedicationDetailSections.swift`).
//
// The views render values the chart-detail surface used to drop on the
// floor: the window's change (`HeroDeltaChip`) and the `avg30LastYear`
// year-over-year baseline (`YearOverYearRow`). Every number is server-sourced — no on-device
// inference, per "alle Werte referenzieren, keine Halluzinationen".

// MARK: - Delta pill

/// Hero delta pill: the window's change next to the page's one large figure.
///
/// One colour rule with the start page tiles: the pill takes a colour only
/// when the server judged the change against the person's own band
/// (`series.change.sentiment`), green for favourable, red for adverse, and
/// stays grey otherwise. A tap from a green tile arrow therefore lands on a
/// green pill, never on a grey one. The verdict is spoken as well.
///
/// Blood pressure is two values; the server's change is the systolic one,
/// and the pill says so.
///
/// Named `HeroDeltaChip` (not `DeltaChip`) to avoid colliding with the
/// `DeltaChip` the HealthScore tile declares.
struct HeroDeltaChip: View {
    let delta: Double
    let unit: String
    /// The server's verdict; `nil` → grey and nothing to say.
    var sentiment: TrendSentiment?
    /// What the change compares, for VoiceOver.
    var basis: RangeChange.Basis?
    /// A duration kind (sleep) shows its change in hours and minutes.
    var kind: MetricKind?
    /// The arrow when the server named the direction (``RangeChange/symbol``);
    /// `nil` reads it from the sign of ``delta``.
    var symbol: String?

    /// The tone of a change: the tile arrows' colour for the same verdict.
    static func tone(for sentiment: TrendSentiment?) -> HLBadge.Tone {
        guard let sentiment else { return .neutral }
        return switch TrendChip.Mode.colorRole(for: sentiment) {
        case .statusOK: .success
        case .statusBad: .critical
        case .textSecondary, .none: .neutral
        }
    }

    var body: some View {
        HLBadge(
            Self.label(delta: delta, unit: unit, kind: kind),
            icon: symbol ?? Self.symbol(for: delta),
            tone: Self.tone(for: sentiment)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// The size of the change in the unit, or in hours and minutes.
    static func label(delta: Double, unit: String, kind: MetricKind?) -> String {
        if let kind, let duration = MetricDurationFormat.text(abs(delta), kind: kind) {
            return duration
        }
        let amount = "\(HLValueFormat.number(abs(delta), fractionDigits: 0 ... 1)) \(unit)"
        // The pressure's change is the systolic one: the pill names it.
        return kind == .bloodPressure ? String(localized: "chart.hero.change.systolic \(amount)") : amount
    }

    /// Up for a rise, down for a fall, a dash for no change.
    nonisolated static func symbol(for delta: Double) -> String {
        delta > 0 ? "arrow.up" : delta < 0 ? "arrow.down" : "minus"
    }

    private var accessibilityLabel: String {
        let number = HLValueFormat.number(delta, fractionDigits: 0 ... 1)
        let base = switch basis {
        case .firstToLastDay: String(localized: "chart.hero.change.firstToLastDay.a11y \(number) \(unit)")
        case .priorHalf, .priorWindow, .none: String(localized: "Delta to the previous period: \(number) \(unit)")
        }
        guard let clause = sentiment?.spokenClause else { return base }
        return "\(base), \(clause)"
    }
}

// MARK: - Year-over-year row

/// "Vor 1 Jahr" baseline + delta, both sourced verbatim from the server's
/// `avg30LastYear`. One quiet line: the hero carries one capsule, so the year's
/// change is text in the same grey.
struct YearOverYearRow: View {
    let baseline: Double
    let delta: Double?
    let unit: String

    var body: some View {
        HStack(spacing: HLSpace.xs) {
            Text(String(localized: "1 year ago"))
                .foregroundStyle(HLText.tertiary)
            Text(baselineText)
                .fontWeight(.semibold)
                .foregroundStyle(HLText.secondary)
                .monospacedDigit()
            if let delta {
                Text(Self.signed(delta, unit: unit))
                    .foregroundStyle(HLText.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .font(.hlCaption)
        .padding(.top, HLSpace.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// The change with its sign: "+0,4 kg", "−1,2 kg".
    nonisolated static func signed(_ delta: Double, unit: String) -> String {
        let number = HLValueFormat.number(abs(delta), fractionDigits: 0 ... 1)
        let sign = delta > 0 ? "+" : delta < 0 ? "\u{2212}" : "\u{00B1}"
        return unit.isEmpty ? sign + number : "\(sign)\(number) \(unit)"
    }

    private var baselineText: String {
        let value = HLValueFormat.number(baseline, fractionDigits: 0 ... 1)
        return unit.isEmpty ? value : "\(value) \(unit)"
    }

    private var accessibilityLabel: String {
        guard let delta else {
            return String(localized: "1 year ago: \(baselineText)")
        }
        let deltaText = HLValueFormat.number(delta, fractionDigits: 0 ... 1)
        return String(localized: "1 year ago: \(baselineText), change \(deltaText) \(unit)")
    }
}
