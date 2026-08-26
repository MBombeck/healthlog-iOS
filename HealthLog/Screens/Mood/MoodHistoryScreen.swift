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
    @State private var deleteConfirmTarget: MoodEntry?

    private static let pageSize = 25

    private struct MonthBucket: Identifiable {
        let id: Date
        let title: String
        let entries: [MoodEntry]
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter
    }()

    private static let wireDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var buckets: [MonthBucket] {
        let calendar = Calendar.current
        let sorted = historyEntries.sorted { $0.recordedAt > $1.recordedAt }
        let grouped = Dictionary(grouping: sorted) { entry -> Date in
            let components = calendar.dateComponents([.year, .month], from: entry.recordedAt)
            return calendar.date(from: components) ?? calendar.startOfDay(for: entry.recordedAt)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { date, entries in
                MonthBucket(
                    id: date,
                    title: Self.monthFormatter.string(from: date),
                    entries: entries
                )
            }
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
                    ContentUnavailableView {
                        Label("Could not load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError.userFacingDescription)
                    } actions: {
                        Button("Retry") { reloadID = UUID() }
                    }
                }
            } else if isLoading, historyEntries.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if historyEntries.isEmpty {
                Section { emptyState }
            } else {
                ForEach(buckets) { bucket in
                    Section(bucket.title) {
                        ForEach(bucket.entries) { entry in
                            MoodEntryRow(entry: entry)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deleteConfirmTarget = entry
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        editing = entry
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.accentColor)
                                }
                        }
                    }
                }
                if hasMore {
                    Section {
                        Button("Load more") {
                            Task { await load(reset: false) }
                        }
                        .disabled(isLoading)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .hlScreenBackground()
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
        .hlConfirmDestructive(
            Text("Delete entry?"),
            isPresented: Binding(
                get: { deleteConfirmTarget != nil },
                set: { if !$0 { deleteConfirmTarget = nil } }
            ),
            message: Text("This action cannot be undone."),
            confirm: Text("Delete"),
            cancel: Text("Cancel"),
            onCancel: { deleteConfirmTarget = nil },
            action: {
                guard let entry = deleteConfirmTarget else { return }
                deleteConfirmTarget = nil
                Task {
                    if await store.delete(entry) {
                        reloadID = UUID()
                    }
                }
            }
        )
    }

    private var filterSection: some View {
        Section {
            Picker("Period", selection: periodBinding) {
                Text("All time").tag(MoodHistoryPeriod.all)
                Text("Last 7 days").tag(MoodHistoryPeriod.last7Days)
                Text("Last 30 days").tag(MoodHistoryPeriod.last30Days)
                Text("Last 90 days").tag(MoodHistoryPeriod.last90Days)
                Text("Last year").tag(MoodHistoryPeriod.lastYear)
                Text("Custom").tag(MoodHistoryPeriod.custom)
            }
            if draftFilter.period == .custom {
                DatePicker("From", selection: customFromBinding, displayedComponents: .date)
                DatePicker("To", selection: customToBinding, displayedComponents: .date)
            }
            Picker("Mood", selection: moodBinding) {
                Text("All moods").tag("")
                ForEach(ServerMoodLevel.allCases, id: \.rawValue) { mood in
                    Text(MoodCopy.scoreLabel(mood.score)).tag(mood.rawValue)
                }
            }
            Picker("Source", selection: $draftFilter.source) {
                Text("All sources").tag(MoodEntrySource?.none)
                ForEach(MoodEntrySource.allCases) { source in
                    Text(sourceLabel(source)).tag(Optional(source))
                }
            }
            HStack {
                if draftFilter != MoodHistoryFilter() {
                    Button("Reset") {
                        draftFilter.reset()
                        appliedFilter = draftFilter
                        reloadID = UUID()
                    }
                }
                Spacer()
                if let total = meta?.total {
                    Text("\(total)")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
                Button("Apply") {
                    appliedFilter = draftFilter
                    reloadID = UUID()
                }
                .buttonStyle(.borderedProminent)
            }
        } header: {
            Text("Filters")
        }
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
                    if draftFilter.customFrom == nil {
                        let date = Calendar.current.date(byAdding: .day, value: -29, to: .now) ?? .now
                        draftFilter.customFrom = Self.wireDateFormatter.string(from: date)
                    }
                    if draftFilter.customTo == nil {
                        draftFilter.customTo = Self.wireDateFormatter.string(from: .now)
                    }
                }
            }
        )
    }

    private var customFromBinding: Binding<Date> {
        Binding(
            get: {
                draftFilter.customFrom.flatMap(Self.wireDateFormatter.date(from:))
                    ?? Calendar.current.date(byAdding: .day, value: -29, to: .now)
                    ?? .now
            },
            set: { draftFilter.customFrom = Self.wireDateFormatter.string(from: $0) }
        )
    }

    private var customToBinding: Binding<Date> {
        Binding(
            get: {
                draftFilter.customTo.flatMap(Self.wireDateFormatter.date(from:)) ?? .now
            },
            set: { draftFilter.customTo = Self.wireDateFormatter.string(from: $0) }
        )
    }

    private func sourceLabel(_ source: MoodEntrySource) -> LocalizedStringKey {
        switch source {
        case .manual: "Manual"
        case .moodlog: "moodLog"
        case .web: "Web"
        case .telegram: "Telegram"
        case .daylio: "Daylio"
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
        HLEmptyState(
            icon: "face.smiling",
            title: Text("No entries"),
            message: Text("Log your first mood to see your history.")
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpace.xxl)
    }
}
