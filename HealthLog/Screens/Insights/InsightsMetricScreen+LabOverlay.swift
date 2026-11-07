import SwiftUI

/// **1.5 LAB-LINES** — what sits directly under the metric chart beyond the
/// chart itself, all of it rare and therefore behind "Erweitert":
///
/// - **Laborwert einblenden** (#158, server #1299, v1.46.3): one lab
///   marker on its own axis over the chart's window (``ChartLabOverlay``).
///   Only with the opt-in `timeline` module switched on, as on the web, and
///   with the right to read the timeline: a refusal hides the row.
/// - **Tageszeit** (BP-TOD, server #1331, v1.47.0): the blood pressure chart
///   narrowed to the morning, midday or evening (``PartOfDayChart``).
///
/// A page where neither applies shows nothing here, not even the link. A
/// chosen marker shows under the chart whether "Erweitert" is open or not.
struct InsightsChartExtras: View {
    let kind: MetricKind
    let store: ChartDetailStore

    @Environment(BackendAvailability.self) private var backend
    @Environment(\.appContainer) private var appContainer
    /// The version the last `/api/version` probe recorded, observed so the
    /// options appear as soon as the foreground probe lands.
    @AppStorage(KnownServerVersion.defaultsKey) private var serverVersion: String?
    @State private var labModel: ChartLabOverlayModel?
    @State private var expanded = false
    @State private var labAttempt = 0

    // MARK: - Gates (pure, testable)

    /// The lab row: a paired server that has `labSeries` (1.46.3, unknown is
    /// no) and the `timeline` module switched on. The module is opt-in, so a
    /// map without the key is off too.
    nonisolated static func labOverlayAvailable(hasServer: Bool, serverVersion: String?, timelineModule: Bool?) -> Bool {
        guard hasServer, timelineModule == true, let serverVersion else { return false }
        return ServerVersionInfo(version: serverVersion).isAtLeast(TimelineRepository.minimumServerVersion)
    }

    /// The part-of-day row: the blood pressure page of a paired 1.47 server.
    nonisolated static func partOfDayAvailable(kind: MetricKind, hasServer: Bool, serverVersion: String?) -> Bool {
        guard kind == .bloodPressure, hasServer, let serverVersion else { return false }
        return ServerVersionInfo(version: serverVersion).isAtLeast(BloodPressureTimeOfDayRepository.minimumServerVersion)
    }

    private var labAvailable: Bool {
        Self.labOverlayAvailable(
            hasServer: backend.canShowCloudInsights,
            serverVersion: serverVersion,
            // The gate lives on the container (it is not in the environment).
            timelineModule: appContainer?.moduleGate.modules?["timeline"]
        ) && labModel?.isRefused != true
    }

    /// From a week up only: a single day has no daily means to narrow.
    private var partAvailable: Bool {
        Self.partOfDayAvailable(kind: kind, hasServer: backend.canShowCloudInsights, serverVersion: serverVersion)
            && ChartDetailStore.partOfDayApplies(kind: kind, range: store.range)
            && !store.partOfDayChart.isUnsupported
    }

    // MARK: - Body

    var body: some View {
        if labAvailable || partAvailable {
            VStack(spacing: HLSpace.sm) {
                if labAvailable, let labModel {
                    labOverlay(labModel)
                }
                advancedLink
                if expanded {
                    options
                        .transition(.opacity)
                }
            }
            .task(id: LabLoadKey(days: store.range.rawValue, marker: labModel?.selectedKey, attempt: labAttempt)) {
                guard labAvailable else { return }
                // A new model carries the remembered marker; that changes this
                // task's key, and the rerun reads it. No marker, nothing to read.
                guard let model = labModel else {
                    _ = resolvedLabModel()
                    return
                }
                await model.load(days: store.range.rawValue)
            }
            .task(id: PartLoadKey(part: store.activePartOfDay, days: store.range.rawValue)) {
                await store.loadPartOfDay()
            }
        }
    }

    // MARK: - Lab marker under the chart

    @ViewBuilder
    private func labOverlay(_ model: ChartLabOverlayModel) -> some View {
        switch model.phase {
        case .idle, .missing:
            EmptyView()
        case .loading:
            HLCard {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: ChartLabOverlay.chartHeight)
            }
            .accessibilityIdentifier("insights.labOverlay.loading")
        case let .loaded(series):
            ChartLabOverlay(series: series, window: chartWindow, isRefreshing: model.isRefreshing)
        case .failed:
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("insights.labOverlay.error")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HLButton("Retry", variant: .secondary) { labAttempt += 1 }
                        .accessibilityIdentifier("insights.labOverlay.retry")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The chart's window on the day axis: the first day's start to the end of today.
    private var chartWindow: ClosedRange<Date> {
        let calendar = Calendar.current
        let window = ChartDetailStore.partOfDayWindow(days: store.range.rawValue, now: .now, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: window.to)) ?? window.to
        return window.from ... end
    }

    // MARK: - "Erweitert"

    private var advancedLink: some View {
        Button {
            withHLAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
        } label: {
            HStack(spacing: HLSpace.xs) {
                Text("Advanced")
                    .font(.hlSubhead.weight(.semibold))
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.hlIcon(HLIconSize.sm))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(HLText.secondary)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("insights.metric.advanced")
        .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
    }

    private var options: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                if partAvailable {
                    optionRow("chart.partOfDay.title") { partPicker }
                }
                if labAvailable {
                    optionRow("insights.labOverlay.choose") { labChoice }
                        .task {
                            guard let model = resolvedLabModel() else { return }
                            await model.loadChoices()
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func optionRow(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> some View) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: HLSpace.sm) {
                Text(title)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                Spacer(minLength: HLSpace.sm)
                trailing()
            }
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(title)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                trailing()
            }
        }
        .frame(minHeight: 44)
    }

    private var partPicker: some View {
        Picker(selection: Binding(
            get: { store.activePartOfDay },
            set: { store.choosePartOfDay($0) }
        )) {
            Text("chart.partOfDay.wholeDay").tag(BloodPressureTimeOfDay.Part?.none)
            ForEach(BloodPressureTimeOfDay.Part.allCases, id: \.self) { part in
                Text(verbatim: BloodPressureTimeOfDaySection.name(part)).tag(Optional(part))
            }
        } label: {
            Text("chart.partOfDay.title")
        }
        .pickerStyle(.menu)
        .tint(HLText.secondary)
    }

    @ViewBuilder
    private var labChoice: some View {
        if let labModel {
            switch labModel.choices {
            case .notLoaded, .loading:
                ProgressView()
                    .accessibilityLabel(Text("Loading"))
            case .failed:
                Button {
                    labModel.retryChoices()
                    Task { await labModel.loadChoices() }
                } label: {
                    Text("Retry")
                        .font(.hlSubhead.weight(.semibold))
                }
                .accessibilityIdentifier("insights.labOverlay.choice.retry")
            case let .loaded(markers):
                if markers.isEmpty {
                    Text("insights.labOverlay.noMarkers")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                } else {
                    labPicker(labModel, markers: markers)
                }
            }
        }
    }

    private func labPicker(_ model: ChartLabOverlayModel, markers: [TimelineLabMarker]) -> some View {
        let keys = Set(markers.map(\.key))
        return Picker(selection: Binding(
            get: { model.selectedKey.flatMap { keys.contains($0) ? $0 : nil } },
            set: { model.select($0) }
        )) {
            Text("insights.labOverlay.none").tag(String?.none)
            ForEach(ChartLabOverlayModel.groups(markers)) { group in
                Section {
                    ForEach(group.markers) { marker in
                        Text(verbatim: marker.name).tag(Optional(marker.key))
                    }
                } header: {
                    if let panel = group.panel {
                        Text(verbatim: panel)
                    } else {
                        Text("insights.labOverlay.otherPanel")
                    }
                }
            }
        } label: {
            Text("insights.labOverlay.choose")
        }
        .pickerStyle(.menu)
        .tint(HLText.secondary)
    }

    private func resolvedLabModel() -> ChartLabOverlayModel? {
        if let labModel { return labModel }
        guard let api = appContainer?.api else { return nil }
        let created = ChartLabOverlayModel(kind: kind, repository: TimelineRepository(api: api))
        labModel = created
        return created
    }

    private struct LabLoadKey: Equatable {
        let days: Int
        let marker: String?
        let attempt: Int
    }

    private struct PartLoadKey: Equatable {
        let part: BloodPressureTimeOfDay.Part?
        let days: Int
    }
}

// MARK: - Usual range (coach-read) for the chart card

extension InsightsMetricScreen {
    /// The usual-range sentence at the top of the chart card, or `nil`.
    var coachReadHeadline: String? {
        ChartCoachReadLine.text(coachRead, kind: kind, units: settingsStore.unitPreferences)
    }

    /// Reads `coach-read` once per page. Any failure leaves the card without
    /// the line, as in 1.4: it is a sentence about the chart, not the chart.
    func loadCoachRead() async {
        guard backend.canShowCloudInsights,
              let metric = CoachReadRepository.metric(for: kind),
              let api = appContainer?.api else { return }
        coachRead = try? await CoachReadRepository(api: api).fetch(metric: metric)
    }
}
