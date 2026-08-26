import Charts
import MapKit
import SwiftUI

/// v0.5.3-F3 — Workout-Detail-Surface.
///
/// v0.5.4-SP5 — extended with HR-time-series chart + GPS-route map.
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

    /// Audit-01 H3 — the hero duration keeps its 36pt visual weight at the
    /// default setting but now scales with Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var durationSize: CGFloat = 36

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
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                heroCard
                statsGrid
                metadataSection
                hrZoneSection
                hrChartSection
                splitsSection
                sportContextSection
                routeMapSection
                sourceCard
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.vertical, HLSpace.lg)
        }
        .hlScreenBackground()
        .hlScrollEdgeSoft()
        .navigationTitle(LocalizedStringKey(WorkoutFormatter.sportTitle(resolved.sportType)))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: workout.id) {
            await store.loadDetail(id: workout.id)
        }
    }

    private var heroCard: some View {
        HLCard(style: .elevated) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                if let start = resolved.startedAt {
                    Text(Self.heroDateFormatter.string(from: start))
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                }
                Text(WorkoutFormatter.sportTitle(resolved.sportType))
                    .font(.hlTitle1)
                    .foregroundStyle(HLText.primary)
                if let duration = WorkoutFormatter.duration(resolved.durationSec) {
                    Text(duration)
                        .font(.hlMetric(durationSize))
                        .foregroundStyle(HLText.primary)
                        .accessibilityLabel(Text("Dauer \(duration)"))
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
                StatTile(
                    label: "Distance",
                    value: WorkoutFormatter.distanceLabel(metres: distance),
                    icon: "ruler"
                )
            }
            if let kcal = resolved.activeEnergyKcal, kcal > 0 {
                StatTile(
                    label: "Kalorien",
                    value: "\(Int(kcal.rounded())) kcal",
                    icon: "flame.fill"
                )
            }
            if let avg = resolved.avgHr, avg > 0 {
                StatTile(
                    label: "Ø Puls",
                    value: "\(Int(avg.rounded())) bpm",
                    icon: "heart.fill"
                )
            }
            if let max = resolved.maxHr, max > 0 {
                StatTile(
                    label: "Max Puls",
                    value: "\(Int(max.rounded())) bpm",
                    icon: "bolt.heart.fill"
                )
            }
            if let steps = resolved.stepCount, steps > 0 {
                StatTile(
                    label: "Steps",
                    value: "\(steps)",
                    icon: "shoeprints.fill"
                )
            }
            if let elev = resolved.elevationM, elev > 0 {
                StatTile(
                    label: "Höhenmeter",
                    value: "\(Int(elev.rounded())) m",
                    icon: "mountain.2.fill"
                )
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
                    StatTile(
                        label: "Strain",
                        value: HLNumberFormat.decimal(strain, fractionDigits: 1),
                        icon: "bolt.fill"
                    )
                }
                if let altitude = meta.altitudeGainMeter, altitude > 0 {
                    StatTile(
                        label: "Höhenmeter",
                        value: "\(Int(altitude.rounded())) m",
                        icon: "mountain.2.fill"
                    )
                }
                if let percent = Self.normalizedPercent(meta.percentRecorded) {
                    StatTile(
                        label: "Aufgezeichnet",
                        value: HLNumberFormat.percent(Int(percent.rounded())),
                        icon: "waveform.path.ecg"
                    )
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

    // MARK: - HR-zone section (W-B182)

    /// Time-in-HR-zone bar. Prefers the server-resolved `zones` object (7.8 —
    /// covers both the WHOOP device path and the computed %HRmax `tanaka` fold);
    /// falls back to the raw `metadata.zoneDurations` WHOOP map for servers that
    /// predate the resolved field. Renders a horizontal stacked bar of zone
    /// proportions with a per-zone legend. Hidden when no zone data is present.
    @ViewBuilder
    private var hrZoneSection: some View {
        let zones = Self.resolvedZones(from: resolved)
        if !zones.isEmpty {
            HLCard(style: .elevated) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("Heart-rate zones")
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.primary)
                    HRZoneBar(zones: zones)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - HR chart section (v0.5.4-SP5)

    @ViewBuilder
    private var hrChartSection: some View {
        if let series = store.detailHRSeries, !series.isEmpty {
            HLCard(style: .elevated) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("Heart rate")
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.primary)
                    HRChart(samples: series, avg: resolved.avgHr, max: resolved.maxHr)
                        .frame(height: 180)
                        .accessibilityLabel(Self.hrAccessibilityLabel(samples: series))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Builds an a11y summary like "Herzfrequenz, 412 Messpunkte, von 96
    /// bis 178 bpm." so VoiceOver users get a description instead of
    /// drowning in the chart axis.
    static func hrAccessibilityLabel(samples: [WorkoutHRSample]) -> String {
        guard !samples.isEmpty else { return "Herzfrequenz nicht verfügbar" }
        let min = Int((samples.map(\.bpm).min() ?? 0).rounded())
        let max = Int((samples.map(\.bpm).max() ?? 0).rounded())
        return "Herzfrequenz, \(samples.count) Messpunkte, von \(min) bis \(max) bpm."
    }

    // MARK: - Route map section (v0.5.4-SP5)

    @ViewBuilder
    private var routeMapSection: some View {
        if let coords = Self.routeCoordinates(from: resolved.route), coords.count >= 2 {
            HLCard(style: .elevated) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("Distance")
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.primary)
                    RouteMap(coordinates: coords)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
                        .accessibilityLabel(Self.routeAccessibilityLabel(count: coords.count))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        "Streckenkarte, \(count) GPS-Punkte."
    }

    // MARK: - Source card

    private var sourceCard: some View {
        HLSettingsCard(
            icon: "antenna.radiowaves.left.and.right",
            title: "Quelle"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack {
                    Text("Data source")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                    Spacer()
                    Text(WorkoutDetailView.sourceLabel(resolved.source))
                        .font(.hlBody.weight(.medium))
                        .foregroundStyle(HLText.primary)
                }
                if let external = resolved.externalId {
                    HStack(alignment: .top) {
                        Text("External ID")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                        Spacer()
                        Text(external)
                            .font(.hlCaption.monospacedDigit())
                            .foregroundStyle(HLText.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    /// Maps the wire `APPLE_HEALTH` / `WITHINGS` / `MANUAL` enum onto a
    /// human-readable German label.
    static func sourceLabel(_ raw: String) -> String {
        switch raw.uppercased() {
        case "APPLE_HEALTH": "Apple Health"
        case "WITHINGS": "Withings"
        case "MANUAL": "Manuell"
        case "IMPORT": "Import"
        // v0.14.8 W-WORKOUT-E2E — the server ingests workouts from WHOOP
        // (v1.11.0) + Fitbit (v1.12.0); brand spellings, not `.capitalized`.
        case "WHOOP": "WHOOP"
        case "FITBIT": "Fitbit"
        // #42 (server v1.27.x) — the Google Health API provider (Fitbit +
        // Pixel Watch). Distinct from the classic `FITBIT` Web-API source; the
        // wire token `GOOGLE_HEALTH` would otherwise fall through to
        // `.capitalized` → "Google_health".
        case "GOOGLE_HEALTH": "Google Health"
        // #46 (server v1.28.11) — workout ingest also carries Strava / Oura /
        // Polar / Nightscout provenance; pin the brand spellings explicitly.
        case "STRAVA": "Strava"
        case "OURA": "Oura"
        case "POLAR": "Polar"
        case "NIGHTSCOUT": "Nightscout"
        default: raw.capitalized
        }
    }

    private static let heroDateFormatter: DateFormatter = {
        let f = DateFormatter()
        // Build 8 (8.6): follow the running UI locale instead of a hard `de_DE`
        // pin, so an English build renders an English full date instead of a
        // forced-German one. The string carries no German prefix, so no catalog
        // key is needed.
        f.locale = Locale.current
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Stat tile

private struct StatTile: View {
    let label: LocalizedStringKey
    let value: String
    let icon: String

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: icon)
                        .font(.hlIcon(HLIconSize.rowAction))
                        .foregroundStyle(HLText.secondary)
                    Text(label)
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                }
                Text(value)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
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
    let samples: [WorkoutHRSample]
    let avg: Double?
    let max: Double?

    /// v0.11 — canonical scrub-to-read (AUDIT-FINAL §H1): touch the trace to
    /// read bpm-at-time, identical to every other chart.
    @State private var selectedDate: Date?

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Zeit", sample.timestamp),
                    y: .value("HR", sample.bpm)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(HLChartTints.series)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            if let avg, avg > 0 {
                RuleMark(y: .value("Ø", avg))
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
                    title: sample.timestamp.formatted(.dateTime.hour().minute()),
                    value: "\(Int(sample.bpm.rounded()))",
                    unit: "bpm"
                )
            }
        }
        // M2 — route the axis grid through the canonical `HLChartGrid` tokens
        // (was `HLColor.separator` opacities) so the workout HR chart's axes
        // match every other chart's hairline-mono treatment.
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                    .foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                AxisTick().foregroundStyle(HLText.tertiary)
                AxisValueLabel()
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                    .foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
        }
        .hlChartScrub($selectedDate) { date in
            guard let nearest = HLChartScrubber.nearest(to: date, in: samples, date: \.timestamp) else { return nil }
            return String(localized: "\(nearest.timestamp.formatted(.dateTime.hour().minute())): \(Int(nearest.bpm.rounded())) bpm")
        }
        // v0.5.4 — ChartAXCoverageTests gate: every Chart must wire an
        // `AXChartDescriptor` so VoiceOver can audio-graph the series.
        .accessibilityChartDescriptor(HLChartDescriptor(makeAXDescriptor()))
    }

    private func makeAXDescriptor() -> AXChartDescriptor {
        let timeFormatter = Date.FormatStyle(date: .omitted, time: .shortened)
        let points = samples.map { sample in
            (
                x: sample.timestamp.timeIntervalSince1970,
                y: sample.bpm,
                xLabel: timeFormatter.format(sample.timestamp)
            )
        }
        let summary: String = {
            if samples.isEmpty {
                return String(localized: "No heart rate data")
            }
            let count = samples.count
            if let avg, avg > 0 {
                return String(
                    localized: "\(count) Herzfrequenz-Werte · Ø \(Int(avg.rounded())) bpm"
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
                Marker("Start", systemImage: "flag.fill", coordinate: first)
                    .tint(HLColor.statusOK)
            }
            if let last = coordinates.last, coordinates.count > 1 {
                Marker("Ziel", systemImage: "flag.checkered", coordinate: last)
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
