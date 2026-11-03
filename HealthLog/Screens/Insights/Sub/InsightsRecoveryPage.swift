import SwiftUI

/// The Insights **Recovery** page (web `/insights/recovery`).
///
/// **1.4 B3 — a course, not five numbers.** Two trend cards in the style of
/// the overview's trend row (the recovery score, then the day strain or the
/// training load), each with its last 30 days as a line, and one calm list for
/// everything else with its latest reading and 30-day average. Every card and
/// row opens the detail the rest of the app already shows for that value: the
/// score detail for the recovery score, the metric screen for the others.
///
/// **Server-authoritative.** Values, averages and the empty reason are the
/// server's (`RecoveryInsightsStore`, from `?slice=summaries`); the lines are
/// the readings the metric screen reads. Only types with a reading in the last
/// 30 days appear (`RecoveryPageLayout`). Energy reads in kcal (plan decision
/// 4), a unit choice on a server value.
///
/// **Lives inside the Insights pager.** Owns no `NavigationStack` (the
/// container does); its `ScrollView` reports its offset to
/// `InsightsStripVisibility`. Header anatomy is the shared `InsightsPageHeader`.
struct InsightsRecoveryPage: View {
    @Environment(RecoveryInsightsStore.self) private var store
    @Environment(InsightsStripVisibility.self) private var stripVisibility
    /// Rest Mode rides on the Health Score; while it is active (and the illness
    /// module is on) the page subtitle softens the framing. Values untouched.
    @Environment(HealthScoreStore.self) private var healthScoreStore
    @Environment(ModuleGate.self) private var moduleGate: ModuleGate?
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                InsightsPageHeader(
                    "Recovery",
                    subtitle: restModeActive ? "illness.restMode.caption" : nil,
                    accessibilityIdentifierSuffix: "recovery"
                ) {
                    // 1.4 B4 — the page's one (i): what the page shows, the
                    // method and references behind the recovery score and the
                    // guide, which stood as a loose line under the title.
                    HLInfoButton(
                        content: InsightsSpecialPageInfo.recovery(),
                        style: .circle,
                        accessibilityIdentifier: "insights.recovery.info"
                    )
                }
                pageBody
            }
            .padding(.horizontal, HLSpace.lg)
            .padding(.top, HLSpace.lg)
            .padding(.bottom, HLSpace.xxxl)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newOffset in
            stripVisibility.report(offset: newOffset)
        }
        .hlScrollEdgeSoft()
        .hlPullToRefresh { await store.refresh() }
        .background(HLSurface.primary.ignoresSafeArea())
        .task {
            if store.family == nil { await store.load() }
        }
    }

    @ViewBuilder
    private var pageBody: some View {
        let layout = store.layout
        if store.family == nil, store.isLoading || !store.hasSettledOnce {
            loadingCards
        } else if store.family == nil, store.loadFailed {
            HLRetryUnavailableView { await store.refresh() }
        } else if let empty = layout.empty {
            emptyState(empty)
        } else {
            ForEach(layout.trends) { reading in
                RecoveryTrendLink(reading: reading, readings: store.trendReadings[reading.kind], isLoading: store.isLoading)
            }
            if !layout.rows.isEmpty {
                RecoveryReadingsCard(rows: layout.rows)
            }
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    private var restModeActive: Bool {
        healthScoreStore.score?.activeRestMode != nil && moduleGate?.isEnabled(.illness) == true
    }

    /// Two quiet placeholders in the trend cards' shape while the first load
    /// runs, so the page never flashes its empty note.
    private var loadingCards: some View {
        VStack(spacing: HLSpace.lg) {
            ForEach(0 ..< 2, id: \.self) { _ in
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        HLSkeleton(.capsule, width: 140, height: 16)
                        HLSkeleton(.rect, height: HLChartStyle.heightCompact, cornerRadius: 10)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }

    /// The calm empty note. Its reason is the server's (`recoveryEmpty`):
    /// no wearable reading at all, or nothing from the last 30 days.
    private func emptyState(_ empty: RecoveryPageLayout.Empty) -> some View {
        HLEmptyState(
            icon: "bolt.heart",
            title: empty == .noWearable ? "insights.recovery.empty.title" : "insights.recovery.empty.recentTitle",
            message: empty == .noWearable ? "insights.recovery.empty.body" : nil
        ) {
            HLButton("insights.recovery.empty.action", variant: .secondary) {
                router.requestSettingsIntegrations()
            }
            .accessibilityIdentifier("insights.recovery.empty.action")
        }
        .padding(.top, HLSpace.xl)
        .accessibilityIdentifier("insights.recovery.empty")
    }
}

// MARK: - Trend card

/// One recovery trend card: the overview's `InsightsTrendCard` with a dated
/// 30-day line at the compact chart height, opening the value's detail.
private struct RecoveryTrendLink: View {
    let reading: RecoveryPageLayout.Reading
    /// The metric screen's page of readings for this kind; `nil` until read.
    let readings: [Measurement]?
    let isLoading: Bool

    var body: some View {
        let kind = reading.kind
        let points = RecoveryPageLayout.trendPoints(from: readings ?? [], kind: kind)
        let title = kind.displayName
        let value = RecoveryValueText.value(reading.latest, kind: kind)
        let link = NavigationLink {
            RecoveryDetailDestination(kind: kind)
        } label: {
            InsightsTrendCard(symbol: kind.descriptor.sfSymbol, title: title, valueText: value) {
                if points.count >= 2 {
                    HLTileMetricChart(kind: kind, points: points)
                        .frame(height: HLChartStyle.heightCompact)
                } else if readings == nil, isLoading {
                    HLSkeleton(.rect, height: HLChartStyle.heightCompact, cornerRadius: 10)
                }
            }
        }
        .hlPressable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(title), \(value)"))
        .accessibilityValue(Text(verbatim: RecoveryValueText.average(reading.average30, kind: kind)))
        .accessibilityHint(Text("Double-tap to open detail view"))
        .accessibilityIdentifier("insights.recovery.trend.\(kind.rawValue)")
        // The card speaks as one element; the line keeps its audio graph on it.
        if points.count >= 2 {
            link.accessibilityChartDescriptor(HLTileMetricChart.chartDescriptor(
                kind: kind,
                points: points,
                unit: String(localized: kind.descriptor.unitLabel)
            ))
        } else {
            link
        }
    }
}

// MARK: - List

/// The calm list: one row per remaining current type, latest reading on the
/// right, the 30-day average under the name, each row opening its metric
/// screen.
private struct RecoveryReadingsCard: View {
    let rows: [RecoveryPageLayout.Reading]

    var body: some View {
        HLCard {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, reading in
                    NavigationLink {
                        RecoveryDetailDestination(kind: reading.kind)
                    } label: {
                        HLListRow(
                            title: reading.kind.displayName,
                            subtitle: RecoveryValueText.average(reading.average30, kind: reading.kind),
                            value: RecoveryValueText.value(reading.latest, kind: reading.kind)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Double-tap to open detail view"))
                    .accessibilityIdentifier("insights.recovery.row.\(reading.kind.rawValue)")
                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.recovery.list")
    }
}

// MARK: - Destination

/// What a card or row opens: the detail the app already shows for that value.
/// The recovery score opens the score detail (the overview ring's detail,
/// pushed here); without a score envelope, and for every other type, the
/// metric screen with its full chart. Built only when pushed.
private struct RecoveryDetailDestination: View {
    let kind: MetricKind

    @Environment(\.appContainer) private var appContainer
    @Environment(DerivedInsightsStore.self) private var derivedStore
    @Environment(AppRouter.self) private var router

    var body: some View {
        if kind == .recoveryScore,
           let dto = derivedStore.presentable.first(where: { $0.metric == "RECOVERY_SCORE" })
        {
            WellnessScoreDetailSheet(
                dto: dto,
                onSelectMetric: { router.selectInsightsMetric($0) },
                onSelectMood: { router.selectInsightsSpecial(.mood) },
                embedsNavigationStack: false
            )
        } else if let appContainer {
            // The pager hides the bar for its pages; pushed, the screen needs
            // it for the way back.
            InsightsMetricScreen(kind: kind, store: appContainer.makeChartDetailStore(kind: kind))
                .toolbar(.visible, for: .navigationBar)
        }
    }
}

// MARK: - Value text

/// How the page writes a recovery value. The number is the server's; only the
/// unit is chosen here: day and workout strain on their 0 to 21 scale, energy
/// in kcal (plan decision 4; the server reports kJ, the conversion is the
/// app-wide `MetricKind.UnitFamily.energy`), everything else in the
/// descriptor's own style and unit.
enum RecoveryValueText {
    static func value(_ value: Double, kind: MetricKind) -> String {
        switch kind {
        case .recoveryScore:
            // DIN 5008 in German ("83 %" with a narrow space), "83%" in English.
            guard let whole = Int(safeServer: value.rounded()) else { return Double.emDashPlaceholder }
            return HLNumberFormat.percent(whole)
        case .dayStrain, .workoutStrain:
            return String(localized: "insights.recovery.ofTwentyOne \(MetricValueFormatter.styled(value, style: .decimal1))")
        case .energyExpenditureKJ:
            let units = UnitPreferences.standard
            let number = MetricValueFormatter.account(value, kind: kind, units: units) { $0.safeServerGroupedIntString }
            return "\(number) \(units.unitLabel(for: kind))"
        default:
            let number = MetricValueFormatter.styled(value, style: kind.descriptor.formatStyle)
            let unit = String(localized: kind.descriptor.unitLabel)
            return unit.isEmpty ? number : "\(number) \(unit)"
        }
    }

    /// "Ø 30 Tage 64 bpm".
    static func average(_ value: Double, kind: MetricKind) -> String {
        String(localized: "30-day avg \(Self.value(value, kind: kind))")
    }
}
