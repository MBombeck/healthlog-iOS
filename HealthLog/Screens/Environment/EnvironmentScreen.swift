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
    /// 1.5 MOVE — "Unterwegs", owned by the screen so pull to refresh reads
    /// it again with the rest. Hidden until it knows it has something to show.
    @State private var movement: MovementStore?

    var body: some View {
        HLAsyncListScreen(
            phase: phase,
            refresh: { await reload() },
            loading: { HLAsyncListSkeletonRows().hlFormRowSurface() },
            empty: { EmptyView() },
            content: { if let store { loadedRows(store: store).hlFormRowSurface() } }
        )
        .hlPageMargins()
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
                // The module is off; the server says why (a scoped
                // sharing grant, the operator's instance switch, the viewer's
                // own switch). `nil` on a server < v1.38.15 → the neutral copy.
                FeatureDisabledCard(
                    variant: .hero,
                    reason: container?.moduleGate.offReason(.environment)
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            attributionSection(store: store)
        } else {
            if store.hasContent {
                homeSection(store: store)
                coverageSection(store: store)
                travelSection(store: store)
                movementSection
            } else {
                Section {
                    HLEmptyState(
                        icon: "cloud.sun",
                        title: "environment.empty.title",
                        message: "environment.empty.subtitle"
                    )
                    .listRowBackground(Color.clear)
                }
                movementSection
            }
            attributionSection(store: store)
        }
    }

    /// 1.5 MOVE — only with the module on (the disabled branch never gets
    /// here) and only when the store has something to show.
    @ViewBuilder
    private var movementSection: some View {
        if let movement {
            EnvironmentMovementSection(store: movement)
        }
    }

    @ViewBuilder
    private func homeSection(store: EnvironmentStore) -> some View {
        if let home = store.home, store.hasHome {
            Section {
                HLRow(
                    title: Text(home.label ?? String(localized: "environment.home.unnamed")),
                    detail: home.since.flatMap(Self.displayDate).map { Text("environment.home.since \($0)") }
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("environment.home")
            } header: {
                HLSectionHeader("environment.home.section")
            }
        }
    }

    private func coverageSection(store: EnvironmentStore) -> some View {
        Section {
            // The latest covered day is a date, not a reading, so it takes
            // the quieter value weight.
            HLRowLayout(title: Text("environment.coverage.days \(store.context.days)")) {
                if let latest = store.context.latestDate, let formatted = Self.displayDate(latest) {
                    HLRowValue(formatted, emphasis: .setting)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("environment.coverage.days")
        } header: {
            HLSectionHeader("environment.coverage.section")
        }
    }

    @ViewBuilder
    private func travelSection(store: EnvironmentStore) -> some View {
        if !store.travel.isEmpty {
            Section {
                ForEach(store.travel) { trip in
                    HLRow(
                        title: Text(trip.label.isEmpty ? String(localized: "environment.home.unnamed") : trip.label),
                        detail: Text(Self.dateRange(trip.startDate, trip.endDate))
                    )
                    .accessibilityElement(children: .combine)
                }
            } header: {
                HLSectionHeader("environment.travel.section")
            }
        }
    }

    /// The **licence-mandated** Open-Meteo attribution (CC BY 4.0). Rendered as a
    /// linked credit in a footer that is present in every loaded state. The credit
    /// TEXT comes from the store (server-provided, defaulted to the canonical
    /// string), the LINKS are fixed licence URLs.
    private func attributionSection(store: EnvironmentStore) -> some View {
        Section {} footer: {
            // Under the centred empty state the credit is centred too.
            EnvironmentAttributionView(attribution: store.attribution, centered: !store.hasContent)
                .accessibilityIdentifier("environment.attribution")
        }
    }

    // MARK: - Loading

    private func onAppear() async {
        if store == nil {
            store = container?.environmentStore
        }
        if movement == nil, let api = container?.api {
            movement = MovementStore(repository: MovementRepository(api: api))
        }
        await reload()
    }

    private func reload() async {
        await store?.load()
        // Movement belongs to the `environment` module: with it off the
        // overview says so and the movement read is not made at all.
        if store?.isDisabled == false {
            await movement?.load()
        }
    }

    // MARK: - Date helpers (tolerant — raw string fallback)

    /// Format a wire date (a `YYYY-MM-DD` day-key or an ISO-8601 instant) into a
    /// localized medium date. Returns the raw string when it does not parse, and
    /// `nil` only for an empty input, so display is always tolerant.
    static func displayDate(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if let day = dayKeyFormatter.date(from: String(raw.prefix(10))) {
            return HLDateFormat.date(day)
        }
        if let instant = ISO8601DateFormatter().date(from: raw) {
            return HLDateFormat.date(instant)
        }
        return raw
    }

    /// A localized "start – end" range, falling back to the raw keys.
    static func dateRange(_ start: String, _ end: String) -> String {
        let s = displayDate(start) ?? start
        let e = displayDate(end) ?? end
        return HLNumberFormat.range(s, e)
    }

    private static let dayKeyFormatter: DateFormatter = {
        // Parses the server's `yyyy-MM-dd` keys; the display goes through
        // `displayDate`, not through this formatter.
        // swiftlint:disable:next hl_date_via_helper
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// The Open-Meteo credit lockup — the CC BY 4.0 obligation made visible + linked.
/// The credit text is the server-provided (defaulted) string; the links are fixed
/// licence URLs. Kept as a small dedicated view so the licence surface is a single
/// reusable unit.
struct EnvironmentAttributionView: View {
    let attribution: String
    /// Centred under a centred empty state; leading under cards.
    var centered = false

    /// The server sends the credit in English. Its canonical wording is shown
    /// in the interface language; any other credit stays as served.
    static func credit(for attribution: String) -> String {
        attribution == EnvironmentOverviewDTO.defaultAttribution
            ? String(localized: "environment.attribution.credit")
            : attribution
    }

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: HLSpace.xxs) {
            if let url = EnvironmentOverviewDTO.attributionURL {
                HLTextLink(verbatim: Self.credit(for: attribution), destination: url)
                    .accessibilityIdentifier("environment.attribution.link")
            } else {
                Text(verbatim: Self.credit(for: attribution))
            }
            if let license = EnvironmentOverviewDTO.licenseURL {
                HLTextLink("environment.attribution.license", destination: license)
            }
        }
        // The links take the size of the line around them; secondary ink
        // like every quiet line, no underline.
        .font(.hlCaption)
        .foregroundStyle(HLText.secondary)
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .padding(.top, HLSpace.xs)
    }
}
