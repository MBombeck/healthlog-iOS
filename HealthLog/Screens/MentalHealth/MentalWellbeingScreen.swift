import SwiftUI

/// Opt-in mental-health self-checks beside mood tracking. The landing stays
/// neutral: four instrument cards, with history available only in a deliberate
/// per-instrument detail sheet.
struct MentalWellbeingScreen: View {
    @Environment(\.appContainer) private var container

    @State private var store: MentalHealthStore?
    @State private var showAbortConfirm = false
    @State private var detailInstrument: MentalHealthInstrument?

    var body: some View {
        HLPage {
            // The landing heads itself as a sidebar tab; a check in progress
            // keeps the inline title that names the instrument.
            if (store?.phase ?? .choose) == .choose {
                SectionRootHeader("more.mentalWellbeing.title")
            }
            if let store {
                switch store.phase {
                case .choose:
                    chooseSection(store: store)
                case .form:
                    MentalWellbeingForm(store: store)
                case .result:
                    MentalWellbeingResult(store: store)
                }
                if store.phase != .form {
                    HLSyncStatusFooter(screenLoading: store.isLoading)
                }
            }
        }
        .hlSectionRootTitle(navigationTitle, headsItself: (store?.phase ?? .choose) == .choose)
        .navigationBarBackButtonHidden(store?.phase == .form)
        .toolbar { abortToolbar }
        .hlConfirmDestructive(
            Text("mentalHealth.abort.confirm.title"),
            isPresented: $showAbortConfirm,
            message: Text("mentalHealth.abort.confirm.message"),
            confirm: Text("mentalHealth.abort.confirm.discard"),
            cancel: Text("mentalHealth.abort.confirm.keep"),
            action: {
                store?.backToChoose()
            }
        )
        .sheet(item: $detailInstrument) { instrument in
            if let store {
                MentalHealthInstrumentDetail(
                    instrument: instrument,
                    store: store,
                    onStart: {
                        detailInstrument = nil
                        store.begin(instrument)
                    }
                )
            }
        }
        // G5 (decision E5, 2026-08-22) — the „i" popover is gone, ersatzlos.
        // It carried the WHO-5 / SCI attribution as English licence prose at
        // popover size, which is unreadable where it mattered and redundant
        // where it did not: the same attribution stands in the detail sheet, on
        // the instrument it belongs to. Removing the popover is therefore a
        // deletion of a DUPLICATE, not of an obligation —
        // `MentalWellbeingConsistencyTests.attributionSurvivesInTheDetailSheet`
        // is what keeps that sentence true.
        .hlRefresh(in: .list) { await store?.load() }
        .task { await onAppear() }
    }

    /// While a check-in runs the page is named after it; otherwise after
    /// the area.
    private var navigationTitle: Text {
        if let store, store.phase == .form {
            return Text(LocalizedStringKey(Self.instrumentTitleKey(store.activeInstrument)))
        }
        return Text("more.mentalWellbeing.title")
    }

    /// The catalogue key of an instrument's name, built as a whole string so
    /// it is not looked up as a format.
    nonisolated static func instrumentTitleKey(_ instrument: MentalHealthInstrument) -> String {
        "mentalHealth.instrument.\(instrument.keySegment)"
    }

    @ToolbarContentBuilder private var abortToolbar: some ToolbarContent {
        if let store, store.phase == .form {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if store.hasAnswers {
                        showAbortConfirm = true
                    } else {
                        store.backToChoose()
                    }
                } label: {
                    // The check-in is a step inside the page, not a page of its
                    // own: it is left like a form, with the cross, and asks
                    // first once answers would be lost.
                    Label(HLControlWord.cancel.key, systemImage: "xmark")
                }
                .accessibilityIdentifier("mentalHealth.abort")
            }
        }
    }

    /// The header used to open with `mentalHealth.pageTitle`, which is the
    /// same words as the navigation title („Seelisches Wohlbefinden") one line
    /// above it. The description paragraph under it is gone too; the
    /// four cards say what the screen offers, the detail sheet shows the trend.
    private func chooseSection(store: MentalHealthStore) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            HLSectionHeader("mentalHealth.choosePrompt", rank: .area)

            if store.isLoading, store.history.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .accessibilityLabel(Text("mentalHealth.history.chartTitle"))
            } else if store.lastError != nil, store.history.isEmpty {
                historyError {
                    await store.load()
                }
            } else {
                ForEach(MentalHealthInstrument.allCases) { instrument in
                    MentalHealthInstrumentCard(
                        instrument: instrument,
                        last: store.history.first { $0.instrument == instrument },
                        onOpenDetail: {
                            store.beginDetail(instrument)
                            detailInstrument = instrument
                        },
                        onStart: {
                            store.begin(instrument)
                        }
                    )
                }
            }
        }
    }

    private func historyError(retry: @escaping () async -> Void) -> some View {
        HLErrorState("mentalHealth.historyLoadErrorHint", retry: retry)
    }

    private func onAppear() async {
        if store == nil {
            store = container?.mentalHealthStore
        }
        await store?.load()
    }
}

/// Neutral card per instrument: its name and what it asks as the card head,
/// the details behind the info symbol, the last result as facts, and Start.
private struct MentalHealthInstrumentCard: View {
    let instrument: MentalHealthInstrument
    let last: MentalHealthAssessmentDTO?
    let onOpenDetail: () -> Void
    let onStart: () -> Void

    var body: some View {
        HLCard(
            localizedKey(MentalWellbeingScreen.instrumentTitleKey(instrument)),
            subtitle: localizedKey("mentalHealth.instrumentSub.\(instrument.keySegment)")
        ) {
            HLIconButton(systemImage: "info.circle", label: "mentalHealth.openDetail", action: onOpenDetail)
                .accessibilityLabel(detailAccessibilityLabel)
                .accessibilityIdentifier("mentalHealth.detail.\(instrument.keySegment)")
        } content: {
            if let last {
                HLFactGroup {
                    HLFactRow("mentalHealth.lastResult", value: MentalHealthDateFormat.short(last.takenAt))
                    HLFactRow("mentalHealth.lastScore", value: "\(last.totalScore) (\(bandLabel(last)))")
                }
            }
            // Without a result the card shows title and Start; four
            // identical "no check-in yet" lines said what Start implies.

            // The card's Start is the quieter action of a card, the same
            // secondary button as every other card; the detail sheet's own
            // Start stays primary, that one is the sheet's commit action.
            HLButton("mentalHealth.start", variant: .secondary, action: onStart)
                .frame(maxWidth: HLLayout.actionMaxWidth)
                .accessibilityIdentifier("mentalHealth.choose.\(instrument.keySegment)")
        }
    }

    private func bandLabel(_ row: MentalHealthAssessmentDTO) -> String {
        NSLocalizedString(
            "mentalHealth.band.\(row.instrument.rawValue).\(row.severityBand)",
            comment: "Mental-health severity band label"
        )
    }

    private var detailAccessibilityLabel: String {
        let title = NSLocalizedString(
            "mentalHealth.instrument.\(instrument.keySegment)",
            comment: "Mental-health instrument title"
        )
        return "\(title), \(String(localized: "mentalHealth.openDetail"))"
    }

    /// Wraps a key built as a whole string; a literal with an interpolation
    /// would be looked up as a format with a placeholder.
    private func localizedKey(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }
}

private struct MentalHealthInstrumentDetail: View {
    let instrument: MentalHealthInstrument
    @Bindable var store: MentalHealthStore
    let onStart: () -> Void
    /// Height of the page's content, so a first check-in without history
    /// opens a short sheet instead of a half-empty one.
    @State private var contentHeight: CGFloat = 0

    /// The instrument's catalog key, built first so the key is looked up
    /// as a whole and not as a format with a placeholder.
    private var titleKey: String {
        "mentalHealth.instrument.\(instrument.keySegment)"
    }

    private var rows: [MentalHealthAssessmentDTO] {
        store.detailHistory.sorted { lhs, rhs in
            (MentalHealthDateFormat.date(lhs.takenAt) ?? .distantPast)
                > (MentalHealthDateFormat.date(rhs.takenAt) ?? .distantPast)
        }
    }

    var body: some View {
        HLSheetScaffold(
            LocalizedStringKey(titleKey),
            size: .content(measuredHeight: contentHeight),
            action: .done()
        ) {
            HLPage {
                if let last = rows.first {
                    lastResult(last)
                }

                HLButton("mentalHealth.start", variant: .primary, action: onStart)
                    .accessibilityIdentifier("mentalHealth.detail.start")

                detailState

                // The licence text stays verbatim; a line in the reader's
                // language says what it is.
                Text("\(Text("mentalHealth.attribution.preface").fontWeight(.semibold)) \(Text(instrument.attribution))")
                    .hlText(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .hlSheetContentHeight($contentHeight)
            .task(id: instrument) {
                await store.loadDetail(instrument)
            }
        }
    }

    @ViewBuilder private var detailState: some View {
        if store.isDetailLoading, rows.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 180)
                .accessibilityLabel(Text("mentalHealth.history.chartTitle"))
        } else if store.detailError != nil, rows.isEmpty {
            errorState
        } else if rows.isEmpty {
            // No check-in yet: the start button above is the way on,
            // and no empty "Dein Verlauf" block stands under it.
            EmptyView()
        } else {
            if store.isDetailLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("mentalHealth.history.chartTitle"))
            } else if store.detailError != nil {
                errorState
            }
            MentalHealthHistoryChart(instrument: instrument, rows: rows)
            HLCard(layout: .rows) {
                ForEach(rows) { row in
                    MentalHealthDetailHistoryRow(row: row, store: store)
                }
            }
        }
    }

    private var errorState: some View {
        HLErrorState("mentalHealth.historyLoadErrorHint") {
            await store.loadDetail(instrument)
        }
    }

    private func lastResult(_ row: MentalHealthAssessmentDTO) -> some View {
        HLFactGroup {
            HLFactRow("mentalHealth.lastResult", value: MentalHealthDateFormat.short(row.takenAt))
            HLFactRow("mentalHealth.lastScore", value: "\(row.totalScore) (\(bandLabel(row)))")
        }
    }

    private func bandLabel(_ row: MentalHealthAssessmentDTO) -> String {
        NSLocalizedString(
            "mentalHealth.band.\(row.instrument.rawValue).\(row.severityBand)",
            comment: "Mental-health severity band label"
        )
    }
}

/// Thin wrapper over the shared ``HistoryLineChart``: maps the screener history
/// rows onto chart points (score → value) and supplies the band-annotated
/// wording. The chart chrome itself now lives in the shared primitive so
/// mental-health and the Vorsorge detail sheet render from ONE source.
private struct MentalHealthHistoryChart: View {
    let instrument: MentalHealthInstrument
    let rows: [MentalHealthAssessmentDTO]

    private var points: [HistoryLineChart.Point] {
        rows.compactMap { row in
            guard let date = MentalHealthDateFormat.date(row.takenAt) else { return nil }
            return HistoryLineChart.Point(id: row.id, date: date, value: Double(row.totalScore))
        }
    }

    private var bandByID: [String: String] {
        Dictionary(rows.map { ($0.id, bandLabel($0.severityBand)) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        HistoryLineChart(
            title: "mentalHealth.history.chartTitle",
            points: points,
            yDomain: 0 ... Double(instrument.maxScore),
            xValueLabel: String(localized: "mentalHealth.lastResult"),
            yValueLabel: String(localized: "mentalHealth.history.totalLabel"),
            annotation: { point in
                bandByID[point.id].map { "\(Int(point.value)) (\($0))" } ?? "\(Int(point.value))"
            },
            accessibilityDescription: { point in
                "\(MentalHealthDateFormat.short(point.date)): \(Int(point.value)), \(bandByID[point.id] ?? "")"
            }
        )
    }

    private func bandLabel(_ band: String) -> String {
        NSLocalizedString(
            "mentalHealth.band.\(instrument.rawValue).\(band)",
            comment: "Mental-health severity band label"
        )
    }
}

private struct MentalHealthDetailHistoryRow: View {
    let row: MentalHealthAssessmentDTO
    let store: MentalHealthStore

    @State private var showCrisis = false

    var body: some View {
        let content = MentalHealthHistoryRowContent(row: row)
        Group {
            if row.item9Flagged {
                // The row that showed support opens it again; the detail line
                // says so, no extra link under the row.
                HLRowButton { showCrisis = true } label: { historyRow(content) }
                    .accessibilityIdentifier("mentalHealth.history.resources")
            } else {
                historyRow(content)
            }
        }
        .sheet(isPresented: $showCrisis) {
            HLPage {
                MentalHealthCrisisCard(crisis: store.crisisSet(forHistoryRow: row))
            }
            .hlSheetPresentation(.standard)
        }
    }

    private func historyRow(_ content: MentalHealthHistoryRowContent) -> some View {
        HLHistoryRow(
            date: Text(verbatim: content.date),
            detail: content.detail.map { Text(verbatim: $0) },
            value: Text(content.score, format: .number),
            status: HLRowStatus(content.band)
        )
    }
}

/// What one check-in of the history says: when, the score, its band as
/// status, and on the side line whether support was shown, whether the
/// answers were given in an unvalidated translation and whether Apple Health
/// sent the score without its answers.
struct MentalHealthHistoryRowContent: Equatable {
    let date: String
    let score: Int
    let band: String
    let detail: String?

    init(row: MentalHealthAssessmentDTO) {
        date = MentalHealthDateFormat.short(row.takenAt)
        score = row.totalScore
        band = MentalWellbeingResult.bandLabel(instrument: row.instrument, band: row.severityBand)
        detail = HLRowDetail.joined([
            row.item9Flagged ? String(localized: "mentalHealth.history.flaggedBadge") : nil,
            row.wording == .unvalidatedTranslation ? String(localized: "mentalHealth.wording.historyUnvalidated") : nil,
            // Server 1.49.0: a score from Apple Health came without answers.
            row.isAppleHealthScoreOnly ? String(localized: "mentalHealth.history.appleHealthScoreOnly") : nil
        ])
    }
}

enum MentalHealthDateFormat {
    static func date(_ raw: String) -> Date? {
        ISO8601DateFormatter.fractional.date(from: raw)
            ?? ISO8601DateFormatter.plain.date(from: raw)
    }

    static func short(_ raw: String) -> String {
        guard let date = date(raw) else { return raw }
        return short(date)
    }

    static func short(_ date: Date) -> String {
        HLDateFormat.date(date, style: .abbreviated)
    }
}
