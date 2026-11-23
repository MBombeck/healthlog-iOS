import SwiftUI

/// Filtered, paginated mood history. Its page state is intentionally separate
/// from `MoodStore.entries`, which remains the broad dashboard/insights input.
struct MoodHistoryScreen: View {
    @Environment(MoodStore.self) private var store

    @State private var draftFilter = MoodHistoryFilter()
    @State private var appliedFilter = MoodHistoryFilter()
    @State private var historyEntries: [MoodEntry] = []
    @State private var meta: MeasurementListResponse.ListMeta?
    @State private var isLoading = false
    @State private var loadError: HLError?
    @State private var reloadID = UUID()
    @State private var activeRequestID: UUID?
    @State private var editing: MoodEntry?

    private static let pageSize = 25

    private struct MonthBucket: Identifiable {
        let id: Date
        let title: String
        let entries: [MoodEntry]
    }

    private var buckets: [MonthBucket] {
        let calendar = Calendar.current
        let sorted = Self.visible(historyEntries).sorted { $0.recordedAt > $1.recordedAt }
        let grouped = Dictionary(grouping: sorted) { entry -> Date in
            let components = calendar.dateComponents([.year, .month], from: entry.recordedAt)
            return calendar.date(from: components) ?? calendar.startOfDay(for: entry.recordedAt)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { date, entries in
                MonthBucket(
                    id: date,
                    title: HLDateFormat.monthYear(date),
                    entries: entries
                )
            }
    }

    /// An entry dated after now (a clock or an import off by a day) does not
    /// stand at the top of the history.
    static func visible(_ entries: [MoodEntry], now: Date = .now) -> [MoodEntry] {
        entries.filter { $0.recordedAt <= now }
    }

    private var hasMore: Bool {
        guard let total = meta?.total else { return false }
        return historyEntries.count < total
    }

    var body: some View {
        List {
            filterSection

            if let loadError, historyEntries.isEmpty {
                Section {
                    HLErrorState(LocalizedStringKey(loadError.userFacingDescription)) {
                        reloadID = UUID()
                    }
                }
                .hlFormRowSurface()
            } else if isLoading, historyEntries.isEmpty {
                HLAsyncListSkeletonRows(rowCount: 4)
                    .hlFormRowSurface()
            } else if historyEntries.isEmpty {
                Section { emptyState }
                    .hlFormRowSurface()
            } else {
                ForEach(buckets) { bucket in
                    Section {
                        ForEach(bucket.entries) { entry in
                            // The store keeps the way back: the entry goes at
                            // once and the undo hint appears.
                            MoodEntryRow(entry: entry)
                                .hlSwipeDelete(.undoable {
                                    if await store.delete(entry) { reloadID = UUID() }
                                }, also: {
                                    Button(HLControlWord.edit.key, systemImage: "pencil") {
                                        editing = entry
                                    }
                                    .tint(.accentColor)
                                })
                        }
                    } header: {
                        HLSectionHeader(verbatim: bucket.title, rank: .group)
                    }
                    .hlFormRowSurface()
                }
                if hasMore {
                    // The last row loads the next page by itself, like every
                    // other long list.
                    Section {
                        HLLoadMoreRow(hasMore: hasMore, isLoading: isLoading, trigger: .onAppear) {
                            Task { await load(reset: false) }
                        }
                    }
                    .hlFormRowSurface()
                }
            }
        }
        .hlPageMargins()
        .hlScrollEdgeSoft()
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadID) {
            await load(reset: true)
        }
        .sheet(item: $editing) { entry in
            EditMoodSheet(entry: entry) {
                editing = nil
                reloadID = UUID()
            }
        }
    }

    private var filterSection: some View {
        Section {
            HLFormPicker("Period", selection: periodBinding, options: MoodHistoryPeriod.allCases) {
                Text(Self.periodLabel($0))
            }
            if draftFilter.period == .custom {
                DatePicker(selection: customFromBinding, displayedComponents: .date) {
                    HLRowTitle("From")
                }
                .environment(\.timeZone, ProfileDay.timeZone)
                DatePicker(selection: customToBinding, displayedComponents: .date) {
                    HLRowTitle("To")
                }
                .environment(\.timeZone, ProfileDay.timeZone)
            }
            // `serverCases`: the sentinel is not a level a person can
            // filter FOR, and the server would reject it.
            HLFormPicker(
                "Mood",
                selection: moodBinding,
                options: [""] + ServerMoodLevel.serverCases.map(\.rawValue)
            ) { raw in
                ServerMoodLevel(rawValue: raw).map { Text(MoodCopy.levelLabel($0.score)) } ?? Text("All moods")
            }
            HLFormPicker(
                "Source",
                selection: $draftFilter.source,
                options: [MoodEntrySource?.none] + MoodEntrySource.allCases.map { MoodEntrySource?.some($0) }
            ) { source in
                source.map { Text(sourceLabel($0)) } ?? Text("All sources")
            }
            HStack {
                if draftFilter != MoodHistoryFilter() {
                    HLLinkButton("Reset", alignment: .leading) {
                        draftFilter.reset()
                        appliedFilter = draftFilter
                        reloadID = UUID()
                    }
                    .fixedSize()
                }
                Spacer()
                // The count names what it counts.
                if let total = meta?.total {
                    Text("\(total) entries")
                        .hlText(.rowSubtitle)
                }
                // The quiet text action of the app; each link keeps its own
                // tap inside the row.
                HLLinkButton("Apply", alignment: .leading) {
                    appliedFilter = draftFilter
                    reloadID = UUID()
                }
                .fixedSize()
            }
        } header: {
            HLSectionHeader("Filters", rank: .group)
        }
        .hlFormRowSurface()
    }

    private var moodBinding: Binding<String> {
        Binding(
            get: { draftFilter.mood?.rawValue ?? "" },
            set: { draftFilter.mood = ServerMoodLevel(rawValue: $0) }
        )
    }

    private var periodBinding: Binding<MoodHistoryPeriod> {
        Binding(
            get: { draftFilter.period },
            set: { period in
                draftFilter.period = period
                if period == .custom {
                    // The account's last 29 days, not the phone's.
                    let range = MoodHistoryFilter.defaultCustomRange()
                    if draftFilter.customFrom == nil { draftFilter.customFrom = range.from }
                    if draftFilter.customTo == nil { draftFilter.customTo = range.to }
                }
            }
        )
    }

    /// The pickers run in the profile zone (see `filterSection`), so a day key
    /// and the picker's instant convert through ``ProfileDay`` both ways.
    private var customFromBinding: Binding<Date> {
        Binding(
            get: { Self.pickerDate(draftFilter.customFrom ?? MoodHistoryFilter.defaultCustomRange().from) },
            set: { draftFilter.customFrom = ProfileDay.key(for: $0) }
        )
    }

    private var customToBinding: Binding<Date> {
        Binding(
            get: { Self.pickerDate(draftFilter.customTo ?? MoodHistoryFilter.defaultCustomRange().to) },
            set: { draftFilter.customTo = ProfileDay.key(for: $0) }
        )
    }

    private static func pickerDate(_ key: String) -> Date {
        ProfileDay.startOfDay(forKey: key) ?? .now
    }

    private static func periodLabel(_ period: MoodHistoryPeriod) -> LocalizedStringKey {
        switch period {
        case .all: "All time"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .last90Days: "Last 90 days"
        case .lastYear: "Last year"
        case .custom: "Custom"
        }
    }

    private func sourceLabel(_ source: MoodEntrySource) -> LocalizedStringKey {
        switch source {
        case .manual: "Manual"
        case .moodlog: "moodLog"
        case .web: "Web"
        case .telegram: "Telegram"
        case .daylio: "Daylio"
        case .notification: "mood.source.notification"
        }
    }

    private func load(reset: Bool) async {
        if isLoading, !reset { return }
        let requestID = UUID()
        activeRequestID = requestID
        isLoading = true
        defer {
            if activeRequestID == requestID {
                isLoading = false
            }
        }
        if reset {
            loadError = nil
            historyEntries = []
            meta = nil
        }
        let offset = reset ? 0 : historyEntries.count
        do {
            let response = try await store.history(
                query: appliedFilter.query(limit: Self.pageSize, offset: offset)
            )
            guard activeRequestID == requestID else { return }
            if reset {
                historyEntries = response.entries
            } else {
                let existingIDs = Set(historyEntries.map(\.id))
                historyEntries.append(contentsOf: response.entries.filter {
                    !existingIDs.contains($0.id)
                })
            }
            meta = response.meta
            loadError = nil
        } catch is CancellationError {
            return
        } catch let error as HLError {
            guard activeRequestID == requestID else { return }
            loadError = error
        } catch {
            guard activeRequestID == requestID else { return }
            loadError = .unknown(error.localizedDescription)
        }
    }

    private var emptyState: some View {
        // "log your first mood" was wrong under an active filter;
        // the title is true either way.
        HLEmptyState(icon: "face.smiling", title: Text("No entries"))
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLLayout.sectionGapBefore)
    }
}
