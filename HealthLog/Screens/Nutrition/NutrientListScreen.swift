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

    var body: some View {
        HLAsyncListScreen(
            phase: phase,
            refresh: { await reload() },
            loading: { HLAsyncListSkeletonRows() },
            empty: { emptyRows },
            content: { if let store { loadedRows(store: store) } }
        )
        .navigationTitle(Text("nutrients.list.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await onAppear() }
    }

    // MARK: - Phase

    private var phase: HLAsyncListPhase {
        guard let store else { return .loading }
        // N2 — a switched-off module is an empty state with an action, not a
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

    /// N2 — which of the three real empty states the surface is in. `403
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
        Section(header: Text("nutrients.list.section.today")) {
            ForEach(store.rows) { row in
                NavigationLink {
                    NutrientDetailScreen(code: row.nutrient, store: store)
                } label: {
                    NutrientOverviewRowView(row: row)
                }
                .accessibilityIdentifier("nutrients.row.\(row.nutrient.rawValue)")
            }
        }
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    private func waterSection(store: NutrientStore) -> some View {
        Section(header: Text("nutrients.water.section")) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text(NutrientDisplay.formatted(amount: store.waterLatestAmountMl, wireUnit: "ml"))
                    .font(.hlTitle3)
                    .foregroundStyle(HLText.primary)
                    .accessibilityIdentifier("nutrients.water.total")
                HStack(spacing: HLSpace.sm) {
                    ForEach(NutrientStore.waterQuickAddAmountsMl, id: \.self) { amount in
                        Button {
                            Task { await store.addWater(amountMl: amount) }
                        } label: {
                            Text(verbatim: "+\(Int(amount)) ml")
                                .font(.hlSubhead)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("nutrients.water.add.\(Int(amount))")
                    }
                }
            }
            .padding(.vertical, HLSpace.xs)
        }
    }

    private var emptyRows: some View {
        Section {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                NutrientEmptyStateView(state: emptyState) {
                    await store?.enableModuleAndPrepare()
                }
                // 14-04 (F1) — name the window the reader is being told about.
                //
                // `GET /api/nutrients` omits every nutrient with no data inside
                // the requested window, so "nothing here" is always a statement
                // ABOUT A WINDOW and never about the account. Saying which one
                // is the difference between an honest empty state and the one
                // that sent the operator looking for a fault in Apple Health.
                // The number is the server's own echo (`windowDays`), so a
                // deployment that clamps the request corrects the sentence.
                if emptyState == .noData, let store {
                    Text("nutrients.list.empty.window \(store.windowDays)")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("nutrients.empty.window")
                }
            }
        }
    }

    // MARK: - Loading

    private func onAppear() async {
        if store == nil {
            store = container?.nutrientStore
        }
        await reload()
        // N2 — the state-driven read-authorization request. The module state
        // lives on the server, so "module on, this device never asked" is a real
        // combination (a reinstall on an opted-in account) that the toggle-only
        // request never covered. Self-gates on the module + a once-per-process
        // guard; see `NutrientStore.prepareHealthKitAccessIfNeeded()`.
        await store?.prepareHealthKitAccessIfNeeded()
    }

    private func reload() async {
        await store?.load()
    }
}

/// One nutrient row — German name, latest-day total (wire unit), and the
/// days-with-data count inside the window.
private struct NutrientOverviewRowView: View {
    let row: NutrientOverviewRowDTO

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(NutrientDisplay.name(for: row.nutrient))
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                Text("nutrients.row.daysWithData \(row.daysWithData)")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
            Spacer(minLength: HLSpace.sm)
            Text(NutrientDisplay.formatted(amount: row.latestAmount, wireUnit: row.unit))
                .font(.hlBody.monospacedDigit())
                .foregroundStyle(HLText.secondary)
        }
    }
}
