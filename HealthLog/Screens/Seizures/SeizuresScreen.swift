import SwiftUI

/// **The seizure diary** (server v1.48.0, #1368, #182 A4; web
/// `/seizures`). The quick log on top, then the server's summary of the last
/// 90 days, then the recorded seizures; the types and the cluster rule from
/// the page's menu. Built like the illness journal: one `List` root from the
/// first frame, two-line rows, the detail page a push.
///
/// Offered only while the server's module map names `seizures` and says on
/// (``SeizuresModule``); a `403 seizures.disabled` mid-flight shows the
/// switched-off note instead of an error. The store is the container's, so a
/// running timer survives leaving the page.
struct SeizuresScreen: View {
    @Environment(\.appContainer) private var container

    @State private var sheet: SeizureSheet?
    @State private var showTypes = false

    private var store: SeizuresStore? {
        container?.seizuresStore
    }

    var body: some View {
        Group {
            if let store, store.isDisabled {
                HLEmptyState(icon: SeizureSymbols.module, title: "seizures.title", message: "seizures.module.offDescription")
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                HLAsyncListScreen(
                    phase: phase,
                    refresh: { await store?.load() },
                    loading: {
                        SectionRootHeader("seizures.title", inList: true)
                        HLAsyncListSkeletonRows()
                    },
                    empty: {
                        SectionRootHeader("seizures.title", inList: true)
                    },
                    content: {
                        SectionRootHeader("seizures.title", inList: true)
                        if let store { loadedRows(store: store) }
                    }
                )
                .hlPageMargins()
            }
        }
        .hlSectionRootTitle(Text("seizures.title"), headsItself: store?.isDisabled != true && !phase.isError)
        .hlPageActions(store?.isDisabled == true ? .none : pageActions)
        .accessibilityIdentifier("seizures.screen")
        .task { await store?.load() }
        .sheet(item: $sheet) { sheet in
            if let store { sheetContent(sheet, store: store) }
        }
        .navigationDestination(for: SeizureEventRoute.self) { route in
            if let store { SeizureEventDetailScreen(store: store, eventID: route.id) }
        }
        .navigationDestination(isPresented: $showTypes) {
            if let store { SeizureTypesScreen(store: store) }
        }
    }

    private var pageActions: HLTabHeaderActions {
        [
            .more(identifier: "seizures.toolbar.more") {
                Button("seizures.types.manage", systemImage: "list.bullet") { showTypes = true }
                    .accessibilityIdentifier("seizures.toolbar.types")
                Button("seizures.rule.title", systemImage: "clock.arrow.2.circlepath") { sheet = .rule }
                    .accessibilityIdentifier("seizures.toolbar.rule")
            },
            .add(label: "seizures.sheet.newTitle", identifier: "seizures.toolbar.add") { sheet = .new }
        ]
    }

    private var phase: HLAsyncListPhase {
        guard let store else { return .loading }
        if store.diary == nil {
            if store.lastError != nil, !store.isLoading { return .error(retry: { await store.load() }) }
            return .loading
        }
        return .loaded
    }

    @ViewBuilder
    private func sheetContent(_ sheet: SeizureSheet, store: SeizuresStore) -> some View {
        switch sheet {
        case .new: SeizureEventSheet(store: store, editing: nil)
        case let .edit(event): SeizureEventSheet(store: store, editing: event)
        case .rule: SeizureRuleSheet(store: store)
        }
    }

    @ViewBuilder
    private func loadedRows(store: SeizuresStore) -> some View {
        Section {
            SeizureQuickLogCard(
                store: store,
                onAddDetails: { event in
                    store.dismissRecorded()
                    sheet = .edit(event)
                },
                onLogPast: { sheet = .new },
                onManageTypes: { showTypes = true }
            )
        } header: {
            HLSectionHeader("seizures.quick.title")
        } footer: {
            Text("seizures.safety.header")
        }
        .hlFormRowSurface()
        if let diary = store.diary, let summary = diary.summary {
            SeizureSummarySection(summary: summary, rule: diary.settings.rule)
        }
        eventsSection(store: store)
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    @ViewBuilder
    private func eventsSection(store: SeizuresStore) -> some View {
        let diary = store.diary
        let events = diary?.events ?? []
        let clustered = diary?.summary?.clusteredEventIDs ?? []
        Section {
            if events.isEmpty {
                Text("seizures.list.empty")
                    .hlText(.note)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("seizures.list.empty")
            }
            ForEach(events) { event in
                SeizureEventRow(event: event, diary: diary, clustered: clustered.contains(event.id))
                    .hlRowLink(inList: true) {
                        SeizureEventDetailScreen(store: store, eventID: event.id)
                    }
                    .hlSwipeDelete(.confirmed(title: "seizures.sheet.deleteTitle", message: "seizures.sheet.deleteBody") {
                        await store.delete(event)
                    }) {
                        Button("seizures.detail.edit", systemImage: "pencil") { sheet = .edit(event) }
                            .tint(HLAccent.userBrandTint)
                    }
            }
        } header: {
            HLSectionHeader("seizures.list.title")
        } footer: {
            if diary?.truncated == true {
                Text("seizures.list.truncated")
            }
        }
        .hlFormRowSurface()
    }
}

/// One seizure on a navigation path (a `SEIZURE_CLUSTER` tap on 1.49.0).
struct SeizureEventRoute: Hashable {
    let id: String
}

/// What the diary page presents.
enum SeizureSheet: Identifiable, Equatable {
    case new
    case edit(SeizureEventDTO)
    case rule

    var id: String {
        switch self {
        case .new: "new"
        case let .edit(event): "edit-\(event.id)"
        case .rule: "rule"
        }
    }
}

/// One seizure in the list: its type, when and how long, and one quiet
/// status (suspected, cluster, rescue). The whole row opens the seizure.
struct SeizureEventRow: View {
    let event: SeizureEventDTO
    let diary: SeizureDiaryDTO?
    var clustered = false

    var body: some View {
        let title = SeizurePresentation.typeName(of: event, in: diary)
        let detail = SeizurePresentation.detail(event)
        HLRow(
            title: Text(verbatim: title),
            detail: detail.map { Text(verbatim: $0) },
            status: SeizurePresentation.status(event, clustered: clustered).map { HLRowStatus($0) }
        ) {
            HLRowGlyph(symbol: SeizureSymbols.module)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("seizures.list.row")
    }
}

/// The server's summary of the period, rendered as sent.
struct SeizureSummarySection: View {
    let summary: SeizureDiarySummaryDTO
    let rule: SeizureClusterRule

    var body: some View {
        Section {
            row(Text("seizures.summary.recorded \(sinceText)"), value: summary.seizures)
            row(Text("seizures.summary.seizureDays"), value: summary.seizureDays)
            if let since = summary.streak.daysSinceLast {
                row(Text("seizures.summary.sinceLast"), value: since)
            }
            row(Text("seizures.summary.longestFree"), value: summary.streak.longestFreeDays)
            row(Text("seizures.summary.clusters \(SeizurePresentation.ruleText(rule))"), value: summary.clusters.count)
            row(Text("seizures.summary.niceClusters"), value: summary.niceClusterCount)
        } header: {
            HLSectionHeader("seizures.summary.title")
        } footer: {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                if summary.suspected > 0 {
                    Text("seizures.summary.suspected \(summary.suspected)")
                }
                Text("seizures.summary.undercount")
            }
        }
        .hlFormRowSurface()
        .accessibilityIdentifier("seizures.summary")
    }

    private var sinceText: String {
        SeizureDateFormat.parse(summary.from).map { HLDateFormat.date($0, style: .abbreviated) } ?? summary.from
    }

    private func row(_ title: Text, value: Int) -> some View {
        HLRow(title: title, value: Text(verbatim: value.formatted())) { EmptyView() }
    }
}
