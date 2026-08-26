import SwiftUI

/// v0.11 W-B — the per-metric target reference panel, the iOS twin of the web
/// `MetricTargetSummary` (`src/components/insights/metric-target-summary.tsx`).
///
/// Rendered inline on `ChartDetailScreen`, directly under the chart, when — and
/// ONLY when — the user has a target band configured for that metric. It folds
/// the value the retired standalone "Ziele" screen used to carry onto the
/// metric it belongs to (web parity: targets became an attribute, not a
/// destination):
///
///   • the in-target rail (`RangeBandRow`) — where the last 30 days sit inside
///     the band + the target-range label (the web's range string + RangeBar +
///     in-target share, folded into one monochrome, signal-only element);
///   • the 30-day average;
///   • the 7-day consistency strip (`ConsistencyStrip`);
///   • an "Adjust target range" affordance that opens the contextual
///     `InsightsTargetBandEditorSheet` (replacing the deleted standalone editor).
///
/// **ADAPTIVE (doctrine §6):** the whole panel self-suppresses when no target
/// is set (`range == nil`) — a metric without a target renders no empty block.
/// The consistency strip + in-target share further suppress when the window is
/// `insufficientData`. The adjust affordance only appears for metrics with an
/// editable threshold (`editableMetrics` non-empty), so derived targets (mood /
/// compliance / BMI) never show a dead button.
///
/// **Monochrome / glass:** color is signal-only (the rail fill + an optional
/// status pill); the panel sits on a recessed `HLSurface.tertiary` well inside
/// the existing `HLCard` — no glass on content.
struct InsightsTargetReferencePanel: View {
    let target: InsightsTargetsResponseDTO.TargetItem
    /// BP-only diastolic counterpart (stitched into the range string + average).
    var bpDiastolic: InsightsTargetsResponseDTO.BPDiastolic?
    /// I-0 Item 2 — the authoritative server "% in target" for this metric
    /// (today only BP carries one: `digest.bpPctInTarget`, the reading-pair-in-
    /// target share rendered by the top `BPStatusCard`). When set, the rail uses
    /// THIS number instead of the client `daysInRange30d / daysLogged30d`
    /// recompute, so the page never shows two divergent percentages (the
    /// operator's 29% top vs 25% bottom). `nil` for metrics with no server pct
    /// (non-BP targets keep the day-share rail — there is only one display, so
    /// no conflict).
    var serverPctInTarget: Int?
    /// W22-W22 (operator felt-refine #2) — whether the in-card "Adjust target
    /// range" affordance renders. `true` (default) keeps the still-live
    /// `ChartDetailScreen` exactly as it was (edit lives in the card). The
    /// web-mirror `InsightsMetricScreen` passes `false` — it hoists the edit to
    /// a header gear button next to the `✦` Coach action, so the bottom card
    /// reads as a pure read-only reference.
    var showsEditButton: Bool = true

    @State private var showEditor = false
    /// Refreshes the read-only targets payload after an edit so this panel —
    /// and the Insights tiles — repaint against the new band.
    @Environment(InsightsTargetsStore.self) private var targetsStore

    /// Editable threshold metrics behind this target type (empty → no editor).
    private var editableMetrics: [ThresholdMetric] {
        InsightsTargetBandEditorSheet.editableMetrics(forTargetType: target.type)
    }

    /// #32 — the current measured reference value(s) for the editor's faint
    /// "Currently: …" hint, keyed by `metric.rawValue`. Uses the 30-day
    /// average already on the target payload; BP fans the systolic + diastolic
    /// averages onto their respective threshold metrics.
    private var editorCurrentValues: [String: Double] {
        var values: [String: Double] = [:]
        for metric in editableMetrics {
            switch metric {
            case .bloodPressureDia:
                if let dia = bpDiastolic?.average30 { values[metric.rawValue] = dia }
            default:
                if let avg = target.average30 { values[metric.rawValue] = avg }
            }
        }
        return values
    }

    private var isBP: Bool {
        target.type == "BLOOD_PRESSURE"
    }

    /// #51 — the LOCALIZED editor-sheet title for this target. The server
    /// `target.label` is an English wire string (`InsightsTargetsDTO.swift:46`),
    /// so passing it surfaced "Blood Pressure" on a German device. We map the
    /// target `type` back to its `MetricKind` and use `displayName` (localized,
    /// `Measurement.swift:240`); falls back to the server label only if a new
    /// editable type ever lacks a kind mapping (it always has one today).
    private var localizedEditorTitle: String {
        InsightsTargetBandEditorSheet.titleKind(forTargetType: target.type)?.displayName ?? target.label
    }

    var body: some View {
        // ADAPTIVE: no target band → render nothing (no empty block).
        if let range = target.range {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                rail(range: range)
                averageLine
                if showConsistency {
                    ConsistencyStrip(buckets: target.consistency7d)
                }
                if showsEditButton, !editableMetrics.isEmpty { adjustButton }
            }
            // (e) Operator unify — the Ziel tile reads as the SAME canonical
            // content card as its neighbours (`HLCard` → `HLSurface.secondary`,
            // `HLSpace.lg` inset, `HLRadius.lg` corner). The prior recessed
            // `HLSurface.tertiary` well at `HLRadius.sm` made the panel look like
            // a different surface from the Assessment / Stats cards. Monochrome
            // doctrine: zero glass on content cards, no tint.
            .padding(HLSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HLSurface.secondary)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.lg, style: .continuous))
            .accessibilityElement(children: .contain)
            .sheet(isPresented: $showEditor) {
                Task { await targetsStore.refresh() }
            } content: {
                InsightsTargetBandEditorSheet(
                    metrics: editableMetrics,
                    titleText: localizedEditorTitle,
                    currentValues: editorCurrentValues
                )
                .hlSheetPresentation(.form)
            }
        }
    }

    // MARK: - Rows

    private var header: some View {
        // (c) Font unify — the "Target range" heading now matches the canonical
        // Insights section heading EXACTLY (`AssessmentCard` section title:
        // `.hlSubhead.weight(.semibold)` uppercase + 0.5 tracking) so the Ziel
        // panel's type scale reads identical to the rest of the metric page.
        HStack(spacing: HLSpace.sm) {
            Image(systemName: "target")
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
            // #57 — sentence-case Insights header language (icon + pill row,
            // so the typography matches InsightsSectionHeader inline).
            Text("Target range")
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.sm)
            classificationPill
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// The in-target rail — reuses the canonical `RangeBandRow` so this panel
    /// reads identically to the metric tile + the BP card.
    @ViewBuilder
    private func rail(range: InsightsTargetsResponseDTO.TargetItem.Range) -> some View {
        if let band = InsightsTargetTileGrid.rangeBand(
            range: range,
            insufficient: target.insufficientData,
            daysInRange30d: target.daysInRange30d,
            daysLogged30d: target.daysLogged30d,
            unit: railUnit,
            type: target.type
        ) {
            // I-0 Item 2 — when the server carries an authoritative pct (BP), the
            // rail trusts it so this number matches the top `BPStatusCard` (one
            // truth, no 29%-vs-25% split). The band's labels/unit stay; only the
            // pct is repointed to the server source.
            let serverBand = serverPctInTarget.map { pct in
                RangeBand(lowerLabel: band.lowerLabel, upperLabel: band.upperLabel, unit: band.unit, pctInRange: pct)
            } ?? band
            RangeBandRow(band: railBand(serverBand, range: range))
        } else {
            // No 30-day window yet — still show the target-range label so the
            // user reads the band even before consistency accrues. (c) Value text
            // routes to `.hlBody` so it reads at the same scale as the page body.
            Text(rangeLabel(range))
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
        }
    }

    /// Stitch the BP diastolic band into the rail's lower/upper labels so the
    /// rail reads the familiar `S/D` pair; non-BP metrics pass through.
    private func railBand(_ band: RangeBand, range: InsightsTargetsResponseDTO.TargetItem.Range) -> RangeBand {
        guard isBP, let dia = bpDiastolic?.range else { return band }
        return RangeBand(
            lowerLabel: "\(fmt(range.min))/\(fmt(dia.min))",
            upperLabel: "\(fmt(range.max))/\(fmt(dia.max))",
            unit: band.unit,
            pctInRange: band.pctInRange
        )
    }

    @ViewBuilder
    private var averageLine: some View {
        if let avgText = average30Text {
            // (c) Value text routes to `.hlBody` so the 30-day average reads at
            // the same scale as the rest of the metric page (not a `.hlCaption`).
            Text(avgText)
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
        }
    }

    private var adjustButton: some View {
        Button {
            showEditor = true
        } label: {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "slider.horizontal.3")
                    .font(.hlCaption.weight(.semibold))
                Text("Adjust target range")
                    .font(.hlCaption.weight(.semibold))
            }
            .foregroundStyle(HLText.primary)
            .padding(.top, HLSpace.xxs)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("insights.target.adjust.\(target.type)")
    }

    // MARK: - Derivations

    private var showConsistency: Bool {
        !target.insufficientData && !target.consistency7d.isEmpty
    }

    private var railUnit: String {
        isBP ? "mmHg" : target.unit
    }

    /// Status pill mirroring the web `TargetStatusPill` — the classification
    /// category coloured by signal (in-band green / near-band warn / else bad).
    /// Suppressed when the server emits no classification.
    @ViewBuilder
    private var classificationPill: some View {
        if let classification = target.classification, !classification.category.isEmpty {
            HLBadge(classification.category, tone: classificationTone)
        }
    }

    private var classificationTone: HLBadge.Tone {
        // Latest consistency bucket is the most honest "where are we now" signal;
        // fall back to neutral when the window is sparse.
        for bucket in target.consistency7d.reversed() {
            guard let bucket else { continue }
            switch bucket {
            case .inBand: return .success
            case .nearBand: return .warning
            case .outBand: return .critical
            }
        }
        return .neutral
    }

    private func rangeLabel(_ range: InsightsTargetsResponseDTO.TargetItem.Range) -> String {
        let unit = railUnit
        if isBP, let dia = bpDiastolic?.range {
            return String(
                format: String(localized: "Target: %@–%@ / %@–%@ %@"),
                fmt(range.min), fmt(range.max), fmt(dia.min), fmt(dia.max), unit
            )
        }
        if unit.isEmpty {
            return String(format: String(localized: "Target: %@–%@"), fmt(range.min), fmt(range.max))
        }
        return String(format: String(localized: "Target: %@–%@ %@"), fmt(range.min), fmt(range.max), unit)
    }

    /// "30-day average: 72.8 kg" (BP stitches `S/D`). nil when no average.
    private var average30Text: String? {
        guard let avg = target.average30, avg.isFinite else { return nil }
        let unit = railUnit
        let avgValue: String = if isBP, let diaAvg = bpDiastolic?.average30,
                                  let sys = Int(safeServer: avg), let dia = Int(safeServer: diaAvg)
        {
            // SWEEP (W-CRASHGUARD) — `average30` is a raw server `Double`; route
            // both operands through `Int(safeServer:)` so a non-finite OR
            // out-of-range value falls back to the fractional formatter instead
            // of trapping.
            "\(sys)/\(dia)"
        } else {
            avg.formatted(.number.precision(.fractionLength(0 ... 1)))
        }
        let prefix = String(localized: "30-day average:")
        return unit.isEmpty ? "\(prefix) \(avgValue)" : "\(prefix) \(avgValue) \(unit)"
    }

    /// Trim a trailing `.0` so whole-number bands read `120` not `120.0` —
    /// matches the web `fmt`.
    private func fmt(_ value: Double) -> String {
        // SWEEP (W-CRASHGUARD) — a finite whole renders as an Int; a non-finite
        // OR out-of-`Int.range` bound falls through to the fractional formatter
        // via the `Int(safeServer:)` nil-on-reject contract — never traps.
        if value == value.rounded(), let whole = Int(safeServer: value) {
            return String(whole)
        }
        return value.formatted(.number.precision(.fractionLength(1)))
    }
}
