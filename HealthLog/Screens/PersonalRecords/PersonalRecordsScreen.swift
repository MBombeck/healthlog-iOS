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
    /// R4 §3.1 — Personal Records are server-derived (no on-device store). When
    /// no backend is available, render `HLCloudDerivedPlaceholder` instead of an
    /// empty screen + doomed `/api/personal-records` fetch. `hasServer` is always
    /// `true` in paired mode → inert for paired users.
    @Environment(BackendAvailability.self) private var backend
    /// v0.11 W3 — shared "Server verbinden" CTA path for the placeholder.
    @Environment(AuthStore.self) private var authStore
    /// QoL-A2 (Felt-craft #5) — gate the celebration-dismiss fade on reduce-motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// v1.18.3 — Rest Mode source (server-authoritative via the Health Score).
    /// When active (+ illness enabled), the streak rail carries a calm note that
    /// a recovery gap is expected. The streaks themselves are step-driven
    /// records (`StreakComputer`) and are NEVER penalised by an illness episode —
    /// this is render-side softening only.
    @Environment(HealthScoreStore.self) private var healthScoreStore

    @State private var selectedShareRecord: PersonalRecord?
    @State private var celebrationRecord: PersonalRecord?
    /// v0.5.5.7 RECONCILE-COMPARE — surfaces the
    /// `BenchmarkSourceSheet` when the operator taps a comparison
    /// band. Reset to `nil` on dismiss; `(record, benchmark)` tuple
    /// stays paired so the sheet knows which metric label + source
    /// to surface.
    @State private var selectedBenchmark: BenchmarkSelection?

    /// v0.5.5.7 RECONCILE-COMPARE — provider for the comparison-band
    /// section. Held in `@State` (not env) because the live impl is
    /// stateless + value-type; lift to env in a future refactor if
    /// the screen ever needs to swap providers at runtime (e.g. for
    /// snapshot tests). Initialiser path:
    /// `LiveClinicalBenchmarkProvider()` ships with zero deps.
    @State private var benchmarkProvider: any ClinicalBenchmarkProvider = LiveClinicalBenchmarkProvider()

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
        .overlay(alignment: .top) {
            ErrorBanner(error: store.error) {
                Task { await store.refresh() }
            }
        }
        #if canImport(UIKit)
        .sheet(item: $selectedShareRecord) { record in
            if let image = RecordShareImage.render(record) {
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
                benchmark: selection.benchmark
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

                bucketPicker(selection: $bindableStore.selectedBucket)
                    .padding(.horizontal, HLSpace.lg)

                gridSection

                if !store.streakRecords.isEmpty {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        HLSectionLabel(LocalizedStringKey(Layout.streaksHeader))
                            .padding(.horizontal, HLSpace.lg)
                        // v1.18.3 — calm rest-aware note in the streaks section.
                        // Records are step-driven (StreakComputer) and untouched
                        // by an illness episode; this only softens the framing.
                        RestModeGate(score: healthScoreStore.score) { restMode in
                            RestModeAnnotationPill(restMode: restMode, style: .caption)
                                .padding(.horizontal, HLSpace.lg)
                        }
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
    }

    /// v0.5.5.7 RECONCILE-COMPARE — comparison-band section. Renders
    /// one `ComparisonBand` per visible record whose `kind` the
    /// provider carries benchmark data for. Deduplicated by `kind`
    /// so multiple records of the same kind only surface a single
    /// band (the highest-impressiveness representative).
    @ViewBuilder
    private var comparisonSection: some View {
        let pairs = comparisonPairs
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel(LocalizedStringKey(Layout.comparisonHeader))
                    .padding(.horizontal, HLSpace.lg)
                VStack(spacing: HLSpace.sm) {
                    ForEach(pairs, id: \.record.id) { pair in
                        ComparisonBand(
                            record: pair.record,
                            benchmark: pair.benchmark
                        ) {
                            selectedBenchmark = BenchmarkSelection(
                                record: pair.record,
                                benchmark: pair.benchmark
                            )
                        }
                    }
                }
                .padding(.horizontal, HLSpace.lg)
            }
        }
    }

    /// Returns the unique-by-kind `(record, benchmark)` pairs for the
    /// comparison section. Order matches `store.visibleRecords` so the
    /// section feels stable across re-renders.
    private var comparisonPairs: [(record: PersonalRecord, benchmark: ClinicalBenchmark)] {
        var seenKinds: Set<MetricKind> = []
        var out: [(record: PersonalRecord, benchmark: ClinicalBenchmark)] = []
        for record in store.visibleRecords {
            guard let kind = record.kind, !seenKinds.contains(kind) else { continue }
            guard let benchmark = benchmarkProvider.benchmark(for: kind) else { continue }
            seenKinds.insert(kind)
            out.append((record, benchmark))
        }
        return out
    }

    @ViewBuilder
    private var gridSection: some View {
        let visible = store.visibleRecords.filter { record in
            // Streak records render in the rail instead of the grid.
            let slot = (record.base.metricSlot ?? "").lowercased()
            return !(slot.contains("serie") || slot.contains("streak"))
        }
        if visible.isEmpty {
            VStack(spacing: HLSpace.sm) {
                Image(systemName: "tray")
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(
                        size: 36,
                        weight: .regular
                    )) // Empty-state hero medallion glyph — intentionally off the HLIconSize scale (>hero/28pt), decorative with no
                    // accompanying scaling text.
                    .foregroundStyle(HLText.tertiary)
                Text(LocalizedStringKey(Layout.bucketEmpty))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLSpace.xl)
            .padding(.horizontal, HLSpace.lg)
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: HLSpace.md), GridItem(.flexible(), spacing: HLSpace.md)],
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

    private func bucketPicker(selection: Binding<TimeBucket>) -> some View {
        Picker(selection: selection) {
            ForEach(TimeBucket.allCases) { bucket in
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
    enum Layout {
        static let navigationTitle = "Persönliche Rekorde"
        static let emptyTitle = "No personal records yet"
        static let emptySubtitle =
            "Personal bests per metric unlock once you have enough data."
        static let bucketEmpty = "Für diesen Zeitraum sind noch keine Rekorde verzeichnet."
        static let bucketPickerLabel = "Time range"
        static let streaksHeader = "Streaks"
        static let milestonesHeader = "Meilensteine"
        static let comparisonHeader = "Vergleich"
    }
}

/// v0.5.5.7 RECONCILE-COMPARE — `Identifiable` carrier used by the
/// `.sheet(item:)` for the benchmark source disclaimer. Lifts the
/// `(record, benchmark)` pair into a single `id`-able payload so the
/// presentation mechanism can re-resolve the sheet contents
/// deterministically.
private struct BenchmarkSelection: Identifiable, Equatable {
    let record: PersonalRecord
    let benchmark: ClinicalBenchmark

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
public enum MetricTypeLocalisation {
    public static func label(forType raw: String) -> String {
        let key = raw.uppercased()
        return MetricTypeLocalisation.dictionary[key] ?? raw.capitalized
    }

    private static let dictionary: [String: String] = [
        "WEIGHT": "Weight",
        "BMI": "BMI",
        "BODY_FAT": "Body fat",
        "BLOOD_PRESSURE": "Blood pressure",
        "BLOOD_PRESSURE_SYS": "Blood pressure",
        "BP_SYSTOLIC": "Blood pressure",
        "BP_DIASTOLIC": "Blood pressure",
        "PULSE": "Pulse",
        "RESTING_HR": "Resting heart rate",
        "HRV": "Herzfrequenzvariabilität",
        "VO2_MAX": "VO₂ max",
        "OXYGEN_SATURATION": "Oxygen saturation",
        "BODY_TEMPERATURE": "Körpertemperatur",
        "ACTIVITY_STEPS": "Steps",
        "ACTIVE_ENERGY_BURNED": "Aktive Energie",
        "FLIGHTS_CLIMBED": "Stockwerke",
        "WALKING_RUNNING_DISTANCE": "Distanz (Gehen / Laufen)",
        "WALKING_STEADINESS": "Geh-Stabilität",
        "SLEEP_DURATION": "Sleep",
        "SLEEP_ASLEEP": "Sleep",
        "SLEEP_IN_BED": "Sleep",
        "MOOD": "Stimmung",
        "MOOD_SCORE": "Stimmung",
        "MOOD_STABILITY": "Stimmung",
        "BLOOD_GLUCOSE": "Blood glucose",
        "BLOOD_GLUCOSE_FASTING": "Blood glucose",
        "BLOOD_GLUCOSE_POSTPRANDIAL": "Blood glucose",
        "BLOOD_GLUCOSE_RANDOM": "Blood glucose",
        "BLOOD_GLUCOSE_BEDTIME": "Blood glucose",
        "MEDICATION_COMPLIANCE": "Medikamenten-Compliance",
        "AUDIO_EXPOSURE_ENV": "Lärm-Belastung",
        "AUDIO_EXPOSURE_HEADPHONE": "Lärm-Belastung",
        "AUDIO_EXPOSURE_EVENT": "Lärm-Belastung",
        "TIME_IN_DAYLIGHT": "Tageslicht"
    ]
}
