import Charts
import SwiftUI

/// Drug-level chart section for `MedicationDetailScreen`.
///
/// **MDR boundary (`14-coach-mental-model.md` + GROUND RULE 15):**
///
/// - Y-axis is **unit-less**. No tick labels. Caption reads "Geschätzter
///   Spiegel (relativ)" / "Estimated level (relative)".
/// - X-axis is dated.
/// - NO "predicted next peak" marker. NO clinical interpretation.
/// - Current-time vertical rule + last-dose dot are the ONLY annotations.
/// - Disclaimer copy below the chart is byte-equal to the server's locked
///   wording (`Localizable.xcstrings`).
///
/// **D-12-05-A — the gate is gone; the curve is not.** The server retired
/// Research Mode on 2026-08-08 (`0160052289e4`): *"The chart stopped consulting
/// the flag several releases ago and has painted for every account since… The
/// curve is simply part of the medication page now."* The opt-in, the
/// acknowledgment dialog, `/api/auth/me/research-mode` and the three user
/// columns went with it, so this section renders on its own inputs alone:
///
/// - doses available → `Chart` + the MDR caption,
/// - no doses → `EmptyDosesPlaceholder`.
///
/// There is no failure branch: with nothing to fetch there is nothing whose
/// failure could paint over the chart. The type name is kept — the section is
/// still MDR-bounded, and the name is what the UI census and the screen's call
/// site already address.
///
/// **14-02 (A3) — there IS a third branch now, and it is a loading branch.**
/// The 12-10 "no skeleton zoo" decision is amended, not overturned: it was made
/// about a section whose input was assumed to be present, and the input is
/// `intakes`, which arrives as a first page plus up to 80 sequential drain
/// pages. The section was therefore handed one partial dose set per page, drew
/// each as if it were the finished curve, and then jumped when the last one
/// landed — the operator's A3. One loading branch with the chart's own reserved
/// height, keyed off the store's settled-collection fact rather than off a
/// timer, is a statement about a section whose input is known to arrive late.
///
/// The curve is no longer computed here either: ``MedicationDetailStore``
/// publishes a settled ``MedicationDetailStore/DrugLevelCurve`` computed once
/// per settled input, off the render path.
struct MDRGatedDrugLevelSection: View {
    @Bindable var store: MedicationDetailStore
    let drug: GLP1DrugCatalog.DrugRecord

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            // T2-4: section label Withings rhythm.
            HLSectionLabel("Estimated drug level")

            switch store.drugLevelSection {
            case .loading:
                DrugLevelLoadingPlaceholder()
            case .empty:
                EmptyDosesPlaceholder()
            case let .curve(curve):
                DrugLevelChartView(drug: drug, curve: curve)
                DisclaimerCaption()
            }
        }
    }
}

// MARK: - Loading (14-02)

/// The reserved frame the curve will fill. Same caption line and same ghost
/// card as the chart, and the height comes from `HLChartStyle.heightDetail` —
/// the chart's own height rule — so nothing moves when the curve arrives and
/// Phase 17's consistency sweep has no hardcoded point value to chase.
private struct DrugLevelLoadingPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text(String(localized: "Estimated level (relative)"))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
            HLCard(style: .ghost) {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: HLChartStyle.heightDetail)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "Loading")))
    }
}

// MARK: - Empty doses

private struct EmptyDosesPlaceholder: View {
    var body: some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(String(localized: "No intakes logged yet."))
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                Text(String(localized: "Log your first intake to see the curve."))
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
            }
        }
    }
}

// MARK: - Disclaimer caption

private struct DisclaimerCaption: View {
    var body: some View {
        Text(String(localized: "Educational estimate from EMA-published population pharmacokinetics. Not a measurement."))
            .font(.hlCaption)
            .italic()
            .foregroundStyle(HLText.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, HLSpace.xs)
    }
}

// MARK: - Chart

/// The actual PK chart. **DO NOT** add y-axis tick labels, predictive markers,
/// or any clinical interpretation overlay here. Future maintainers: a
/// "predicted next peak" marker breaches GROUND RULE 15 — the lint rule in
/// `Pharmacokinetics/.swiftlint.yml` will flag the obvious cases but cannot
/// catch every formulation. Trust the regulatory ceiling.
private struct DrugLevelChartView: View {
    let drug: GLP1DrugCatalog.DrugRecord
    /// 14-02 (A3) — the settled curve, computed once by the store. The window
    /// (21 d back, no projection, 6 h step — web parity, 2026-07-18) moved to
    /// `MedicationDetailStore.drugLevelChartOptions` together with the
    /// computation it parameterizes. Nothing in this view computes a curve, and
    /// nothing here may start doing so again: `body` runs on every unrelated
    /// store mutation, and this input settles exactly once.
    let curve: MedicationDetailStore.DrugLevelCurve

    private var doses: [Glp1PK.DoseEvent] {
        curve.doses
    }

    private var samples: [Glp1PK.Sample] {
        curve.samples
    }

    /// Reference "now" the curve is anchored to, captured by the store when it
    /// computed the curve — so the two can never disagree.
    private var asOf: Date {
        curve.asOf
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text(String(localized: "Estimated level (relative)"))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
            HLCard(style: .ghost) {
                Chart {
                    ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                        AreaMark(
                            x: .value("Datum", date(for: sample.tHours)),
                            y: .value("Spiegel", sample.concentration)
                        )
                        .foregroundStyle(
                            // v0.6.1 mono refresh — Trulicity PK chart drops
                            // Dracula-Purple/-PurpleDeep across area, line,
                            // point and annotation in favour of the mono
                            // primary text token. Axis stays hidden per the
                            // MDR boundary lock further down this file.
                            LinearGradient(
                                colors: [HLText.primary.opacity(0.4), HLText.primary.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("Datum", date(for: sample.tHours)),
                            y: .value("Spiegel", sample.concentration)
                        )
                        .foregroundStyle(HLText.primary)
                        .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth))
                        .interpolationMethod(.monotone)
                    }
                    ForEach(Array(doses.enumerated()), id: \.offset) { _, dose in
                        PointMark(
                            x: .value("Datum", dose.takenAt),
                            y: .value("Spiegel", 0)
                        )
                        .symbol(.circle)
                        .symbolSize(60)
                        .foregroundStyle(HLText.primary)
                        .annotation(position: .bottom, alignment: .center) {
                            Image(systemName: "syringe.fill")
                                .font(.hlCaption2)
                                .foregroundStyle(HLText.primary)
                        }
                    }
                    RuleMark(x: .value("Jetzt", asOf))
                        .foregroundStyle(HLText.tertiary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text(String(localized: "Now"))
                                .font(.hlCaption)
                                .foregroundStyle(HLText.tertiary)
                                .padding(.horizontal, HLSpace.xs)
                        }
                }
                // MDR boundary — Y-axis MUST stay unit-less. Do not add
                // AxisMarks(values:) or any tick labels here. The
                // `.chartYAxis(.hidden)` is the locked render rule. The
                // SwiftLint custom rule in `Pharmacokinetics/.swiftlint.yml`
                // tries to catch obvious regressions; trust the boundary.
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                        AxisGridLine().foregroundStyle(HLColor.separator)
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                            .font(.hlCaption)
                    }
                }
                .frame(height: HLChartStyle.heightDetail)
                .accessibilityChartDescriptor(
                    HLChartDescriptor(Self.buildDescriptor(drug: drug, curve: curve))
                )
            }
        }
    }

    /// Build an `AXChartDescriptor` whose Y-axis returns **qualitative**
    /// strings only — never a numeric concentration. Anchors to the per-
    /// sample shot-phase (rising / peak / fading) so VoiceOver reads
    /// "Rising at March 7th, 14:00" instead of "0.32 at March 7th".
    ///
    /// **14-02 (A3)** — the phase classification is no longer computed here.
    /// `Glp1PK.shotPhase` runs a whole probe curve per sample, so this loop was
    /// O(samples × doses × probe) on every body pass of a section whose input
    /// settles exactly once. The store computes the phases with the curve; this
    /// is now pure assembly plus the localization of a closed-set enum.
    private static func buildDescriptor(
        drug: GLP1DrugCatalog.DrugRecord,
        curve: MedicationDetailStore.DrugLevelCurve
    ) -> AXChartDescriptor {
        let samples = curve.samples
        let asOf = curve.asOf
        let title = String(localized: "Estimated drug level — \(drug.inn)")
        let summary = String(localized: "Qualitative trend. Y axis without unit. Educational estimate.")

        // AUD-2 H3 — index-keyed x label gives VoiceOver a readable date for
        // each sample. The formatter is a static cached instance (was a fresh
        // `DateFormatter()` per `buildDescriptor` call, reached from the
        // accessibility-chart-descriptor render path — ~50-100µs init + heap
        // churn on a live-updating PK curve).
        let formatter = Self.axDateFormatter

        let points = samples.enumerated().map { idx, sample -> (x: Double, y: Double, xLabel: String) in
            let absoluteDate = asOf.addingTimeInterval(sample.tHours * 3600)
            return (
                x: Double(idx),
                y: sample.concentration,
                xLabel: formatter.string(from: absoluteDate)
            )
        }

        // The per-sample phase classification, so VoiceOver reads a qualitative
        // label and never a numeric value. Computed once with the curve, in the
        // store; localized here.
        let phaseLabels: [String] = curve.phases.map(Self.phaseLabel)

        return HLChartAX.singleSeries(
            title: title,
            summary: summary,
            xAxisTitle: String(localized: "Date"),
            yAxisTitle: String(localized: "Estimated level (relative)"),
            seriesName: drug.inn,
            points: points,
            yValueLabel: { value in
                // Find the nearest sample index — its phase becomes the label.
                guard let nearest = samples.enumerated().min(
                    by: { abs($0.element.concentration - value) < abs($1.element.concentration - value) }
                ) else {
                    return String(localized: "undetermined")
                }
                return phaseLabels[nearest.offset]
            }
        )
    }

    /// AUD-2 H3 — cached medium-date/short-time formatter for the
    /// accessibility chart descriptor's x-axis labels. Hoisted to a static
    /// `let` so the descriptor build path no longer allocates a `DateFormatter`
    /// per render. `DateFormatter` is thread-safe for read-only formatting.
    private nonisolated static let axDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func phaseLabel(_ phase: Glp1PK.ShotPhase) -> String {
        switch phase {
        case .rising: String(localized: "rising")
        case .peak: String(localized: "near peak")
        case .fading: String(localized: "fading")
        case .none: String(localized: "undetermined")
        }
    }

    private func date(for tHours: Double) -> Date {
        asOf.addingTimeInterval(tHours * 3600)
    }
}
