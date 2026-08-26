import Charts
import SwiftUI

/// Sleep hypnogram detail (#124) — stage bands across one night, backed by
/// `GET /api/sleep/night?date=YYYY-MM-DD` (``SleepNightRepository``).
///
/// Layout, top→bottom:
///   1. Summary row — Zeit im Bett / Schlafenszeit / Wach / Aufwachen-Anzahl.
///   2. Hypnogram — stage bands across the night timeline (x = local time-of-
///      night). Bands are distinguished by GREYSCALE LIGHTNESS, never hue
///      (monochrome doctrine): deep = darkest, awake/in-bed = lightest, driven
///      by ``SleepStage/depthRank``.
///   3. Legend — the stages present, with their greyscale swatch.
///   4. Naps — a compact secondary list, surfaced separately from the main
///      band track (never merged in).
///
/// `main == nil` (no sleep data) → a clean empty state.
///
/// All instants in the DTO are UTC; this screen converts them to the user's
/// CURRENT local timezone for the axis + band positioning.
struct SleepHypnogramScreen: View {
    /// - Parameters:
    ///   - date: the local calendar day whose night to load; `nil` = server's
    ///     most-recent night (v0.14.3 E1 — the default entry passes `nil` so
    ///     the load never depends on a device-tz day-key that misses the
    ///     server's wake-day/server-tz night key).
    ///   - initialNight: render/preview seed — W-SLEEP (v0.14.8). When set, the
    ///     screen paints this night immediately; the `.task` load still runs
    ///     when a repository is available (app), and is a no-op in test/preview
    ///     hosts without an `appContainer`.
    init(date: Date? = nil, initialNight: SleepNightDTO? = nil) {
        _dayKey = State(initialValue: date.map(SleepNightRepository.dayKey))
        _night = State(initialValue: initialNight)
        _isLoading = State(initialValue: initialNight == nil)
        // Seed the navigation anchor so test/preview hosts (no repository →
        // no latest-load) still show the night header for the seeded night.
        _latestDayKey = State(initialValue: initialNight?.main.map {
            SleepNightRepository.utcDayKey(for: $0.night)
        })
    }

    @Environment(\.appContainer) private var appContainer

    /// The displayed wake-day key (`YYYY-MM-DD`), `nil` = server's latest
    /// night. ←/→ navigation rewrites this; `.task(id:)` reloads on change.
    @State private var dayKey: String?
    /// The LATEST night's day-key, resolved from the first no-date load —
    /// the right edge of the navigation (no browsing into the future).
    @State private var latestDayKey: String?
    @State private var night: SleepNightDTO?
    @State private var isLoading: Bool
    @State private var loadError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                nightNavigationHeader
                if isLoading, night == nil {
                    loadingState
                } else if let session = night?.main {
                    summaryRow(for: session)
                    hypnogramCard(for: session)
                    legend(for: session)
                    napsSection
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxxl)
        }
        .background(HLSurface.primary.ignoresSafeArea())
        .navigationTitle(Text("sleep.hypnogram.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: dayKey) { await load() }
    }

    // MARK: - Load (SWR per day-key — W-B180)

    private func load() async {
        guard let repo = appContainer?.sleepNightRepo else {
            isLoading = false
            return
        }
        loadError = false
        // Stale half: paint a previously seen night instantly (no spinner)…
        if let cached = await repo.cachedNight(forDayKey: dayKey) {
            night = cached
            isLoading = false
        } else {
            isLoading = true
            night = nil
        }
        defer { isLoading = false }
        // …revalidate half: always refresh against the server.
        do {
            let fresh = try await repo.night(forDayKey: dayKey)
            night = fresh
            if dayKey == nil, let main = fresh.main {
                latestDayKey = SleepNightRepository.utcDayKey(for: main.night)
            }
        } catch {
            if night == nil { loadError = true }
        }
    }

    // MARK: - Night navigation (W-B180)

    /// The day-key currently on screen — the explicit navigation target, or
    /// the latest night's resolved key while showing the default entry.
    private var displayedDayKey: String? {
        dayKey ?? latestDayKey
    }

    /// ←/→ between nights + the wake date, ABOVE the summary card. Hidden
    /// until a night anchor exists (default load still in flight / no sleep
    /// data at all).
    @ViewBuilder
    private var nightNavigationHeader: some View {
        if let key = displayedDayKey {
            SleepNightNavigationHeader(
                displayedKey: key,
                latestDayKey: latestDayKey,
                isLoading: isLoading
            ) { dayKey = $0 }
        }
    }

    // MARK: - Summary

    private func summaryRow(for session: SleepSession) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // Parity 4.7 — the night's LOCAL WAKE DAY, resolved through the
                // same ``SleepNightDay`` authority the navigation header above
                // uses. This line used to render `session.start` (the bedtime
                // INSTANT) in the device zone while the header printed the
                // UTC-anchored wake day, so the two could — and far from UTC
                // routinely did — name one night with two different dates.
                if let day = SleepNightDay.displayDate(for: session) {
                    Text(day, format: SleepNightDay.labelStyle())
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: HLSpace.md) {
                    summaryStat("sleep.summary.inBed", value: durationText(session.inBedMinutes))
                    summaryStat("sleep.summary.bedtime", value: bedtimeText(for: session))
                    summaryStat("sleep.summary.awake", value: durationText(session.awakeMinutes))
                    summaryStat("sleep.summary.awakenings", value: countText(session.awakenings))
                }
                SleepSourceDiscrepancyNote(session: session)
            }
        }
    }

    private func summaryStat(_ titleKey: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(titleKey)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            Text(value)
                .font(.hlMetric(.title3))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Hypnogram

    private func hypnogramCard(for session: SleepSession) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            InsightsSectionHeader("sleep.hypnogram.section")
            HLCard {
                hypnogramBody(for: session)
            }
        }
    }

    /// Picks the band rendering for the night, server-flag-first (W-SLEEPHYP).
    ///
    /// **Correctness RCA (server 1.17.1):** a `reconstructed` night carries NO
    /// measured onsets. The ingest builder (`reconstruct-timeline.ts`) lays the
    /// stages back-to-back from sleep onset in a FIXED physiological order, one
    /// segment per stage — so its "timeline" is ~4 ordered blocks that never
    /// alternate the way a real night does. Drawing that as a lane chart looks
    /// like a real hypnogram and misleads (the operator finding). We therefore
    /// render `reconstructed` nights as the honest proportional distribution
    /// band + an "approximate" caption — never a fake timeline.
    ///
    /// - `reconstructed == true` (WHOOP / Polar, any 1.16/1.17 server): no real
    ///   onsets → distribution band + approximate caption.
    /// - `reconstructed == false` (Apple Health / Withings / Fitbit / Oura):
    ///   measured per-segment series with genuine alternation → real timeline.
    ///   Such a night is NOT summary-shaped, so the heuristic leaves it alone.
    /// - Older server (flag absent → `false`) that still emits a totals-only /
    ///   right-stacked legacy WHOOP night: the
    ///   ``SleepHypnogramLayout/isSummaryShaped`` heuristic catches it and the
    ///   distribution band stands in for the missing timeline.
    @ViewBuilder
    private func hypnogramBody(for session: SleepSession) -> some View {
        if session.segments.isEmpty {
            Text("sleep.hypnogram.noSegments")
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if session.reconstructed {
            // Server-reconstructed (WHOOP / Polar): the segments are an ordered
            // composition of per-stage TOTALS, not measured onsets. Show the
            // honest distribution band + an approximate caption — never the
            // fake lane timeline.
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                summaryDistribution(for: session)
                Label("sleep.hypnogram.reconstructed", systemImage: "wand.and.stars")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .labelStyle(.titleAndIcon)
            }
        } else if SleepHypnogramLayout.isSummaryShaped(session.segments)
            || session.end <= session.start
        {
            // Older-server fallback — summary-shaped night (legacy WHOOP): the
            // source delivers per-stage TOTALS that all share one end instant
            // (`measuredAt = sleep end` per stage), so true von-bis positions
            // don't exist. Rendering those literally is the "alle Balken kleben
            // rechts" artefact — show an honest proportional distribution.
            summaryDistribution(for: session)
        } else {
            // Measured hypnogram (Apple Health / Withings / Fitbit / Oura) —
            // real, alternating onsets, render as-is with no approximate caption.
            hypnogramChart(for: session)
                .frame(height: 200)
                .accessibilityLabel(Text("sleep.hypnogram.a11y"))
                // A11Y (audit-v0162 §5) — a proper chart descriptor so VoiceOver
                // reads each sleep phase + its clock span (via the audio-graph
                // rotor), not just the one flat "Hypnogramm der Schlafphasen"
                // phrase the lone `.accessibilityLabel` used to be. Reuses the
                // shared `HLChartDescriptor` representable (AXChartHelpers).
                .accessibilityChartDescriptor(
                    HLChartDescriptor(SleepHypnogramAX.descriptor(for: session))
                )
        }
    }

    @ViewBuilder
    private func hypnogramChart(for session: SleepSession) -> some View {
        // Apple-Health-Stil (W-B180): the x axis IS the night — pinned to the
        // bed span (session start … end). The TOP lane shows "Im Bett" as the
        // whole span; the stage lanes below carry the segments at their REAL
        // von-bis positions, ordered by depth so DEEP sits at the bottom.
        // Only stages present in the night get a lane.
        let segments = SleepHypnogramLayout.positionedSegments(for: session)
        let lanes = orderedStages(in: segments)
        let laneCount = lanes.count + 1 // + the "Im Bett" top lane
        Chart {
            // Top lane — the full in-bed span, painted from the session
            // bounds (not from IN_BED segments, which may be partial).
            RectangleMark(
                xStart: .value("Start", session.start),
                xEnd: .value("End", session.end),
                yStart: .value("LaneStart", Double(laneCount - 1)),
                yEnd: .value("LaneEnd", Double(laneCount))
            )
            .foregroundStyle(color(for: .inBed))

            ForEach(segments) { segment in
                RectangleMark(
                    xStart: .value("Start", segment.start),
                    xEnd: .value("End", segment.end),
                    yStart: .value("LaneStart", lanePosition(for: segment.stage, in: lanes)),
                    yEnd: .value("LaneEnd", lanePosition(for: segment.stage, in: lanes) + 1)
                )
                // Each stage carries its muted-pastel category color so the
                // phases are distinguishable at a glance (W-SLEEPHYP).
                .foregroundStyle(color(for: segment.stage))
            }
        }
        .chartXScale(domain: session.start ... session.end)
        .chartYScale(domain: 0 ... Double(laneCount))
        .chartYAxis {
            AxisMarks(values: Array(0 ..< laneCount).map { Double($0) + 0.5 }) { value in
                if let raw = value.as(Double.self) {
                    let index = Int(raw)
                    if index >= 0, index < laneCount {
                        AxisValueLabel {
                            Text(laneLabel(at: index, lanes: lanes))
                                .font(.hlCaption2)
                                .foregroundStyle(HLText.secondary)
                        }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(HLText.primary.opacity(HLChartGrid.lineOpacity))
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.hlCaption2)
                    .foregroundStyle(HLText.secondary)
            }
        }
    }

    /// Lane label, bottom→top: the deep-most stage at index 0, the shallow
    /// stages above, "Im Bett" as the synthetic top lane.
    private func laneLabel(at index: Int, lanes: [SleepStage]) -> LocalizedStringResource {
        guard index < lanes.count else { return SleepStage.inBed.displayKey }
        return lanes[lanes.count - 1 - index].displayKey
    }

    // MARK: - Summary-shaped fallback (W-B180)

    /// Proportional per-stage distribution for nights whose source only
    /// delivers stage totals (no within-night timing): one monochrome band,
    /// deep→shallow left→right, plus an explanatory footnote. The legend
    /// below the card carries the exact minutes.
    private func summaryDistribution(for session: SleepSession) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(SleepHypnogramLayout.distribution(for: session), id: \.stage) { item in
                        Rectangle()
                            .fill(color(for: item.stage))
                            .frame(width: max(1, geo.size.width * item.fraction))
                    }
                }
            }
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm))
            .accessibilityHidden(true) // legend + footnote carry the values
            Text("sleep.hypnogram.summaryOnly")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
        }
    }

    // MARK: - Legend

    @ViewBuilder
    private func legend(for session: SleepSession) -> some View {
        let stages = orderedStages(in: session.segments).reversed()
        if !stages.isEmpty {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    ForEach(Array(stages), id: \.self) { stage in
                        HStack(spacing: HLSpace.sm) {
                            RoundedRectangle(cornerRadius: HLRadius.xs)
                                .fill(color(for: stage))
                                .frame(width: 16, height: 16)
                            Text(stage.displayKey)
                                .font(.hlFootnote)
                                .foregroundStyle(HLText.primary)
                            Spacer()
                            if let minutes = session.stages[stage] {
                                Text(durationText(minutes))
                                    .font(.hlFootnote)
                                    .foregroundStyle(HLText.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Naps (secondary section)

    @ViewBuilder
    private var napsSection: some View {
        if let naps = night?.naps, !naps.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("sleep.naps.section")
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        ForEach(Array(naps.enumerated()), id: \.offset) { _, nap in
                            HStack {
                                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                                    Text(napTimeRange(for: nap))
                                        .font(.hlFootnote)
                                        .foregroundStyle(HLText.primary)
                                        .monospacedDigit()
                                    Text("sleep.naps.label")
                                        .font(.hlCaption)
                                        .foregroundStyle(HLText.secondary)
                                }
                                Spacer()
                                Text(durationText(nap.asleepMinutes ?? nap.inBedMinutes))
                                    .font(.hlMetric(.callout))
                                    .foregroundStyle(HLText.primary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        HLCard {
            HStack(spacing: HLSpace.sm) {
                ProgressView()
                Text("sleep.hypnogram.loading")
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, HLSpace.lg)
        }
    }

    private var emptyState: some View {
        HLCard {
            VStack(spacing: HLSpace.sm) {
                Image(systemName: "moon.zzz")
                    .font(.hlTitle1)
                    .foregroundStyle(HLText.tertiary)
                Text(loadError ? "sleep.hypnogram.error" : "sleep.hypnogram.empty")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLSpace.xl)
        }
    }

    // MARK: - Phase palette (W-SLEEPHYP — muted-pastel category colors)

    /// The phase color for a stage — a fixed muted PASTEL spectrum tone per
    /// category (Wach / REM / Kern / Tief, plus the Im-Bett container + the
    /// coarse ASLEEP bucket). A lightness-only greyscale ramp left the phases
    /// indistinguishable (operator finding); these are the sanctioned category
    /// colors, each an adaptive asset-catalog color so light + dark both stay
    /// legible. Hue carries MEANING only as a phase legend, backed by the text
    /// legend below the card + per-stage a11y labels.
    func color(for stage: SleepStage) -> Color {
        switch stage {
        case .awake: HLColor.sleepStageAwake
        case .inBed: HLColor.sleepStageInBed
        case .asleep: HLColor.sleepStageAsleep
        case .rem: HLColor.sleepStageREM
        case .core: HLColor.sleepStageCore
        case .deep: HLColor.sleepStageDeep
        }
    }

    // MARK: - Lane helpers

    /// Stages present in the night, ordered shallow→deep by ``depthRank``.
    private func orderedStages(in segments: [SleepSegment]) -> [SleepStage] {
        let present = Set(segments.map(\.stage))
        return SleepStage.allCases
            .filter { present.contains($0) }
            .sorted { $0.depthRank < $1.depthRank }
    }

    /// Vertical lane index for a stage — deepest stages sit at the BOTTOM of the
    /// chart (lane 0), shallowest at the top, matching Apple Health.
    private func lanePosition(for stage: SleepStage, in lanes: [SleepStage]) -> Double {
        guard let idx = lanes.firstIndex(of: stage) else { return 0 }
        // `lanes` is shallow→deep; invert so deep → lane 0 (bottom).
        return Double(lanes.count - 1 - idx)
    }

    // MARK: - Formatting

    /// Parity 4.7 — delegates to the shared ``SleepDurationFormat`` so the
    /// hypnogram, the rhythm cards and the composition chart all spell a
    /// duration identically.
    private func durationText(_ minutes: Int?) -> String {
        SleepDurationFormat.hoursMinutes(minutes)
    }

    private func countText(_ count: Int?) -> String {
        guard let count else { return "—" }
        return "\(count)"
    }

    private func bedtimeText(for session: SleepSession) -> String {
        session.start.formatted(.dateTime.hour().minute())
    }

    private func napTimeRange(for nap: SleepSession) -> String {
        let start = nap.start.formatted(.dateTime.hour().minute())
        let end = nap.end.formatted(.dateTime.hour().minute())
        return "\(start) – \(end)"
    }
}
