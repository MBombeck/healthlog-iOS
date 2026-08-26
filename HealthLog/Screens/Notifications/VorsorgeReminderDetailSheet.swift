import SwiftUI

/// **W-VORSORGE-DETAIL (b244) — the bottom-to-top detail sheet a Vorsorge card
/// opens on tap.**
///
/// Its anatomy mirrors `MentalHealthInstrumentDetail` 1:1 so the two families
/// feel identical: a `NavigationStack` + `ScrollView`, the Next/Last block on
/// top, the primary action (the SAME `VorsorgeCard.primaryAction` branch as the
/// card), then the shared ``HistoryLineChart`` of the linked metric's readings
/// with the recent "date · value" rows below. Presented via
/// `.hlSheetPresentation(.standard)` → rises bottom-to-top and expands medium →
/// large on swipe, exactly like the mental-health card the operator loves.
///
/// Three arms (``VorsorgeCard/detailArm(for:)``):
/// - **metric** — the linked metric's reading history + recent "date · value" rows.
/// - **screening** — the severity-band chart ("score · band" annotation, same
///   `mentalHealth.band.*` keys) + a "check-in" action + a reference row into the
///   mental-health surface. The crisis / item-9 UI is NOT duplicated here.
/// - **free-text** — no chart: Next/Last + location (if set) + an honest
///   "no linked measurement" hint + mark-done.
struct VorsorgeReminderDetailSheet: View {
    let row: MeasurementReminderRow
    /// **ROUTE-07 (08-22)** — the shared store, passed **explicitly** rather than
    /// read from the environment. `row` is the snapshot `.sheet(item:)` captured,
    /// and a skip or a snooze replaces it with the server's canonical row, which
    /// only the store has. An `@Environment` lookup would have made the whole
    /// action-and-ledger surface disappear silently if it ever failed to inherit;
    /// a required parameter makes that a compile error instead.
    let store: MeasurementRemindersStore
    /// Measure-now — closes the sheet and opens the prefilled capture sheet.
    let onMeasure: (MetricKind) -> Void
    /// #42 — a screening reminder starts the mental-health check-in.
    let onCheckIn: () -> Void
    /// Free-text / scale-only — mark the reminder done server-side.
    let onMarkDone: () -> Void

    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var model: VorsorgeDetailModel?

    private var units: UnitPreferences {
        container?.settingsStore.unitPreferences ?? .standard
    }

    private var primaryAction: VorsorgeCard.PrimaryAction {
        VorsorgeCard.primaryAction(for: row)
    }

    /// The reminder as the store currently holds it — i.e. the last canonical
    /// row the server sent — falling back to the presented snapshot while the
    /// list has not been re-read. Everything the sheet renders reads this, so a
    /// completed skip is visible without re-opening the sheet.
    private var currentRow: MeasurementReminderRow {
        store.reminders.first { $0.id == row.id } ?? row
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    nextLastBlock
                    primaryButton
                    VorsorgeReminderLedgerActions(row: currentRow, store: store)
                    if let model {
                        detailBody(model: model)
                    }
                    VorsorgeReminderLedgerSection(row: currentRow, store: store)
                }
                .padding(HLSpace.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(HLSurface.primary)
            .navigationTitle(headerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await onAppear() }
        }
        .hlSheetPresentation(.standard)
    }

    // MARK: - Header / Next-Last

    private var headerTitle: String {
        if let resolved = VorsorgeCard.resolvedLabel(for: row) { return resolved }
        return MeasurementReminderType.label(for: row.measurementType, fallback: "")
    }

    private var nextLastBlock: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            detailRow(
                label: String(localized: "vorsorge.card.nextDue"),
                value: VorsorgeCard.dueDisplayText(nextDueAt: currentRow.nextDueAt)
            )
            detailRow(
                label: String(localized: "vorsorge.card.lastDone"),
                value: VorsorgeCard.lastDoneDisplayText(lastSatisfiedAt: currentRow.lastSatisfiedAt)
            )
            // ROUTE-07 — both are server instants formatted, never computed. The
            // snooze row appears only while the cursor is still ahead of the
            // clock, which is the comparison the accepted DTO prescribes.
            if let until = currentRow.snoozedUntil, VorsorgeCard.isSnoozed(currentRow) {
                detailRow(
                    label: String(localized: "vorsorge.card.snoozed"),
                    value: until.formatted(.dateTime.day().month().year())
                )
            }
            if currentRow.skipCount > 0 {
                detailRow(
                    label: String(localized: "vorsorge.card.skipped"),
                    value: String(
                        format: String(localized: "vorsorge.card.skipCount"),
                        currentRow.skipCount
                    )
                )
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
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

    // MARK: - Primary action (same branch as the card)

    @ViewBuilder
    private var primaryButton: some View {
        switch primaryAction {
        case let .measure(kind):
            HLButton(String(localized: "vorsorge.card.measureNow"), icon: "plus", variant: .secondary) {
                dismiss()
                onMeasure(kind)
            }
            .accessibilityIdentifier("vorsorge.detail.measureNow")
        case .checkIn:
            HLButton(String(localized: "vorsorge.card.checkIn"), icon: "brain.head.profile", variant: .secondary) {
                dismiss()
                onCheckIn()
            }
            .accessibilityIdentifier("vorsorge.detail.checkIn")
        case .markDone:
            HLButton(String(localized: "vorsorge.card.markDone"), icon: "checkmark", variant: .secondary) {
                onMarkDone()
                dismiss()
            }
            .accessibilityIdentifier("vorsorge.detail.markDone")
        }
    }

    // MARK: - Detail body (chart + rows / empty / loading)

    @ViewBuilder
    private func detailBody(model: VorsorgeDetailModel) -> some View {
        switch model.arm {
        case .freeText:
            freeTextBody
        case .metric:
            metricBody(model: model)
        case let .screening(instrument):
            screeningBody(model: model, instrument: instrument)
        }
    }

    // MARK: - Metric arm

    @ViewBuilder
    private func metricBody(model: VorsorgeDetailModel) -> some View {
        if model.isLoading, model.points.isEmpty {
            loadingState
        } else if !model.points.isEmpty {
            chart(model: model, bandByID: [:])
            recentReadings(model: model)
        } else {
            emptyState(model: model)
        }
    }

    // MARK: - Screening arm

    @ViewBuilder
    private func screeningBody(model: VorsorgeDetailModel, instrument: MentalHealthInstrument) -> some View {
        if model.isLoading, model.points.isEmpty {
            loadingState
        } else if !model.points.isEmpty {
            chart(model: model, bandByID: bandByID(model: model, instrument: instrument))
        } else {
            emptyState(model: model)
        }
        // The crisis / item-9 UI is NOT duplicated here — it stays owned by the
        // mental-health surface. We only point the way there.
        screeningReferenceRow
    }

    private var screeningReferenceRow: some View {
        Button(action: onCheckIn) {
            HStack(spacing: HLSpace.md) {
                Text("vorsorge.detail.screening.reference")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                Spacer(minLength: HLSpace.sm)
                HLDisclosureChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("vorsorge.detail.screening.reference")
    }

    /// `[assessment id: localized band label]` for the screening chart's
    /// "score · band" annotation — the SAME `mentalHealth.band.*` keys as the
    /// mental-health card.
    private func bandByID(model: VorsorgeDetailModel, instrument: MentalHealthInstrument) -> [String: String] {
        Dictionary(
            model.screeningRows.map { row in
                (row.id, NSLocalizedString(
                    "mentalHealth.band.\(instrument.rawValue).\(row.severityBand)",
                    comment: "Mental-health severity band label"
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Free-text arm

    private var freeTextBody: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            if let location = row.location, !location.isEmpty {
                detailRow(label: String(localized: "reminders.create.location.label"), value: location)
            }
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "info.circle")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
                Text("vorsorge.detail.freeText.noMetric")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chart

    private func chart(model: VorsorgeDetailModel, bandByID: [String: String]) -> some View {
        HistoryLineChart(
            title: "vorsorge.detail.history",
            points: model.points,
            yDomain: model.yDomain,
            xValueLabel: String(localized: "vorsorge.detail.axis.date"),
            yValueLabel: String(localized: "vorsorge.detail.axis.value"),
            annotation: { point in chartValueText(point, model: model, bandByID: bandByID) },
            accessibilityDescription: { point in
                "\(HLDateFormat.date(point.date, style: .abbreviated)): \(chartValueText(point, model: model, bandByID: bandByID))"
            }
        )
    }

    /// Formatted point value: a metric's unit-aware value, or a screener's
    /// "score · band".
    private func chartValueText(
        _ point: HistoryLineChart.Point,
        model: VorsorgeDetailModel,
        bandByID: [String: String]
    ) -> String {
        switch model.arm {
        case let .metric(kind):
            return MetricValueFormatter.formatScalar(point.value, kind: kind, units: units)
        case .screening:
            let band = bandByID[point.id] ?? ""
            return band.isEmpty ? "\(Int(point.value))" : "\(Int(point.value)) · \(band)"
        case .freeText:
            return "\(Int(point.value))"
        }
    }

    private var loadingState: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 180)
            .accessibilityLabel(Text("vorsorge.detail.history"))
    }

    @ViewBuilder
    private func recentReadings(model: VorsorgeDetailModel) -> some View {
        if !model.metricMeasurements.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Text("vorsorge.detail.recent")
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                ForEach(model.metricMeasurements.prefix(7).map { $0 }) { measurement in
                    HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                        Text(HLDateFormat.date(measurement.recordedAt, style: .abbreviated))
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                        Spacer(minLength: HLSpace.sm)
                        Text(MetricValueFormatter.formattedValue(measurement, units: units))
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.primary)
                            .monospacedDigit()
                    }
                    Divider()
                }
            }
        }
    }

    private func emptyState(model: VorsorgeDetailModel) -> some View {
        VStack(spacing: HLSpace.sm) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.hlTitle2)
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
            Text("vorsorge.detail.empty.title")
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
            Text("vorsorge.detail.empty.body")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.center)
            HLButton("Retry", variant: .secondary) {
                Task { await model.load() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    // MARK: - Lifecycle

    private func onAppear() async {
        if model == nil, let container {
            model = VorsorgeDetailModel(
                row: row,
                measurementsRepo: container.measurementsRepo,
                mentalHealthStore: container.mentalHealthStore
            )
        }
        await model?.load()
    }
}

// MARK: - ROUTE-07 (v1.37.20) — the completion ledger

/// The reminder's server completion ledger: one row per satisfy (from any path)
/// and per skip, newest first, exactly as `GET …/{id}/history` returned them.
///
/// **Nothing here is reconstructed.** The reminder row this section is handed
/// carries `lastSatisfiedAt`, `lastSkippedAt` and `skipCount`, and a surface
/// that wanted to look complete could assemble a plausible history out of them
/// without ever calling the route. `VorsorgeCard.ledgerState(_:)` takes the
/// ledger and *not* the row for exactly that reason, and the row is used here
/// only for its `id`.
///
/// The three ways a ledger can be absent stay three different sentences: not
/// asked yet, honestly empty (the ledger begins at the release that introduced
/// it and cannot be backfilled), and not offered for this reminder at all.
private struct VorsorgeReminderLedgerSection: View {
    let row: MeasurementReminderRow
    let store: MeasurementRemindersStore

    private var state: VorsorgeCard.LedgerState {
        VorsorgeCard.ledgerState(store.ledger(for: row.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("vorsorge.history.title")
                .font(.hlHeadline)
                .foregroundStyle(HLText.primary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("vorsorge.detail.history")
        .task { await store.loadHistory(id: row.id) }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 60)
                .accessibilityLabel(Text("vorsorge.history.title"))
        case .unsupported:
            note("vorsorge.history.unsupported")
        case .empty:
            note("vorsorge.history.empty")
        case let .loaded(entries, hasMore):
            entryList(entries)
            if hasMore { loadMoreButton }
        case let .failed(entries, hasMore):
            entryList(entries)
            note("vorsorge.history.failed")
            retryButton(hasMore: hasMore)
        }
    }

    private func entryList(_ entries: [VorsorgeCard.LedgerEntry]) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            ForEach(entries) { entry in
                entryRow(entry)
                Divider()
            }
        }
    }

    /// One ledger row. Kind and date on the first line, provenance and the
    /// server-derived punctuality below. An unrecognised `kind`/`source` renders
    /// its neutral label **and** the raw token the server sent, because a
    /// silently dropped row is a hole in a history nobody can otherwise see.
    private func entryRow(_ entry: VorsorgeCard.LedgerEntry) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Text(LocalizedStringKey(entry.kindKey))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                Spacer(minLength: HLSpace.sm)
                Text(HLDateFormat.date(entry.occurredAt, style: .abbreviated))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: HLSpace.xs) {
                Text(LocalizedStringKey(entry.sourceKey))
                Text(LocalizedStringKey(entry.punctualityKey))
                if let raw = entry.unknownWireValue {
                    Text(verbatim: raw)
                }
            }
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var loadMoreButton: some View {
        HLButton(String(localized: "vorsorge.history.loadMore"), variant: .secondary) {
            Task { await store.loadHistory(id: row.id) }
        }
        .disabled(store.ledger(for: row.id).isLoading)
        .accessibilityIdentifier("vorsorge.detail.history.loadMore")
    }

    private func retryButton(hasMore: Bool) -> some View {
        HLButton(String(localized: "vorsorge.history.retry"), variant: .secondary) {
            Task { await store.loadHistory(id: row.id, reset: !hasMore) }
        }
        .disabled(store.ledger(for: row.id).isLoading)
        .accessibilityIdentifier("vorsorge.detail.history.retry")
    }

    private func note(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Image(systemName: "info.circle")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
            Text(key)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
