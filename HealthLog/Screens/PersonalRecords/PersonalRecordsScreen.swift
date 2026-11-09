import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// v0.5.5.6 POLISH-PR — Persönliche Rekorde, complete redesign.
///
/// Operator brief (2026-05-21): *"Persönliche Rekorde sieht noch
/// richtig furchtbar aus. Das funktioniert überhaupt nicht. Überleg
/// doch mal, was du da erwarten würdest."* — full rebuild from
/// `PersonalRecordsScreen.swift` v0.5.3-F3 (which was a flat sectioned
/// list with bare HLCards) to an Apple-Fitness-Award-styled hero +
/// 2-col grid + streak rail + milestones strip surface.
///
/// **Information architecture (top → bottom):**
/// 1. `HeroRecordCard` — 280pt gradient hero, picks the most
///    impressive record via `PersonalRecordsStore.heroRecord`.
/// 2. Segmented `Picker` — "Allzeit / Dieses Jahr / Dieser Monat /
///    Diese Woche" — binds to `store.selectedBucket`.
/// 3. 2-col `LazyVGrid` of `RecordCard`s — kind-tinted glyph + value
///    + mini sparkline w/ peak marker + delta chip.
/// 4. Streak rail — horizontal scroll of capsule pills for streak-
///    class records (longest 10k-step streak etc.).
/// 5. Milestones strip — small Apple-Award stickers ("100 Tage Daten").
/// 6. Empty state — humane copy with a 56pt rosette glyph.
///
/// **Celebration moment:** when a new top-rank record lands (driven
/// by `MeasurementsStore.commit(_:)` upstream), the screen overlays
/// `CelebrationOverlay` with Canvas confetti + triple haptic. The
/// overlay auto-dismisses after 2.5 s, but the operator can tap it to
/// share via `ImageRenderer` → `UIActivityViewController`.
///
/// **Server contract preserved:** the screen still reads
/// `store.records`/`store.enrichedRecords`; the v0.5.3-F3 wire
/// contract is untouched. When the server records arrive (v1.4.26
/// detection worker), every cell repaints with the authoritative
/// data without an iOS release.
struct PersonalRecordsScreen: View {
    @Environment(PersonalRecordsStore.self) private var store
    /// #115 P2 — the share image renders in the account's unit.
    @Environment(\.unitPreferences) private var unitPreferences
    /// R4 §3.1 — Personal Records are server-derived (no on-device store). When
    /// no backend is available, render `HLCloudDerivedPlaceholder` instead of an
    /// empty screen + doomed `/api/personal-records` fetch. `hasServer` is always
    /// `true` in paired mode → inert for paired users.
    @Environment(BackendAvailability.self) private var backend
    /// v0.11 W3 — shared "Server verbinden" CTA path for the placeholder.
    @Environment(AuthStore.self) private var authStore
    /// QoL-A2 (Felt-craft #5) — gate the celebration-dismiss fade on reduce-motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedShareRecord: PersonalRecord?
    @State private var celebrationRecord: PersonalRecord?
    /// v0.5.5.7 RECONCILE-COMPARE — surfaces the
    /// `BenchmarkSourceSheet` when the operator taps a comparison
    /// band. Reset to `nil` on dismiss; `(record, benchmark)` tuple
    /// stays paired so the sheet knows which metric label + source
    /// to surface.
    @State private var selectedBenchmark: BenchmarkSelection?

    var body: some View {
        Group {
            if !backend.canShowPersonalRecords {
                ScrollView {
                    HLCloudDerivedPlaceholder(
                        variant: .hero,
                        surfaceName: String(localized: "your Personal Records"),
                        onConnect: { authStore.beginServerPairing() }
                    )
                    .padding(HLSpace.lg)
                }
            } else if store.enrichedRecords.isEmpty, !store.isLoading, store.error == nil {
                emptyState
            } else {
                content
            }
        }
        .hlScreenBackground()
        .hlScrollEdgeSoft()
        .navigationTitle(LocalizedStringKey(Layout.navigationTitle))
        .task { if backend.canShowPersonalRecords { await store.revalidateIfStale() } }
        // W-B184 — WHOOP-style pull-to-refresh (custom glyph + checkmark + one
        // success haptic; the handshake driving the checkmark runs in the modifier).
        .hlPullToRefresh { if backend.canShowPersonalRecords { await store.refresh() } }
        // K1 — the banner below still presents as this overlay; this
        // reserves its height at the top so it covers nothing (H2).
        .hlReserveErrorBannerSpace(store.error)
        .overlay(alignment: .top) {
            ErrorBanner(error: store.error) {
                Task { await store.refresh() }
            }
        }
        #if canImport(UIKit)
        .sheet(item: $selectedShareRecord) { record in
            if let image = RecordShareImage.render(record, units: unitPreferences) {
                RecordShareSheet(image: image) {
                    selectedShareRecord = nil
                }
                .ignoresSafeArea()
            }
        }
        #endif
        .overlay {
            if let celebrationRecord {
                CelebrationOverlay(record: celebrationRecord) {
                    withAnimation(reduceMotion ? nil : HLMotion.smooth) {
                        self.celebrationRecord = nil
                    }
                }
            }
        }
        .sheet(item: $selectedBenchmark) { selection in
            BenchmarkSourceSheet(
                metricLabel: selection.metricLabel,
                kind: selection.record.kind ?? .unknown,
                band: selection.band
            ) {
                selectedBenchmark = nil
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        @Bindable var bindableStore = store

        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.xl) {
                if let hero = store.heroRecord {
                    HeroRecordCard(record: hero) { record in
                        selectedShareRecord = record
                    }
                    .padding(.horizontal, HLSpace.lg)
                }

                // 1.4 B2 — the picker offers only ranges that hold a record, so
                // no range opens on an empty grid with an apology under it.
                let buckets = Self.availableBuckets(store.enrichedRecords)
                if buckets.count > 1 {
                    bucketPicker(buckets, selection: $bindableStore.selectedBucket)
                        .padding(.horizontal, HLSpace.lg)
                }

                gridSection

                if !store.streakRecords.isEmpty {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        HLSectionLabel(LocalizedStringKey(Layout.streaksHeader))
                            .padding(.horizontal, HLSpace.lg)
                        // 1.4 B2 — no rest-mode paragraph here: the note
                        // belongs to Today and the recovery page, not between
                        // a heading and its rail.
                        StreakRail(streaks: store.streakRecords) { record in
                            selectedShareRecord = record
                        }
                    }
                }

                let milestones = Milestone.synthesise(from: store.enrichedRecords)
                if !milestones.isEmpty {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        HLSectionLabel(LocalizedStringKey(Layout.milestonesHeader))
                            .padding(.horizontal, HLSpace.lg)
                        MilestoneStrip(milestones: milestones)
                    }
                }

                comparisonSection
            }
            .padding(.top, HLSpace.md)
            .padding(.bottom, HLSpace.xxxl)
        }
        .onChange(of: Self.availableBuckets(store.enrichedRecords), initial: true) { _, buckets in
            // A range that lost its last record (or never had one) hands the
            // selection to the narrowest range that has something.
            if !buckets.contains(store.selectedBucket), let first = buckets.first {
                store.selectedBucket = first
            }
        }
    }

    /// v0.5.5.7 RECONCILE-COMPARE — comparison-band section. #135 —
    /// renders one `ComparisonBand` per visible record whose row carries the
    /// server's `benchmark` (v1.43). Deduplicated by `kind` so several records
    /// of the same kind surface a single band. Nothing on an older server.
    @ViewBuilder
    private var comparisonSection: some View {
        let pairs = comparisonPairs
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel(LocalizedStringKey(Layout.comparisonHeader))
                    .padding(.horizontal, HLSpace.lg)
                VStack(spacing: HLSpace.sm) {
                    ForEach(pairs, id: \.record.id) { pair in
                        ComparisonBand(record: pair.record, band: pair.band) {
                            selectedBenchmark = BenchmarkSelection(record: pair.record, band: pair.band)
                        }
                    }
                }
                .padding(.horizontal, HLSpace.lg)
            }
        }
    }

    /// Returns the unique-by-kind `(record, band)` pairs for the comparison
    /// section. Order matches `store.visibleRecords` so the section feels
    /// stable across re-renders.
    private var comparisonPairs: [(record: PersonalRecord, band: RecordBenchmarkBand)] {
        Self.comparisonPairs(store.visibleRecords, units: unitPreferences)
    }

    /// Pure: the first record per kind whose server benchmark the app can draw.
    static func comparisonPairs(
        _ records: [PersonalRecord],
        units: UnitPreferences
    ) -> [(record: PersonalRecord, band: RecordBenchmarkBand)] {
        var seenKinds: Set<MetricKind> = []
        var out: [(record: PersonalRecord, band: RecordBenchmarkBand)] = []
        for record in records {
            guard let kind = record.kind, !seenKinds.contains(kind) else { continue }
            guard let band = RecordBenchmarkBand(record: record.base, units: units) else { continue }
            seenKinds.insert(kind)
            out.append((record, band))
        }
        return out
    }

    @ViewBuilder
    private var gridSection: some View {
        let visible = Self.gridRecords(store.visibleRecords)
        if !visible.isEmpty {
            // POLISH-B (SHOTS F-REC-1) — two cards a row up to XXXL; from the
            // accessibility sizes on one card a row, so names, times and the
            // "new record" chip keep their whole words.
            LazyVGrid(
                columns: Self.gridColumns(dynamicTypeSize),
                spacing: HLSpace.md
            ) {
                ForEach(visible) { record in
                    RecordCard(record: record) { selected in
                        selectedShareRecord = selected
                    }
                }
            }
            .padding(.horizontal, HLSpace.lg)
        }
    }

    /// Two flexible columns, one from the accessibility sizes on.
    nonisolated static func gridColumns(_ size: DynamicTypeSize) -> [GridItem] {
        let count = size.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: HLSpace.md), count: count)
    }

    /// Streak records render in the rail instead of the grid.
    nonisolated static func gridRecords(_ records: [PersonalRecord]) -> [PersonalRecord] {
        records.filter { record in
            let slot = (record.base.metricSlot ?? "").lowercased()
            return !(slot.contains("serie") || slot.contains("streak") || slot.contains("연속") || slot.contains("reeks"))
        }
    }

    /// 1.4 B2 — the time ranges that hold at least one grid record, in picker
    /// order (narrowest first). Empty when there is no grid record at all.
    nonisolated static func availableBuckets(_ records: [PersonalRecord]) -> [TimeBucket] {
        let grid = gridRecords(records)
        return TimeBucket.allCases.filter { bucket in grid.contains { bucket.includes($0.bucket) } }
    }

    private func bucketPicker(_ buckets: [TimeBucket], selection: Binding<TimeBucket>) -> some View {
        Picker(selection: selection) {
            ForEach(buckets) { bucket in
                Text(LocalizedStringKey(bucket.label))
                    .tag(bucket)
            }
        } label: {
            Text(LocalizedStringKey(Layout.bucketPickerLabel))
        }
        .pickerStyle(.segmented)
    }

    /// Personal-Records empty surface — the canonical `HLEmptyState` lockup
    /// (audit-01 C1). Title + subtitle keep their layout descriptor
    /// (`Layout.emptyTitle` / `Layout.emptySubtitle`) so the contract test
    /// stays valid.
    private var emptyState: some View {
        HLEmptyState(
            icon: "rosette",
            title: LocalizedStringKey(Layout.emptyTitle),
            message: LocalizedStringKey(Layout.emptySubtitle)
        )
        .accessibilityIdentifier("personalRecords.empty")
        .containerCentered()
    }
}

extension PersonalRecordsScreen {
    /// Every value here is fed to `LocalizedStringKey(_:)` at the call site, so
    /// each one is a String-Catalog key. Four of them were German literals with
    /// no catalog entry (1.0.3 / audit row 18): the screen title, the bucket
    /// empty line, the comparison header and the milestones header all rendered
    /// raw German in the English UI — on the screen a reviewer chasing
    /// citations reaches through `BenchmarkSourceSheet`. `streaksHeader` was the
    /// last literal ("Streaks" in both locales); German reads "Serien" since 1.4.
    enum Layout {
        static let navigationTitle = "records.title"
        static let emptyTitle = "No personal records yet"
        static let emptySubtitle =
            "Personal bests per metric unlock once you have enough data."
        static let bucketPickerLabel = "Time range"
        static let streaksHeader = "records.streaks.header"
        static let milestonesHeader = "records.milestones.header"
        static let comparisonHeader = "records.comparison.header"
    }
}

/// v0.5.5.7 RECONCILE-COMPARE — `Identifiable` carrier used by the
/// `.sheet(item:)` for the benchmark source disclaimer. Lifts the
/// `(record, benchmark)` pair into a single `id`-able payload so the
/// presentation mechanism can re-resolve the sheet contents
/// deterministically.
private struct BenchmarkSelection: Identifiable, Equatable {
    let record: PersonalRecord
    let band: RecordBenchmarkBand

    var id: String {
        record.id
    }

    var metricLabel: String {
        if let kind = record.kind {
            return kind.displayName
        }
        return MetricTypeLocalisation.label(forType: record.base.metricType)
    }
}

// MARK: - Metric-type localisation

/// Shared mapper used by PersonalRecords + Targets screens to surface
/// human-readable metric labels. Coverage matches the v0.5.2 measurement
/// type set; unknown values pass through verbatim so the screen never
/// renders an empty label.
///
/// L1 — every value resolves through the String Catalog. The table used to be
/// plain `String`s, half English and half German ("Herzfrequenzvariabilität",
/// "Stockwerke", "Stimmung" …), and every caller put them on screen as-is, so
/// the record cards, the hero card and the VoiceOver labels mixed German into
/// the English UI.
public enum MetricTypeLocalisation {
    public static func label(forType raw: String, locale: Locale = .current) -> String {
        let key = raw.uppercased()
        guard var resource = MetricTypeLocalisation.dictionary[key] else { return raw.capitalized }
        resource.locale = locale
        return String(localized: resource)
    }

    /// Every server metric type this table names (tests walk it per language).
    static var knownTypes: [String] {
        dictionary.keys.sorted()
    }

    private static let dictionary: [String: LocalizedStringResource] = [
        "WEIGHT": "Weight",
        "BMI": "BMI",
        "BODY_FAT": "Body fat",
        "BLOOD_PRESSURE": "Blood pressure",
        "BLOOD_PRESSURE_SYS": "Blood pressure",
        "BP_SYSTOLIC": "Blood pressure",
        "BP_DIASTOLIC": "Blood pressure",
        "PULSE": "Pulse",
        "RESTING_HR": "Resting heart rate",
        "HRV": "Heart rate variability",
        "VO2_MAX": "VO₂ max",
        "OXYGEN_SATURATION": "Oxygen saturation",
        "BODY_TEMPERATURE": "records.metric.bodyTemperature",
        "ACTIVITY_STEPS": "Steps",
        "ACTIVE_ENERGY_BURNED": "Active energy",
        "FLIGHTS_CLIMBED": "Flights climbed",
        "WALKING_RUNNING_DISTANCE": "records.metric.walkingRunningDistance",
        "WALKING_STEADINESS": "records.metric.walkingSteadiness",
        "SLEEP_DURATION": "Sleep",
        "SLEEP_ASLEEP": "Sleep",
        "SLEEP_IN_BED": "Sleep",
        "MOOD": "Mood",
        "MOOD_SCORE": "Mood",
        "MOOD_STABILITY": "Mood",
        "BLOOD_GLUCOSE": "Blood glucose",
        "BLOOD_GLUCOSE_FASTING": "Blood glucose",
        "BLOOD_GLUCOSE_POSTPRANDIAL": "Blood glucose",
        "BLOOD_GLUCOSE_RANDOM": "Blood glucose",
        "BLOOD_GLUCOSE_BEDTIME": "Blood glucose",
        "MEDICATION_COMPLIANCE": "records.metric.medicationCompliance",
        "AUDIO_EXPOSURE_ENV": "records.metric.noiseExposure",
        "AUDIO_EXPOSURE_HEADPHONE": "records.metric.noiseExposure",
        "AUDIO_EXPOSURE_EVENT": "records.metric.noiseExposure",
        "TIME_IN_DAYLIGHT": "Time in daylight"
    ]
}
