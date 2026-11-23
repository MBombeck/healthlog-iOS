import SwiftUI

/// Native nutrient read/display surface (Build 7.6, GH #48) — the LESE-Seite the
/// app was missing. Lists the per-nutrient day totals the server holds
/// (`GET /api/nutrients`) with German names + wire units, a manual water
/// quick-add strip (`POST /api/nutrients/water`), and a tap-through to each
/// nutrient's day-series + EFSA reference progress (``NutrientDetailScreen``).
///
/// Module-gated (default OFF). **N2** — an empty surface no longer speaks with
/// one voice: ``NutrientEmptyState`` splits the switched-off module (the only
/// case with a working action behind it) from the transient
/// authorization-in-flight state and from a genuine "nothing recorded". The old
/// single sentence claimed Apple Health had nothing to give while the truth was
/// that the app never asked. Mounts the shared ``HLSyncStatusFooter`` — no
/// ad-hoc spinner.
struct NutrientListScreen: View {
    @Environment(\.appContainer) private var container

    @State private var store: NutrientStore?
    /// Server 1.49.0: the daily energy balance, a row above the day totals.
    @State private var energyBalance = EnergyBalanceModel()

    var body: some View {
        HLAsyncListScreen(
            phase: phase,
            refresh: { await reload() },
            loading: { HLAsyncListSkeletonRows().hlFormRowSurface() },
            empty: { emptyRows.hlFormRowSurface() },
            content: { if let store { loadedRows(store: store).hlFormRowSurface() } }
        )
        .hlPageMargins()
        .navigationTitle(Text("nutrients.list.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await onAppear() }
    }

    // MARK: - Phase

    private var phase: HLAsyncListPhase {
        guard let store else { return .loading }
        // A switched-off module is an empty state with an action, not a
        // populated list and not an error. It wins over stale rows: those were
        // read before the module went off and no longer describe the account.
        if emptyState == .moduleOff { return .empty }
        if store.rows.isEmpty {
            if store.isLoading { return .loading }
            if store.lastError != nil { return .error(retry: { await reload() }) }
            // The first authorization request + sync of this process is still
            // running; the honest render is the skeleton, not a claim.
            if emptyState == .preparing { return .loading }
            return .empty
        }
        return .loaded
    }

    /// Which of the three real empty states the surface is in. `403
    /// module.disabled` and a `ModuleGate` that says off are the same fact to
    /// the reader, so they collapse into one case here.
    private var emptyState: NutrientEmptyState {
        guard let store else { return .preparing }
        return NutrientEmptyState.resolve(
            isModuleEnabled: store.isModuleEnabled && !store.isDisabled,
            isPreparingHealthKitAccess: store.isPreparingHealthKitAccess
        )
    }

    // MARK: - Rows

    @ViewBuilder
    private func loadedRows(store: NutrientStore) -> some View {
        waterSection(store: store)
        EnergyBalanceSection(model: energyBalance)
        Section {
            ForEach(store.rows) { row in
                // A code this build cannot name keeps its row and
                // its amount, but has NO detail behind it: `/daily` is keyed on
                // the catalogue code, and the sentinel is not one (the route
                // validates the enum and answers 400). So the row renders flat.
                // A nameable row is tappable as a whole, without a chevron:
                // it shows a value, not a menu.
                if row.nutrient == .unknown {
                    NutrientOverviewRowView(row: row)
                        .accessibilityIdentifier("nutrients.row.\(row.id)")
                } else {
                    NutrientOverviewRowView(row: row)
                        .hlRowLink(inList: true) {
                            NutrientDetailScreen(code: row.nutrient, store: store)
                        }
                        .accessibilityIdentifier("nutrients.row.\(row.nutrient.rawValue)")
                }
            }
        } header: {
            HLSectionHeader("nutrients.list.section.today")
        }
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    private func waterSection(store: NutrientStore) -> some View {
        Section {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLValueText(store.waterLatestAmountMl, unit: .milliliters, size: .tile, fractionDigits: 0 ... 0)
                    .accessibilityIdentifier("nutrients.water.total")
                // Three equal quick-add buttons in the row's small form.
                HLButtonRow(size: .small) {
                    ForEach(NutrientStore.waterQuickAddAmountsMl, id: \.self) { amount in
                        HLButton(Text(verbatim: "+\(Int(amount)) ml"), variant: .secondary) {
                            Task { await store.addWater(amountMl: amount) }
                        }
                        .accessibilityIdentifier("nutrients.water.add.\(Int(amount))")
                    }
                }
            }
            .padding(.vertical, HLSpace.xs)
        } header: {
            HLSectionHeader("nutrients.water.section")
        }
    }

    private var emptyRows: some View {
        Section {
            // The window the reader is told about rides in the
            // empty state's own sentence (1.4 B2: it was a loose caption under
            // it). `GET /api/nutrients` omits every nutrient with no data in
            // the requested window, so "nothing here" is always a statement
            // about that window; the number is the server's own echo.
            // A window of 0 days is no statement (the route echoed nothing).
            NutrientEmptyStateView(
                state: emptyState,
                windowDays: emptyState == .noData ? store.flatMap { $0.windowDays > 0 ? $0.windowDays : nil } : nil
            ) {
                await store?.enableModuleAndPrepare()
            }
            // The lockup stands on the list, not on a row card.
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Loading

    private func onAppear() async {
        if store == nil {
            store = container?.nutrientStore
        }
        await reload()
        // The state-driven read-authorization request. The module state
        // lives on the server, so "module on, this device never asked" is a real
        // combination (a reinstall on an opted-in account) that the toggle-only
        // request never covered. Self-gates on the module + a once-per-process
        // guard; see `NutrientStore.prepareHealthKitAccessIfNeeded()`.
        await store?.prepareHealthKitAccessIfNeeded()
    }

    private func reload() async {
        await store?.load()
        await reloadEnergyBalance()
    }

    /// Read only while the module is on; the route answers 403 otherwise,
    /// and a server before 1.49 answers 404 (both hide the row).
    private func reloadEnergyBalance() async {
        guard let container, let store, store.isModuleEnabled, !store.isDisabled else { return }
        let repository = EnergyBalanceRepository(api: container.api)
        await energyBalance.load { try await repository.read() }
    }
}

/// One nutrient row: name, the days-with-data count inside the window, and
/// the latest day's total (wire unit) as the row's value.
private struct NutrientOverviewRowView: View {
    let row: NutrientOverviewRowDTO

    var body: some View {
        HLRow(
            // An unnameable code labels itself with the raw
            // server string; see `NutrientDisplay.name(for:rawCode:)`.
            title: Text(NutrientDisplay.name(for: row.nutrient, rawCode: row.rawNutrient)),
            detail: Text("nutrients.row.daysWithData \(row.daysWithData)"),
            value: Text(NutrientDisplay.formatted(amount: row.latestAmount, wireUnit: row.unit))
        )
    }
}
