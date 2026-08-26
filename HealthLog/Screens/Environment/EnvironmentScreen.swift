import SwiftUI

/// Native environmental-context display surface (Build 7 Item 7.7; server module
/// `environment`). Shows what the module overview honestly reports — the coarse
/// home location, the manual travel overrides, and how much weather / daylight
/// coverage the server holds — followed by the **licence-mandated Open-Meteo
/// attribution** (CC BY 4.0).
///
/// There is deliberately no air-quality / pollen / UV content: the server module
/// is weather + daylight only, and the per-day values are consumed server-side for
/// correlations (not returned to the client). This surface reflects the coverage,
/// not the raw readings.
///
/// Module-gated (default-ON): a `403 module.disabled` renders the neutral
/// disabled hint instead of an error. The attribution is shown in EVERY loaded
/// state — populated, empty, or disabled — so the credit can never disappear.
struct EnvironmentScreen: View {
    @Environment(\.appContainer) private var container

    @State private var store: EnvironmentStore?

    var body: some View {
        HLAsyncListScreen(
            phase: phase,
            refresh: { await reload() },
            loading: { HLAsyncListSkeletonRows() },
            empty: { EmptyView() },
            content: { if let store { loadedRows(store: store) } }
        )
        .navigationTitle(Text("environment.list.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await onAppear() }
    }

    // MARK: - Phase

    private var phase: HLAsyncListPhase {
        guard let store else { return .loading }
        // Disabled + populated + genuinely-empty ALL route to `.loaded` so the
        // attribution section is rendered in every one of them. Only a first-load
        // spinner and a hard error (with nothing to show) get their own phase.
        if store.isDisabled { return .loaded }
        // Until the first load resolves, show the skeleton (never a momentary
        // empty-state flash).
        if !store.hasLoaded { return .loading }
        if store.lastError != nil, !store.hasContent { return .error(retry: { await reload() }) }
        return .loaded
    }

    // MARK: - Rows

    @ViewBuilder
    private func loadedRows(store: EnvironmentStore) -> some View {
        if store.isDisabled {
            Section {
                FeatureDisabledCard(variant: .hero)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            attributionSection(store: store)
        } else {
            if store.hasContent {
                homeSection(store: store)
                coverageSection(store: store)
                travelSection(store: store)
            } else {
                Section {
                    HLEmptyState(
                        icon: "cloud.sun",
                        title: "environment.empty.title",
                        message: "environment.empty.subtitle"
                    )
                    .listRowBackground(Color.clear)
                }
            }
            attributionSection(store: store)
        }
    }

    @ViewBuilder
    private func homeSection(store: EnvironmentStore) -> some View {
        if let home = store.home, store.hasHome {
            Section(header: Text("environment.home.section")) {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(home.label ?? String(localized: "environment.home.unnamed"))
                        .font(.hlBody)
                        .foregroundStyle(HLText.primary)
                    if let since = home.since, let formatted = Self.displayDate(since) {
                        Text("environment.home.since \(formatted)")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }
                }
                .padding(.vertical, HLSpace.xxs)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("environment.home")
            }
        }
    }

    private func coverageSection(store: EnvironmentStore) -> some View {
        Section(header: Text("environment.coverage.section")) {
            HStack(alignment: .firstTextBaseline) {
                Text("environment.coverage.days \(store.context.days)")
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                    .accessibilityIdentifier("environment.coverage.days")
                Spacer(minLength: HLSpace.sm)
                if let latest = store.context.latestDate, let formatted = Self.displayDate(latest) {
                    Text(formatted)
                        .font(.hlBody.monospacedDigit())
                        .foregroundStyle(HLText.secondary)
                }
            }
            .padding(.vertical, HLSpace.xxs)
        }
    }

    @ViewBuilder
    private func travelSection(store: EnvironmentStore) -> some View {
        if !store.travel.isEmpty {
            Section(header: Text("environment.travel.section")) {
                ForEach(store.travel) { trip in
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(trip.label.isEmpty ? String(localized: "environment.home.unnamed") : trip.label)
                            .font(.hlBody)
                            .foregroundStyle(HLText.primary)
                        Text(Self.dateRange(trip.startDate, trip.endDate))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }
                    .padding(.vertical, HLSpace.xxs)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// The **licence-mandated** Open-Meteo attribution (CC BY 4.0). Rendered as a
    /// linked credit in a footer that is present in every loaded state. The credit
    /// TEXT comes from the store (server-provided, defaulted to the canonical
    /// string), the LINKS are fixed licence URLs.
    private func attributionSection(store: EnvironmentStore) -> some View {
        Section {} footer: {
            EnvironmentAttributionView(attribution: store.attribution)
                .accessibilityIdentifier("environment.attribution")
        }
    }

    // MARK: - Loading

    private func onAppear() async {
        if store == nil {
            store = container?.environmentStore
        }
        await reload()
    }

    private func reload() async {
        await store?.load()
    }

    // MARK: - Date helpers (tolerant — raw string fallback)

    /// Format a wire date (a `YYYY-MM-DD` day-key or an ISO-8601 instant) into a
    /// localized medium date. Returns the raw string when it does not parse, and
    /// `nil` only for an empty input, so display is always tolerant.
    static func displayDate(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if let day = dayKeyFormatter.date(from: String(raw.prefix(10))) {
            return mediumFormatter.string(from: day)
        }
        if let instant = ISO8601DateFormatter().date(from: raw) {
            return mediumFormatter.string(from: instant)
        }
        return raw
    }

    /// A localized "start – end" range, falling back to the raw keys.
    static func dateRange(_ start: String, _ end: String) -> String {
        let s = displayDate(start) ?? start
        let e = displayDate(end) ?? end
        return "\(s) – \(e)"
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// The Open-Meteo credit lockup — the CC BY 4.0 obligation made visible + linked.
/// The credit text is the server-provided (defaulted) string; the links are fixed
/// licence URLs. Kept as a small dedicated view so the licence surface is a single
/// reusable unit.
private struct EnvironmentAttributionView: View {
    let attribution: String

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            if let url = EnvironmentOverviewDTO.attributionURL {
                Link(destination: url) {
                    Text(verbatim: attribution)
                        .font(.hlCaption)
                        .underline()
                }
                .accessibilityIdentifier("environment.attribution.link")
            } else {
                Text(verbatim: attribution)
                    .font(.hlCaption)
            }
            if let license = EnvironmentOverviewDTO.licenseURL {
                Link(destination: license) {
                    Text("environment.attribution.license")
                        .font(.hlCaption2)
                        .underline()
                }
            }
        }
        .foregroundStyle(HLText.tertiary)
        .padding(.top, HLSpace.xs)
    }
}
