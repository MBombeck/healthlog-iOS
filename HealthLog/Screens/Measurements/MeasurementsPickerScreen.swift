import SwiftUI

/// v0.14.2 (#136) — **Messwerte** metric-type picker.
///
/// A clean list of the metric kinds the user has data for, grouped by the
/// app's own taxonomy (`InsightsMetricCategory`, via `MeasurementsPickerModel`).
/// Each row pushes the EXISTING values table — `MeasurementListScreen(kind:)`,
/// the Apple-Health-style day/week/month bucketed list with edit/delete +
/// source filter that was previously only reachable via the chart drill-down
/// (`ChartDetailScreen` → `DrillDownRow`). Per operator directive "keine
/// einzelnen Views für Sachen, die es schon gibt", this screen builds NO new
/// values table — it is purely the missing picker in front of the reused list.
///
/// **Entry point:** the Mehr tab, "Data & devices" section (a peer of Export /
/// Geräte — browsing one's measurement history is content navigation, not a
/// setting), see `MoreScreen`.
///
/// **Availability:** the picker probes the SWR-cached `recentAll()` page to
/// learn which kinds carry data and lists only those (Apple-Health "Browse"
/// pattern). A brand-new account with no measurements gets a calm empty state
/// instead of a wall of zero-data rows.
struct MeasurementsPickerScreen: View {
    @Environment(\.appContainer) private var container

    /// v0.14.8 — the two browse modes. `.byType` is the existing metric-type
    /// picker (default — nothing regresses); `.recent` is the new chronological
    /// cross-category feed (`MeasurementsChronoFeed`). Operator request: "manchmal
    /// möchte man einfach nur sehen, was die letzten Messwerte sind —
    /// chronologisch, über alle Kategorien hinweg."
    enum Mode: Hashable {
        case byType
        case recent
    }

    @State private var mode: Mode = .byType

    @State private var kindsWithData: Set<MetricKind> = []
    /// v0.14.8 — the recent cross-category rows powering the chronological feed
    /// (raised window so multiple kinds interleave by time). Loaded alongside the
    /// kind-availability set so switching modes never re-fetches.
    @State private var recentAll: [Measurement] = []
    @State private var isLoading: Bool = false
    @State private var lastLoadedAt: Date?
    @State private var error: HLError?

    /// Cross-category feed window. Larger than the type-picker's availability
    /// probe (400) so a HealthKit power-user's high-frequency kinds don't crowd
    /// every low-frequency kind out of the interleaved "Alle" list.
    private static let chronoLimit = 400

    private var sections: [MeasurementsPickerModel.Section] {
        MeasurementsPickerModel.sections(kindsWithData: kindsWithData)
    }

    var body: some View {
        VStack(spacing: 0) {
            modePicker
            switch mode {
            case .byType:
                byTypeList
            case .recent:
                MeasurementsChronoFeed(measurements: $recentAll) { measurement in
                    await deleteRecent(measurement)
                }
            }
        }
        // v0.14.x operator fix — `HLColor.background` (#16171C dark) drifted
        // bluish against the canonical screen canvas every tab root paints
        // (`HLSurface.primary`, #101113 dark — see `HLScreenBackground` /
        // `MoreScreen`). Align all Measurements surfaces to the same token.
        .background(HLSurface.primary)
        .navigationTitle(Text("Measurements", comment: "Measurements picker — nav title"))
        .navigationBarTitleDisplayMode(.large)
        .hlErrorBannerOverlay(error: error) {
            Task { await load() }
        }
        .refreshable { await load() }
        .task { await loadIfStale() }
    }

    /// The segmented mode switch — "Nach Typ" / "Chronologisch". Defaults to
    /// `.byType` so the existing experience is unchanged on entry.
    private var modePicker: some View {
        Picker(selection: $mode) {
            Text("By type").tag(Mode.byType)
            Text("Recent").tag(Mode.recent)
        } label: {
            Text("Browse mode")
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, HLSpace.lg)
        .padding(.top, HLSpace.sm)
        .padding(.bottom, HLSpace.xs)
        .accessibilityIdentifier("measurements.picker.modeSwitch")
    }

    private var byTypeList: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.kinds) { kind in
                        row(for: kind)
                    }
                } header: {
                    if let category = section.category {
                        Text(category.label)
                    }
                }
            }
            // Custom metrics — the user's OWN metric definitions, hung below
            // the built-in metric types exactly as the web hangs them below the
            // measurement list (`app/measurements/page.tsx:172`). A separate
            // section (not a row among the kinds) because these are a different
            // kind of thing: user-defined and outside the closed
            // `MeasurementType` system entirely.
            customMetricsSection
            // v0.14.8 W2-SYNCUX — canonical sync-status footer (same primitive
            // as Dashboard/Insights, self-suppressing via empty-section footer).
            Section {} footer: {
                HLSyncStatusFooter(screenLoading: isLoading)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
        .hlScrollEdgeSoft()
        .overlay {
            if sections.isEmpty, !isLoading {
                EmptyState()
            }
        }
    }

    /// Entry point into the custom-metric surface. Shows the definition count
    /// as a subtitle so the row is honest about whether anything is there.
    @ViewBuilder
    private var customMetricsSection: some View {
        if let container {
            Section {
                NavigationLink {
                    CustomMetricsListScreen(store: container.customMetricsStore)
                } label: {
                    HLSettingsRow(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "customMetric.list.title",
                        subtitle: "customMetric.list.subtitle"
                    )
                }
                .accessibilityIdentifier("measurements.picker.customMetrics")
            }
        }
    }

    @ViewBuilder
    private func row(for kind: MetricKind) -> some View {
        let descriptor = kind.descriptor
        NavigationLink {
            MeasurementListScreen(kind: kind)
        } label: {
            HLSettingsRow(
                icon: descriptor.sfSymbol,
                title: LocalizedStringKey(String(localized: descriptor.title)),
                subtitle: LocalizedStringKey(String(localized: descriptor.unitLabel))
            )
        }
        .accessibilityIdentifier("measurements.picker.row.\(kind.rawValue)")
    }

    // MARK: - Loading

    /// Derive the kinds-with-data set.
    ///
    /// v0.14.7 B8 — **availability-source fix.** This previously derived the set
    /// from `recentAll(limit: 400)` alone — a last-400-rows RECENCY window, not an
    /// all-time per-kind availability map. On a HealthKit power-user whose recent
    /// rows are dominated by high-frequency kinds (steps / activeEnergy / HR), a
    /// low-frequency kind with real history but no row in that window (weight,
    /// blood-pressure, glucose, BMI, VO2max, sleep…) was silently MISSING from the
    /// picker — the operator-reported "not all types are listed" bug. This is the
    /// same bug class the repo already fixed for the Insights strip via
    /// ``MeasurementsRepository/availableKinds()`` (an all-time count per
    /// `MeasurementType` from `GET /api/analytics?slice=summaries`); the picker was
    /// never migrated onto it. Now we UNION the authoritative all-time server map
    /// with the recent on-device snapshot, mirroring how Insights composes it:
    /// `availableKinds()` returns `[]` in standalone (no `/api/*`), so the
    /// `recentAll` union keeps the offline / HealthKit path working.
    private func load() async {
        guard let container else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let serverKinds = container.measurementsRepo.availableKinds()
            async let recent = container.measurementsRepo.recentAll(limit: Self.chronoLimit)
            let recentRows = try await recent
            // v0.14.8 — keep the full recent page for the chronological feed; the
            // type-picker only needs the kind set derived from it.
            recentAll = recentRows
            let recentKinds = Set(recentRows.map(\.kind))
            // Server map is best-effort (all-time); never let its absence drop the
            // on-device kinds — union so both the paired all-time set AND the
            // standalone recency snapshot light up.
            let allTime = await (try? serverKinds) ?? []
            kindsWithData = allTime.union(recentKinds)
            lastLoadedAt = .now
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    private func loadIfStale() async {
        let stale = lastLoadedAt.map { Date.now.timeIntervalSince($0) >= 60 } ?? true
        if kindsWithData.isEmpty || stale {
            await load()
        }
    }

    /// The store owns optimistic deletion, durable outbox enrollment and undo.
    /// Its Bool alone is intentionally insufficient: retriable/outboxed deletes
    /// return false while correctly keeping the row removed. The store always
    /// publishes the current failure before returning, so its outbox disposition
    /// distinguishes that durable removal from a genuinely rejected delete.
    private func deleteRecent(_ measurement: Measurement) async -> Bool {
        guard let container else { return false }
        let succeeded = await container.measurementsStore.delete(measurement)
        guard !succeeded else { return true }
        let storeError = container.measurementsStore.error
        error = storeError
        return storeError?.shouldPersistToOutbox == true
    }
}

// MARK: - Empty state

/// Calm empty state for an account with no measurements at all — not a dead
/// box. Mirrors the `MeasurementListScreen.EmptyState` copy/glyph so the two
/// surfaces feel like one family, and reuses the existing "No measurements yet"
/// xcstrings key.
private struct EmptyState: View {
    var body: some View {
        HLEmptyState(
            icon: "tray",
            title: "No measurements yet",
            message: "Log your first measurement to browse it by type here."
        )
        .accessibilityIdentifier("measurements.picker.empty")
    }
}
