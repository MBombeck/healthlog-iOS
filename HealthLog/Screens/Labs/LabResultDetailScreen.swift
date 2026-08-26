import SwiftUI

/// Detail for a single lab result. Loads the decrypted note via
/// `GET /api/labs/{id}`; renders the value vs. its reference range using the
/// shared neutral ``RangeBandRow`` rail (no recompute — the server-resolved
/// `referenceLow`/`referenceHigh` + neutral `rangeStatus` drive the display).
struct LabResultDetailScreen: View {
    @Environment(\.dismiss) private var dismiss

    let store: LabsStore
    let resultID: String
    /// The list-row summary, shown immediately while the detail (note) loads.
    let summary: LabResultDTO

    @State private var detail: LabResultDetailDTO?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showEdit = false
    @State private var showDeleteConfirm = false

    private var status: LabRangeStatus {
        detail?.rangeStatus ?? summary.rangeStatus
    }

    private var analyte: String {
        detail?.analyte ?? summary.analyte
    }

    private var unit: String {
        detail?.unit ?? summary.unit
    }

    /// Item 1.5 — optional. `detail?.value ?? summary.value` would have coalesced
    /// a qualitative detail row's `nil` back onto the summary; prefer the detail
    /// row wholesale once it has loaded.
    private var value: Double? {
        detail == nil ? summary.value : detail?.value
    }

    private var valueText: String? {
        detail == nil ? summary.valueText : detail?.valueText
    }

    private var referenceLow: Double? {
        detail?.referenceLow ?? summary.referenceLow
    }

    private var referenceHigh: Double? {
        detail?.referenceHigh ?? summary.referenceHigh
    }

    private var panel: String? {
        detail?.panel ?? summary.panel
    }

    private var takenAt: String {
        detail?.takenAt ?? summary.takenAt
    }

    private var source: String {
        detail?.source ?? summary.source
    }

    private var isLinked: Bool {
        (detail?.biomarkerId ?? summary.biomarkerId) != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                headerCard
                rangeCard
                if let note = detail?.note, !note.isEmpty {
                    noteCard(note)
                }
                metaCard
                HLSyncStatusFooter(screenLoading: isLoading)
            }
            .padding(HLSpace.lg)
        }
        .hlScreenBackground()
        .navigationTitle(Text(verbatim: analyte))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showEdit = true
                    } label: {
                        Label("labs.edit.action", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("labs.delete.action", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("labs.detail.menu")
            }
        }
        .task { await loadDetail() }
        .sheet(isPresented: $showEdit) {
            EditLabResultSheet(store: store, result: summary)
        }
        .hlConfirmDestructive(
            Text("labs.delete.confirm.title"),
            isPresented: $showDeleteConfirm,
            confirm: Text("labs.delete.action"),
            cancel: Text("labs.action.cancel"),
            action: {
                Task {
                    await store.deleteLab(id: resultID, undoMessage: String(localized: "labs.delete.undo"))
                    dismiss()
                }
            }
        )
    }

    private var headerCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack {
                    Text(valueLabel)
                        .font(.hlMetric(.largeTitle))
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                    Spacer()
                    LabRangeBadge(status: status)
                }
                if isLinked {
                    Label("labs.detail.linkedMarker", systemImage: "link")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var rangeCard: some View {
        // Item 1.5 — a reference rail needs a number to place on it. A
        // qualitative (or absent) reading has none, so the whole card stands
        // down rather than rendering a marker at 0.
        if let band, let value {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("labs.detail.reference")
                        .font(.hlFootnote.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                    LabReferenceRangeRow(
                        value: value,
                        unit: unit,
                        lower: referenceLow,
                        upper: referenceHigh,
                        status: status
                    )
                    Text(band)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
    }

    private func noteCard(_ note: String) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("labs.detail.note")
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                Text(note)
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
            }
        }
    }

    private var metaCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                metaRow(label: String(localized: "labs.detail.takenAt"), value: LabsDateFormat.mediumDateTime(takenAt))
                if let panel, !panel.isEmpty {
                    metaRow(label: String(localized: "labs.detail.panel"), value: panel)
                }
                metaRow(label: String(localized: "labs.detail.source"), value: source)
                if let loadError {
                    HLFormErrorText(loadError)
                }
            }
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
            Spacer()
            Text(value)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
        }
    }

    private var valueLabel: String {
        LabValueDisplay.text(value: value, valueText: valueText, unit: unit)
    }

    /// The "Reference 3.5–5.1 mmol/L" line — only when at least one bound
    /// exists. Built from `String(format:)` over a single static localized
    /// template so the xcstrings keys stay static.
    private var band: String? {
        func num(_ v: Double) -> String {
            v.formatted(.number.precision(.fractionLength(0 ... 2)))
        }
        let unitSuffix = unit.isEmpty ? "" : " \(unit)"
        switch (referenceLow, referenceHigh) {
        case let (low?, high?):
            let template = String(localized: "labs.detail.range.both")
            return String(format: template, num(low), num(high)) + unitSuffix
        case let (low?, nil):
            let template = String(localized: "labs.detail.range.min")
            return String(format: template, num(low)) + unitSuffix
        case let (nil, high?):
            let template = String(localized: "labs.detail.range.max")
            return String(format: template, num(high)) + unitSuffix
        case (nil, nil):
            return nil
        }
    }

    private func loadDetail() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            detail = try await store.fetchDetail(id: resultID)
        } catch {
            // The summary already renders; a detail (note) load failure is
            // non-fatal — surface a quiet inline note.
            loadError = String(localized: "labs.detail.loadFailed")
        }
    }
}

/// Value-vs-reference display: the value, the bounds, and a neutral position
/// rail. Reuses the calm rail aesthetic of ``RangeBandRow`` but drives the fill
/// from the value's position inside `[lower, upper]` (NOT a recomputed verdict —
/// the verdict is the server `status`; this is purely a position indicator).
struct LabReferenceRangeRow: View {
    let value: Double
    let unit: String
    let lower: Double?
    let upper: Double?
    let status: LabRangeStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack {
                Text(lowerLabel)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                Spacer()
                Text(upperLabel)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: InsightsInTargetBar.cornerRadius)
                        .fill(InsightsInTargetBar.trackTone)
                        .frame(height: InsightsInTargetBar.railHeight)
                    // Neutral position marker — the brand tint dot, never a
                    // red/green alarm fill.
                    Circle()
                        .fill(HLAccent.userBrandTint)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, min(geo.size.width - 12, geo.size.width * fraction - 6)))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: fraction)
                }
            }
            .frame(height: InsightsInTargetBar.railHeight)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(status.localizedLabel))
    }

    /// Position 0…1 of `value` within `[lower, upper]`; clamps when only one
    /// bound exists or when out of range. Pure presentation, no verdict.
    private var fraction: CGFloat {
        guard let lower, let upper, upper > lower else { return 0.5 }
        return CGFloat(max(0, min(1, (value - lower) / (upper - lower))))
    }

    private var lowerLabel: String {
        guard let lower else { return "—" }
        return lower.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    private var upperLabel: String {
        guard let upper else { return "—" }
        return upper.formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}
