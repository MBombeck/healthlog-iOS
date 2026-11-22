import Charts
import MapKit
import SwiftUI

/// Workout-Detail-Surface.
///
/// Extended with HR-time-series chart + GPS-route map.
///
/// Zeigt Stats des kanonischen Workouts (Dauer, Distanz, Avg/Max HR,
/// Kalorien, Quelle) plus, wenn vorhanden:
///   - HR-Chart (SwiftUI Charts) aus lokalen HealthKit-Samples zwischen
///     `startedAt` und `endedAt` — server ships avg/max/min but never
///     the per-second curve, so the chart is HK-direct.
///   - GPS-Route (MapKit) aus `WorkoutRoute.geometry` (GeoJSON LineString)
///     vom Server. Auto-zoom-to-fit per `MapCameraPosition`.
///
/// **Empty-Tolerance:** beide Sections rendern unsichtbar, wenn die
/// Daten fehlen (Withings hat kein GPS, manuelle Einträge keine HR-
/// Samples, HK-Auth verweigert → leere Series). Der Hero + StatsGrid
/// bleibt immer sichtbar, weil er sich aus dem Listen-DTO zieht.
struct WorkoutDetailView: View {
    /// Listen-Row als Cache-First Anker. Detail-Refresh überschreibt
    /// `store.detail`, der Body re-rendert dann mit den reicheren Feldern.
    let workout: WorkoutListEntryDTO

    @Environment(WorkoutsStore.self) private var store

    /// Aufgelöste Detail-Quelle: bevorzugt das frisch geladene
    /// `store.detail`, fällt auf die übergebene Liste-Row zurück solange
    /// der Detail-Round-Trip noch in-flight ist. So bleibt der Screen
    /// vom ersten Frame an befüllt.
    ///
    /// Internal (not `private`) so the enrichment sections in
    /// `WorkoutDetailView+Enrichment.swift` can read it across the extension
    /// boundary (Swift `private` is file-scoped).
    var resolved: WorkoutListEntryDTO {
        if let d = store.detail, d.id == workout.id {
            return d
        }
        return workout
    }

    var body: some View {
        HLPage {
            heroCard
            statsGrid
            metadataSection
            performanceSection
            hrZoneSection
            hrChartSection
            splitsSection
            sportContextSection
            routeMapSection
            sourceCard
        }
        .navigationTitle(WorkoutFormatter.sportTitle(resolved.sportType))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: workout.id) {
            await store.loadDetail(id: workout.id)
        }
    }

    /// The page's one key figure: the duration, the date under it. The sport
    /// is the navigation title and is not repeated here.
    private var heroCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                if let duration = WorkoutFormatter.duration(resolved.durationSec) {
                    // A stopwatch length ("1:02:03") has no `HLUnit`, so it
                    // takes the hero value role directly.
                    Text(duration)
                        .hlText(.heroValue)
                        .accessibilityLabel(Text("Dauer \(duration)"))
                }
                if let start = resolved.startedAt {
                    Text(HLDateFormat.dateTime(start, style: .complete))
                        .hlText(.pageSubtitle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: HLSpace.md),
            GridItem(.flexible(), spacing: HLSpace.md)
        ], spacing: HLSpace.md) {
            if let distance = resolved.distanceM, distance > 0 {
                let reading = WorkoutFormatter.distanceReading(metres: distance)
                StatTile(
                    label: "Distance",
                    value: reading.value,
                    unit: reading.unit,
                    fractionDigits: reading.fractionDigits,
                    icon: "ruler"
                )
            }
            if let kcal = resolved.activeEnergyKcal, kcal > 0 {
                StatTile(label: "workout.stat.calories", value: kcal, unit: .kilocalories, icon: "flame.fill")
            }
            if let avg = resolved.avgHr, avg > 0 {
                StatTile(label: "workout.stat.avgHeartRate", value: avg, unit: .beatsPerMinute, icon: "heart.fill")
            }
            if let max = resolved.maxHr, max > 0 {
                StatTile(label: "workout.stat.maxHeartRate", value: max, unit: .beatsPerMinute, icon: "bolt.heart.fill")
            }
            if let steps = resolved.stepCount, steps > 0 {
                // The label already says "steps"; the figure stands alone.
                StatTile(label: "Steps", value: Double(steps), unit: .plain, icon: "shoeprints.fill")
            }
            if let elev = resolved.elevationM, elev > 0 {
                StatTile(label: "Höhenmeter", value: elev, unit: .meters, icon: "mountain.2.fill")
            }
        }
    }

    // MARK: - Metadata section (W-B182 — WHOOP strain / altitude / quality)

    /// WHOOP (and any future provider) metadata the server stores in
    /// `Workout.metadata`: strain, altitude gain, recording quality. Renders
    /// only the fields that are present; the whole section disappears when there
    /// is no metadata (Apple Watch workouts typically carry none).
    @ViewBuilder
    private var metadataSection: some View {
        if let meta = resolved.metadata, Self.hasDisplayableMetadata(meta) {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: HLSpace.md),
                GridItem(.flexible(), spacing: HLSpace.md)
            ], spacing: HLSpace.md) {
                if let strain = meta.whoopWorkoutStrain, strain > 0 {
                    StatTile(label: "Strain", value: strain, unit: .plain, fractionDigits: 1 ... 1, icon: "bolt.fill")
                }
                if let altitude = meta.altitudeGainMeter, altitude > 0 {
                    StatTile(label: "Höhenmeter", value: altitude, unit: .meters, icon: "mountain.2.fill")
                }
                if let percent = Self.normalizedPercent(meta.percentRecorded) {
                    StatTile(label: "Aufgezeichnet", value: percent, unit: .percent, icon: "waveform.path.ecg")
                }
            }
        }
    }

    /// True iff at least one metadata field is worth rendering.
    /// `nonisolated` — pure decode helper, callable off the main actor (tests).
    nonisolated static func hasDisplayableMetadata(_ meta: WorkoutMetadataDTO) -> Bool {
        if let s = meta.whoopWorkoutStrain, s > 0 { return true }
        if let a = meta.altitudeGainMeter, a > 0 { return true }
        if normalizedPercent(meta.percentRecorded) != nil { return true }
        return false
    }

    /// WHOOP reports `percent_recorded` as a 0–1 fraction; some providers ship
    /// 0–100. Normalize to a 0–100 percentage, dropping nil / non-positive.
    nonisolated static func normalizedPercent(_ raw: Double?) -> Double? {
        guard let raw, raw > 0 else { return nil }
        return raw <= 1 ? raw * 100 : raw
    }

    // MARK: - HR-zone section

    /// Time-in-HR-zone bar. Prefers the server-resolved `zones` object (7.8 —
    /// covers both the WHOOP device path and the computed %HRmax `tanaka` fold);
    /// falls back to the raw `metadata.zoneDurations` WHOOP map for servers that
    /// predate the resolved field. Renders a horizontal stacked bar of zone
    /// proportions with a per-zone legend. Hidden when no zone data is present.
    @ViewBuilder
    private var hrZoneSection: some View {
        let zones = Self.resolvedZones(from: resolved)
        if !zones.isEmpty {
            HLCard("Heart-rate zones") {
                HRZoneBar(zones: zones)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - HR chart section

    @ViewBuilder
    private var hrChartSection: some View {
        // Only this workout's curve: the store is shared, and the curve it
        // holds may still be the previous workout's while this one loads.
        if let curve = store.hrCurve(for: workout.id), !curve.samples.isEmpty {
            HLCard("Heart rate") {
                HRChart(curve: curve, avg: resolved.avgHr, max: resolved.maxHr)
                    .frame(height: HLChartStyle.heightRegular)
                    .accessibilityLabel(Self.hrAccessibilityLabel(curve: curve))
            }
        }
    }

    /// Builds an a11y summary like "Heart rate, 412 data points, from 96 to
    /// 178 bpm." so VoiceOver users get a description instead of drowning in
    /// the chart axis. Catalog copy (was a fixed German sentence).
    static func hrAccessibilityLabel(samples: [WorkoutHRSample]) -> String {
        hrAccessibilityLabel(curve: WorkoutHRCurve(workoutID: "", samples: samples))
    }

    /// The summary over the FULL series: count, minimum and maximum come from
    /// every sample, not from the thinned copy the chart plots.
    static func hrAccessibilityLabel(curve: WorkoutHRCurve) -> String {
        guard !curve.samples.isEmpty else { return String(localized: "workout.hr.a11y.unavailable") }
        let min = Int(curve.minimumBPM.rounded())
        let max = Int(curve.maximumBPM.rounded())
        return String(localized: "workout.hr.a11y.summary \(curve.samples.count) \(min) \(max)")
    }

    // MARK: - Route map section

    @ViewBuilder
    private var routeMapSection: some View {
        if let coords = Self.routeCoordinates(from: resolved.route), coords.count >= 2 {
            HLCard("Distance") {
                RouteMap(coordinates: coords)
                    .frame(height: HLChartStyle.heightRegular)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
                    .accessibilityLabel(Self.routeAccessibilityLabel(count: coords.count))
            }
        }
    }

    /// Decodes a GeoJSON LineString into CLLocationCoordinate2D. GeoJSON
    /// stores `[lon, lat, alt?]` per Apple's convention; CoreLocation
    /// reads `(lat, lon)` so the swap happens once here at the boundary.
    static func routeCoordinates(from route: WorkoutRouteDTO?) -> [CLLocationCoordinate2D]? {
        guard let route else { return nil }
        let normalisedType = route.geometry.type.lowercased()
        // Be tolerant of casing; web sometimes ships "lineString" by
        // accident depending on the serializer.
        guard normalisedType == "linestring" else { return nil }
        let points: [CLLocationCoordinate2D] = route.geometry.coordinates.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
        return points.isEmpty ? nil : points
    }

    static func routeAccessibilityLabel(count: Int) -> String {
        String(localized: "workouts.detail.route.a11y \(count)")
    }

    // MARK: - Source card

    private var sourceCard: some View {
        HLCard("workouts.detail.source.title") {
            // The source only; the raw external ID was developer
            // information.
            HLFactRow("Data source", value: WorkoutDetailView.sourceLabel(resolved.source))
        }
    }

    /// Maps the wire `APPLE_HEALTH` / `WITHINGS` / `MANUAL` enum onto a
    /// human-readable label (brand names verbatim, "Manual" from the catalog).
    ///
    /// **#115 R3 (server v1.39.6)** — one table for every source surface:
    /// the brands, `EXTERNAL` ("External" / "Extern", a workout posted through
    /// the narrow `workouts:write` bridge token) and the neutral "Unknown
    /// source" for a token this build cannot name all come from
    /// `SourcePriorityRow.displayLabel(forSource:)`. Only `MANUAL` is resolved
    /// here, because this surface renders a plain `String` and the shared table
    /// hands back the catalogue key for `LocalizedStringKey` consumers.
    static func sourceLabel(_ raw: String) -> String {
        raw.uppercased() == "MANUAL"
            ? String(localized: "Manual")
            : SourcePriorityRow.displayLabel(forSource: raw)
    }
}

// MARK: - Stat tile

private struct StatTile: View {
    let label: LocalizedStringKey
    let value: Double
    let unit: HLUnit
    var fractionDigits: ClosedRange<Int> = 0 ... 0
    let icon: String

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: icon)
                        .font(.hlIcon(HLIconSize.rowAction))
                        .foregroundStyle(HLText.secondary)
                    Text(label)
                        .hlText(.tileLabel)
                }
                HLValueText(value, unit: unit, size: .compact, fractionDigits: fractionDigits)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - HR chart

/// Per-workout HR-time-series renderer. Reuses the single-accent
/// `HLChartTints.series` ramp so the chart reads as part of the
/// dashboard's tonal-mono surface. Avg + Max overlays use dashed
/// RuleMarks (Theme-2.0 §C — no AreaMarks, no solid fills).
struct HRChart: View {
    /// The thinned series the chart draws (at most `LTTB.seriesPlotThreshold`).
    let samples: [WorkoutHRSample]
    /// How many raw samples the curve has; the audio graph summary names it.
    let sampleCount: Int
    let avg: Double?
    let max: Double?

    init(curve: WorkoutHRCurve, avg: Double?, max: Double?) {
        samples = curve.plotted
        sampleCount = curve.samples.count
        self.avg = avg
        self.max = max
    }

    /// Canonical scrub-to-read (AUDIT-FINAL §H1): touch the trace to
    /// read bpm-at-time, identical to every other chart.
    @State private var selectedDate: Date?

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("HR", sample.bpm)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(HLChartTints.series)
                .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth, lineCap: .round, lineJoin: .round))
            }
            if let avg, avg > 0 {
                RuleMark(y: .value("Average", avg))
                    .foregroundStyle(HLChartTints.seriesLow)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("Ø \(Int(avg.rounded()))")
                            .font(.hlCaption.monospacedDigit())
                            .foregroundStyle(HLText.tertiary)
                    }
            }
            if let max, max > 0 {
                RuleMark(y: .value("Max", max))
                    .foregroundStyle(HLColor.statusWarn.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            // Canonical scrub overlay.
            HLChartScrubber.marks(
                selectedDate: selectedDate,
                in: samples,
                date: \.timestamp,
                value: \.bpm
            ) { sample in
                HLScrubCallout(
                    title: HLTimeFormat.time(sample.timestamp),
                    value: "\(Int(sample.bpm.rounded()))",
                    unit: "bpm"
                )
            }
        }
        // The shared axes: values on the left with the unit, the app's one
        // date-axis rule below (time of day for a session).
        .hlChartAxes(dates: samples.map(\.timestamp), unit: String(localized: "bpm"))
        .hlChartScrub($selectedDate) { date in
            guard let nearest = HLChartScrubber.nearest(to: date, in: samples, date: \.timestamp) else { return nil }
            return String(localized: "\(HLTimeFormat.time(nearest.timestamp)): \(Int(nearest.bpm.rounded())) bpm")
        }
        // ChartAXCoverageTests gate: every Chart must wire an
        // `AXChartDescriptor` so VoiceOver can audio-graph the series.
        .accessibilityChartDescriptor(HLChartDescriptor(makeAXDescriptor()))
    }

    private func makeAXDescriptor() -> AXChartDescriptor {
        let points = samples.map { sample in
            (
                x: sample.timestamp.timeIntervalSince1970,
                y: sample.bpm,
                xLabel: HLTimeFormat.time(sample.timestamp)
            )
        }
        let summary: String = {
            if samples.isEmpty {
                return String(localized: "No heart rate data")
            }
            let count = sampleCount
            if let avg, avg > 0 {
                return String(
                    localized: "workout.hr.chart.summary \(count) \(Int(avg.rounded()))"
                )
            }
            return String(localized: "\(count) heart rate values")
        }()
        return HLChartAX.singleSeries(
            title: String(localized: "Heart rate"),
            summary: summary,
            xAxisTitle: String(localized: "Time"),
            yAxisTitle: String(localized: "bpm"),
            seriesName: String(localized: "Heart rate"),
            points: points,
            yValueLabel: { v in "\(Int(v.rounded())) bpm" }
        )
    }
}

// MARK: - Route map

/// MapKit polyline view with auto-zoom-to-fit. iOS-18+ uses the
/// SwiftUI `Map(position:)` initialiser + `MapPolyline` content so the
/// view stays declarative.
struct RouteMap: View {
    let coordinates: [CLLocationCoordinate2D]

    @State private var camera: MapCameraPosition

    init(coordinates: [CLLocationCoordinate2D]) {
        self.coordinates = coordinates
        _camera = State(initialValue: .region(RouteMap.fittedRegion(for: coordinates)))
    }

    var body: some View {
        Map(position: $camera) {
            MapPolyline(coordinates: coordinates)
                .stroke(HLChartTints.series, lineWidth: 4)
            if let first = coordinates.first {
                Marker("workout.route.start", systemImage: "flag.fill", coordinate: first)
                    .tint(HLColor.statusOK)
            }
            if let last = coordinates.last, coordinates.count > 1 {
                Marker("workout.route.finish", systemImage: "flag.checkered", coordinate: last)
                    .tint(HLColor.statusBad)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .allowsHitTesting(true)
    }

    /// Computes the bounding box of the polyline and inflates it by 20%
    /// on each side so the line never kisses the frame edge. Falls back
    /// to a default-zoom city block when the polyline is degenerate.
    static func fittedRegion(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coords.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for c in coords {
            minLat = Swift.min(minLat, c.latitude)
            maxLat = Swift.max(maxLat, c.latitude)
            minLon = Swift.min(minLon, c.longitude)
            maxLon = Swift.max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        // 1.4 inflate factor → 20% padding on each side; minimum span
        // floor keeps degenerate "stand in one spot" routes from
        // collapsing to a single-point view.
        let latDelta = Swift.max((maxLat - minLat) * 1.4, 0.002)
        let lonDelta = Swift.max((maxLon - minLon) * 1.4, 0.002)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }
}
