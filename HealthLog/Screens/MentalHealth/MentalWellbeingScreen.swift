import SwiftUI

/// Opt-in mental-health self-checks beside mood tracking. The landing stays
/// neutral: four instrument cards, with history available only in a deliberate
/// per-instrument detail sheet.
struct MentalWellbeingScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(\.locale) private var locale

    @State private var store: MentalHealthStore?
    @State private var showAbortConfirm = false
    @State private var detailInstrument: MentalHealthInstrument?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.xl) {
                if let store {
                    if store.phase == .choose {
                        header
                    }
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
            .padding(HLSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HLSurface.primary)
        .hlScrollEdgeSoft()
        .navigationTitle(Text("more.mentalWellbeing.title"))
        .navigationBarTitleDisplayMode(.inline)
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
        .refreshable { await store?.load() }
        .task { await onAppear() }
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
                    Label("mentalHealth.back", systemImage: "chevron.left")
                }
                .accessibilityIdentifier("mentalHealth.abort")
            }
        }
    }

    /// G3 — the header used to open with `mentalHealth.pageTitle`, which is the
    /// same words as the navigation title („Seelisches Wohlbefinden") one line
    /// above it. The navigation title is the one that stays: it survives
    /// scrolling and it is how every other screen in the app titles itself.
    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("mentalHealth.pageDescription")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseSection(store: MentalHealthStore) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            Text("mentalHealth.choosePrompt")
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)

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
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("mentalHealth.historyLoadError")
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                Text("mentalHealth.historyLoadErrorHint")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HLButton("Retry", variant: .secondary) {
                    Task { await retry() }
                }
            }
        }
    }

    private func onAppear() async {
        if store == nil {
            store = container?.mentalHealthStore
        }
        await store?.load()
    }
}

/// Neutral card with three sibling affordances: detail, attribution, and Start.
private struct MentalHealthInstrumentCard: View {
    let instrument: MentalHealthInstrument
    let last: MentalHealthAssessmentDTO?
    let onOpenDetail: () -> Void
    let onStart: () -> Void

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HStack(alignment: .top, spacing: HLSpace.sm) {
                    Button(action: onOpenDetail) {
                        VStack(alignment: .leading, spacing: HLSpace.xxs) {
                            Text(localizedKey("mentalHealth.instrument.\(instrument.keySegment)"))
                                .font(.hlHeadline)
                                .foregroundStyle(HLText.primary)
                            Text(localizedKey("mentalHealth.instrumentSub.\(instrument.keySegment)"))
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(detailAccessibilityLabel)
                    .accessibilityIdentifier("mentalHealth.detail.\(instrument.keySegment)")
                }

                if let last {
                    VStack(spacing: HLSpace.xs) {
                        labelValueRow(
                            label: String(localized: "mentalHealth.lastResult"),
                            value: MentalHealthDateFormat.short(last.takenAt)
                        )
                        labelValueRow(
                            label: String(localized: "mentalHealth.lastScore"),
                            value: "\(last.totalScore) · \(bandLabel(last))"
                        )
                    }
                } else {
                    Text("mentalHealth.noResultYet")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }

                // G4/G6 — the card's Starten is a KACHEL-Aktion, not a flow CTA.
                // `HLButton(.primary)` fills with `AnyShapeStyle(.tint)`, and the
                // scene tint is the monochrome ink, so on a card it read as the
                // near-white slab the operator called „extrem hell". R9/E2-A1
                // names the shape for an action inside a tile and
                // `HLTileActionButton` carries it — the same type the medication
                // and Vorsorge tiles render from. The detail sheet's own Starten
                // stays `.primary`: that one IS the screen's commit action.
                HLTileActionButton("mentalHealth.start", action: onStart)
                    .accessibilityIdentifier("mentalHealth.choose.\(instrument.keySegment)")
            }
        }
    }

    private func labelValueRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            Text(label)
                .font(.hlCaption.weight(.medium))
                .foregroundStyle(HLText.secondary)
            Spacer(minLength: HLSpace.sm)
            Text(value)
                .font(.hlCaption)
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.trailing)
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
        return "\(title) — \(String(localized: "mentalHealth.openDetail"))"
    }

    private func localizedKey(_ key: String) -> LocalizedStringKey {
        LocalizedStringKey(key)
    }
}

private struct MentalHealthInstrumentDetail: View {
    let instrument: MentalHealthInstrument
    @Bindable var store: MentalHealthStore
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var rows: [MentalHealthAssessmentDTO] {
        store.detailHistory.sorted { lhs, rhs in
            (MentalHealthDateFormat.date(lhs.takenAt) ?? .distantPast)
                > (MentalHealthDateFormat.date(rhs.takenAt) ?? .distantPast)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    if let last = rows.first {
                        lastResult(last)
                    }

                    HLButton("mentalHealth.start", variant: .primary, action: onStart)
                        .accessibilityIdentifier("mentalHealth.detail.start")

                    detailState

                    Text(instrument.attribution)
                        .font(.hlCaption2)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(HLSpace.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(HLSurface.primary)
            .navigationTitle(localizedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: instrument) {
                await store.loadDetail(instrument)
            }
        }
        // V2 — the raw `[.medium, .large]` detent pair is now the named
        // `hlSheetPresentation(.standard)` contract, so medications,
        // mental-health and (from Commit 6) the Vorsorge detail sheet all hang
        // off ONE detent policy. Adds the canonical drag-indicator; no other
        // behaviour change.
        .hlSheetPresentation(.standard)
    }

    @ViewBuilder private var detailState: some View {
        if store.isDetailLoading, rows.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 180)
                .accessibilityLabel(Text("mentalHealth.history.chartTitle"))
        } else if store.detailError != nil, rows.isEmpty {
            errorState
        } else if rows.isEmpty {
            VStack(spacing: HLSpace.sm) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.hlTitle2)
                    .foregroundStyle(HLText.tertiary)
                Text("mentalHealth.history.title")
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                Text("mentalHealth.history.empty")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            if store.isDetailLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("mentalHealth.history.chartTitle"))
            } else if store.detailError != nil {
                errorState
            }
            MentalHealthHistoryChart(instrument: instrument, rows: rows)
            VStack(spacing: HLSpace.sm) {
                ForEach(rows) { row in
                    MentalHealthDetailHistoryRow(row: row, store: store)
                }
            }
        }
    }

    private var errorState: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("mentalHealth.historyLoadError")
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
            Text("mentalHealth.historyLoadErrorHint")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HLButton("Retry", variant: .secondary) {
                Task { await store.loadDetail(instrument) }
            }
        }
    }

    private func lastResult(_ row: MentalHealthAssessmentDTO) -> some View {
        VStack(spacing: HLSpace.xs) {
            detailValueRow(
                label: String(localized: "mentalHealth.lastResult"),
                value: MentalHealthDateFormat.short(row.takenAt)
            )
            detailValueRow(
                label: String(localized: "mentalHealth.lastScore"),
                value: "\(row.totalScore) · \(bandLabel(row))"
            )
        }
    }

    private func detailValueRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            Text(label)
                .font(.hlSubhead.weight(.medium))
                .foregroundStyle(HLText.secondary)
            Spacer(minLength: HLSpace.sm)
            Text(value)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var localizedTitle: String {
        NSLocalizedString(
            "mentalHealth.instrument.\(instrument.keySegment)",
            comment: "Mental-health instrument title"
        )
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
                "\(Int(point.value)) · \(bandByID[point.id] ?? "")"
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
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Text(MentalHealthDateFormat.short(row.takenAt))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                Spacer(minLength: HLSpace.sm)
                Text(bandLabel)
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                Text("\(row.totalScore)")
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
            }
            if row.item9Flagged {
                Button {
                    showCrisis = true
                } label: {
                    Label("mentalHealth.history.flaggedBadge", systemImage: "lifepreserver")
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLAccent.userBrandTint)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mentalHealth.history.resources")
            }
            Divider()
        }
        .sheet(isPresented: $showCrisis) {
            ScrollView {
                MentalHealthCrisisCard(crisis: store.crisisSet(forHistoryRow: row))
                    .padding(HLSpace.lg)
            }
            .background(HLSurface.primary)
            .presentationDetents([.medium, .large])
        }
    }

    private var bandLabel: String {
        NSLocalizedString(
            "mentalHealth.band.\(row.instrument.rawValue).\(row.severityBand)",
            comment: "Mental-health severity band label"
        )
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
