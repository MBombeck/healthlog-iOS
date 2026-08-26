import Accessibility
import Charts
import SwiftUI

/// Renders the four scatter-correlation cards from `comprehensive.digest`.
///
/// **Background (A8 §7):** Server emits four correlation matrices on
/// `/api/insights/comprehensive` — BP × Weight, BP × Medication-Compliance,
/// Mood × BP, Mood × Weight, Mood × Pulse. Until v0.4.0 iOS rendered none
/// of them (the placeholder `/api/insights/correlations` route returns `[]`).
///
/// **UI pattern** (Apple Health "Trends → Compare" idiom):
/// - Scatter plot via `Chart` + `PointMark`
/// - r-value + n-sample-size header
/// - Plain-language interpretation from server-emitted `strength` enum
/// - Hidden when `n < 5` (server already gates at minPairs=5)
/// I-1 D — the five cross-metric correlation pairs the server emits. Each pair
/// belongs to ONE primary metric page (so the combo card can be relocated off the
/// overview onto the metric it concerns):
///   • `.bpMedication` → Medications page
///   • `.weightBp` → Blutdruck page
///   • `.moodBp` → Stimmung page
///   • `.moodPulse` → Puls page
///   • `.moodWeight` → Gewicht page
public enum CorrelationPair: CaseIterable, Sendable {
    case bpMedication
    case weightBp
    case moodBp
    case moodPulse
    case moodWeight

    /// **A360 H2 (v0156)** — the Coach launch scope spanning both metrics in this
    /// pair, so an "Ask the coach about this" tap opens the Coach pre-scoped to
    /// exactly the relationship the card describes (web parity with
    /// `correlation-card.tsx`'s `COACH_SOURCES_BY_KIND`).
    public var coachLaunchScope: CoachLaunchScope {
        switch self {
        case .bpMedication: CoachLaunchScope(metric: .bp, also: [.compliance])
        case .weightBp: CoachLaunchScope(metric: .weight, also: [.bp])
        case .moodBp: CoachLaunchScope(metric: .mood, also: [.bp])
        case .moodPulse: CoachLaunchScope(metric: .mood, also: [.pulse])
        case .moodWeight: CoachLaunchScope(metric: .mood, also: [.weight])
        }
    }

    /// **A360 H2 (v0156)** — a localized composer opener referencing this pair's
    /// relationship, so the Coach composer pre-fills instead of opening blank.
    public var coachSeed: String {
        switch self {
        case .bpMedication:
            String(localized: "How does my medication adherence relate to my blood pressure?")
        case .weightBp:
            String(localized: "Is there a link between my weight and my blood pressure?")
        case .moodBp:
            String(localized: "Is there a link between my mood and my blood pressure?")
        case .moodPulse:
            String(localized: "Is there a link between my mood and my heart rate?")
        case .moodWeight:
            String(localized: "Is there a link between my mood and my weight?")
        }
    }
}

public struct CorrelationsPanel: View {
    let digest: ComprehensiveDigest
    /// The subset of pairs this panel renders. The overview passed `.allCases`
    /// (now relocated per-metric); a metric page passes only the pair(s) it owns.
    let pairs: Set<CorrelationPair>
    /// Whether to append the observational-not-causal reading note below the
    /// cards. The overview row owned its own note; the per-metric block renders
    /// one inline here so the relocated card never loses it.
    let showsDisclaimer: Bool
    /// **A360 H2 (v0156)** — "Ask the coach about this" affordance per correlation
    /// card. The host opens the Coach pre-scoped to both metrics in the tapped
    /// pair (`pair.coachLaunchScope`) with a localized opener (`pair.coachSeed`).
    /// `nil` (the Coach surface gated off / standalone) hides the affordance.
    let onAskCoach: ((CorrelationPair) -> Void)?

    public init(
        digest: ComprehensiveDigest,
        pairs: Set<CorrelationPair> = Set(CorrelationPair.allCases),
        showsDisclaimer: Bool = false,
        onAskCoach: ((CorrelationPair) -> Void)? = nil
    ) {
        self.digest = digest
        self.pairs = pairs
        self.showsDisclaimer = showsDisclaimer
        self.onAskCoach = onAskCoach
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            // MED-2: the section label is owned by the ONE canonical
            // `InsightsSectionHeader` at the call site (inline row) /
            // `navigationTitle` (standalone screen). The panel no longer paints
            // its own duplicate header.

            // Order: most actionable signal first (BP × Medication), then
            // weight, then mood-derived signals.
            if pairs.contains(.bpMedication),
               let corr = digest.bpMedicationCorrelation,
               let scatter = digest.bpMedicationScatterData,
               scatter.count >= 5
            {
                CorrelationCard(
                    title: String(localized: "Blood pressure × medication compliance"),
                    strengthLabel: strengthLabel(corr.strength),
                    interpretation: bpMedicationInterpretation(corr: corr),
                    r: corr.r,
                    n: corr.n,
                    xAxisTitle: String(localized: "Intake rate (%)"),
                    yAxisTitle: String(localized: "Systolic (mmHg)"),
                    points: scatter,
                    xValue: { $0.continuityPct },
                    yValue: { $0.sysBP },
                    tone: HLText.secondary,
                    onAskCoach: onAskCoach.map { handler in { handler(.bpMedication) } }
                )
            }
            if pairs.contains(.weightBp),
               let corr = digest.weightBpCorrelation,
               let scatter = digest.scatterData,
               scatter.count >= 5
            {
                CorrelationCard(
                    title: String(localized: "Weight × blood pressure"),
                    strengthLabel: strengthLabel(corr.strength),
                    interpretation: "",
                    r: corr.r,
                    n: corr.n,
                    xAxisTitle: String(localized: "Weight (kg)"),
                    yAxisTitle: String(localized: "Systolic (mmHg)"),
                    points: scatter,
                    xValue: { $0.weight },
                    yValue: { $0.sysBP },
                    tone: HLText.secondary,
                    onAskCoach: onAskCoach.map { handler in { handler(.weightBp) } }
                )
            }
            if pairs.contains(.moodBp),
               let corr = digest.moodBpCorrelation,
               let scatter = digest.moodBpScatterData,
               scatter.count >= 5
            {
                CorrelationCard(
                    title: String(localized: "Mood × blood pressure"),
                    strengthLabel: strengthLabel(corr.strength),
                    interpretation: "",
                    r: corr.r,
                    n: corr.n,
                    xAxisTitle: String(localized: "Mood (1–5)"),
                    yAxisTitle: String(localized: "Systolic (mmHg)"),
                    points: scatter,
                    xValue: { $0.mood },
                    yValue: { $0.sysBP },
                    tone: HLText.secondary,
                    onAskCoach: onAskCoach.map { handler in { handler(.moodBp) } }
                )
            }
            if pairs.contains(.moodPulse),
               let corr = digest.moodPulseCorrelation,
               let scatter = digest.moodPulseScatterData,
               scatter.count >= 5
            {
                CorrelationCard(
                    title: String(localized: "Mood × heart rate"),
                    strengthLabel: strengthLabel(corr.strength),
                    interpretation: "",
                    r: corr.r,
                    n: corr.n,
                    xAxisTitle: String(localized: "Mood (1–5)"),
                    yAxisTitle: String(localized: "Pulse (bpm)"),
                    points: scatter,
                    xValue: { $0.mood },
                    yValue: { $0.pulse },
                    tone: HLText.secondary,
                    onAskCoach: onAskCoach.map { handler in { handler(.moodPulse) } }
                )
            }
            if pairs.contains(.moodWeight),
               let corr = digest.moodWeightCorrelation,
               let scatter = digest.moodWeightScatterData,
               scatter.count >= 5
            {
                CorrelationCard(
                    title: String(localized: "Mood × weight"),
                    strengthLabel: strengthLabel(corr.strength),
                    interpretation: "",
                    r: corr.r,
                    n: corr.n,
                    xAxisTitle: String(localized: "Mood (1–5)"),
                    yAxisTitle: String(localized: "Weight (kg)"),
                    points: scatter,
                    xValue: { $0.mood },
                    yValue: { $0.weight },
                    tone: HLText.secondary,
                    onAskCoach: onAskCoach.map { handler in { handler(.moodWeight) } }
                )
            }
            // I-1 D — `EmptyCorrelationCard` is the FULL-set (overview) "no
            // correlations yet" placeholder. A per-metric subset (relocated card)
            // must show NOTHING when its one pairing has no signal — never an
            // empty placeholder on a metric page. So the empty card only renders
            // for the full overview set; the subset path renders nothing.
            if !hasAnyCard {
                if isFullSet {
                    EmptyCorrelationCard()
                }
            } else if showsDisclaimer {
                // v0.11 — causal-misread guard. A correlation card is the
                // highest-risk surface for "X causes Y" misreading. The
                // overview row owns its OWN note (`showsDisclaimer: false`
                // there); the relocated per-metric block opts in so the card
                // never loses it.
                //
                // UI-Standard R17 (U1) — the line is a READING INSTRUCTION for
                // the number above it, not a disclaimer: it is now the same
                // three words the mood cross-tab already uses („Zusammenhänge,
                // keine Ursachen."). The „talk to your doctor" tail fell — that
                // is the ack-sheet's job, not this card's. The ack-gate that
                // used to hide the whole footer fell with it: a reading
                // instruction is content and never suppresses itself.
                Text("correlations.disclaimer")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("insights.correlations.disclaimer")
            }
        }
    }

    /// True when this panel renders the complete correlation set (the overview
    /// behaviour). A per-metric subset is NOT the full set, so it suppresses the
    /// "no correlations yet" placeholder.
    private var isFullSet: Bool {
        pairs == Set(CorrelationPair.allCases)
    }

    /// Surface-level check — true if **any** correlation card in THIS panel's
    /// pair subset will render. Used by the call site to decide whether to even
    /// insert this panel (so a metric page that owns no ok pairing shows nothing).
    public var hasAnyCard: Bool {
        if pairs.contains(.bpMedication),
           let scatter = digest.bpMedicationScatterData, scatter.count >= 5, digest.bpMedicationCorrelation != nil
        {
            return true
        }
        if pairs.contains(.weightBp),
           let scatter = digest.scatterData, scatter.count >= 5, digest.weightBpCorrelation != nil
        {
            return true
        }
        if pairs.contains(.moodBp),
           let scatter = digest.moodBpScatterData, scatter.count >= 5, digest.moodBpCorrelation != nil
        {
            return true
        }
        if pairs.contains(.moodPulse),
           let scatter = digest.moodPulseScatterData, scatter.count >= 5, digest.moodPulseCorrelation != nil
        {
            return true
        }
        if pairs.contains(.moodWeight),
           let scatter = digest.moodWeightScatterData, scatter.count >= 5, digest.moodWeightCorrelation != nil
        {
            return true
        }
        return false
    }

    /// Short strength word for the trailing chip on a correlation row
    /// (pair label leading, strength trailing — like a settings row's value).
    private func strengthLabel(_ strength: CorrelationStrength?) -> String {
        switch strength ?? .keine {
        case .stark: String(localized: "Strong")
        case .moderat: String(localized: "Moderate")
        case .schwach: String(localized: "Weak")
        case .keine: String(localized: "correlations.strength.none")
        }
    }

    /// BP × Medication: the desired correlation is **negative** (more
    /// compliance → lower BP) — we phrase it accordingly.
    private func bpMedicationInterpretation(corr: BPMedicationCorrelation) -> String {
        let strength = corr.strength ?? .keine
        switch (strength, corr.r < 0) {
        case (.stark, true):
            return String(localized: "Days with a high intake rate were followed by markedly lower blood pressure.")
        case (.moderat, true):
            return String(localized: "Days with a high intake rate tended to be followed by lower blood pressure.")
        case (.schwach, true):
            return String(localized: "Weak hint that intake days lower blood pressure.")
        case (.stark, false), (.moderat, false), (.schwach, false):
            return String(localized: "Data show no clear BP effect of your intake rate.")
        case (.keine, _):
            return String(localized: "Too little spread for a clear statement yet.")
        }
    }
}

// MARK: - CorrelationCard

private struct CorrelationCard<Point: Sendable>: View {
    let title: String
    /// Short strength word ("schwach"/"mittel"/"stark") shown as a trailing chip
    /// on the SAME row as the pair label.
    let strengthLabel: String
    let interpretation: String
    let r: Double
    let n: Int
    let xAxisTitle: String
    let yAxisTitle: String
    let points: [Point]
    let xValue: (Point) -> Double
    let yValue: (Point) -> Double
    let tone: Color
    /// A360 H2 — fired when the user taps "Ask the coach about this" on this card.
    /// `nil` hides the affordance (Coach gated off / standalone).
    var onAskCoach: (() -> Void)?

    var body: some View {
        // v0.14.1 §5/§8 — the Zusammenhänge block reads as grey flowing text in
        // the SAME voice as the intro `descriptionSlot`, NOT a loud boxed `HLCard`.
        // The title + plain-language interpretation flow as calm grey prose
        // (`HLText.secondary`), the scatter sits inline (no card chrome), and the
        // r-value / sample size drop to a quiet caption. Matches the operator's
        // "not loud cards, same grey flowing style as the intro" on every metric.
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            // C1 — pair label leading, strength as a trailing chip on the SAME
            // row (like a settings row's value), instead of the strength on a
            // separate line below.
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Text(title)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: HLSpace.sm)

                Text(strengthLabel)
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                    .padding(.horizontal, HLSpace.sm)
                    .padding(.vertical, HLSpace.xxs)
                    .background(
                        Capsule(style: .continuous)
                            .fill(HLSurface.tertiary)
                    )
                    .fixedSize()
                    .accessibilityLabel(Text(strengthLabel))
            }

            if !interpretation.isEmpty {
                Text(interpretation)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Chart {
                ForEach(0 ..< points.count, id: \.self) { idx in
                    let p = points[idx]
                    PointMark(
                        x: .value(xAxisTitle, xValue(p)),
                        y: .value(yAxisTitle, yValue(p))
                    )
                    .foregroundStyle(tone)
                    .symbolSize(40)
                }
            }
            .chartXAxisLabel(xAxisTitle)
            .chartYAxisLabel(yAxisTitle)
            .frame(height: 160)
            .accessibilityChartDescriptor(HLChartDescriptor(chartDescriptor))

            Text(String(localized: "r = \(r.formatted(.number.precision(.fractionLength(2)))) · based on \(n) days"))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)

            // A360 H2 — discreet "Ask the coach about this" footer link, scoped to
            // both metrics in the pair. Monochrome, footnote-weight — a quiet
            // affordance, never a loud CTA (the medication-card restraint rule).
            if let onAskCoach {
                Button(action: onAskCoach) {
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: "sparkles")
                            .font(.hlIcon(HLIconSize.sm))
                        Text(String(localized: "Ask the coach about this"))
                            .font(.hlFootnote)
                    }
                    .foregroundStyle(HLText.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, HLSpace.xxs)
                .accessibilityIdentifier("insights.correlations.askCoach")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// AX descriptor — single scatter series so VoiceOver users can rotor
    /// through the points.
    private var chartDescriptor: AXChartDescriptor {
        let xs = points.map(xValue)
        let ys = points.map(yValue)
        let xLower = xs.min() ?? 0
        let xUpperRaw = xs.max() ?? (xLower + 1)
        let xUpper = xUpperRaw > xLower ? xUpperRaw : xLower + 1
        let yLower = ys.min() ?? 0
        let yUpperRaw = ys.max() ?? (yLower + 1)
        let yUpper = yUpperRaw > yLower ? yUpperRaw : yLower + 1
        return HLChartAX.multiSeries(
            title: title,
            summary: interpretation,
            xAxisTitle: xAxisTitle,
            yAxisTitle: yAxisTitle,
            xRange: xLower ... xUpper,
            yRange: yLower ... yUpper,
            series: [(name: title, points: points.map { (x: xValue($0), y: yValue($0)) }, continuous: false)]
        )
    }
}

// MARK: - EmptyCorrelationCard

private struct EmptyCorrelationCard: View {
    var body: some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "chart.dots.scatter")
                        .foregroundStyle(HLText.tertiary)
                    Text(String(localized: "No correlations yet"))
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                }
                Text(
                    String(
                        localized: "Once there are enough measurement pairs (at least 5 days per metric), correlations will appear here."
                    )
                )
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
