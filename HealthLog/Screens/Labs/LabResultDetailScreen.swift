import SwiftUI

/// Detail for a single lab result, built like the reference metric page:
/// the reading as the page's one figure, its assessment against the
/// reference range, then the background. Loads the decrypted note via
/// `GET /api/labs/{id}`. Nothing is recomputed: the server-resolved bounds
/// and `rangeStatus` drive the display.
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

    private var status: LabRangeStatus {
        detail?.rangeStatus ?? summary.rangeStatus
    }

    private var analyte: String {
        detail?.analyte ?? summary.analyte
    }

    private var unit: String {
        detail?.unit ?? summary.unit
    }

    /// Optional. `detail?.value ?? summary.value` would have coalesced
    /// a qualitative detail row's `nil` back onto the summary; prefer the detail
    /// row wholesale once it has loaded.
    private var value: Double? {
        detail == nil ? summary.value : detail?.value
    }

    private var valueText: String? {
        detail == nil ? summary.valueText : detail?.valueText
    }

    /// The figure the report printed, when the server converted the reading.
    private var printedValue: Double? {
        detail == nil ? summary.sourceValue : detail?.sourceValue
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

    var body: some View {
        // The order of the reference metric page: the figure, its
        // assessment, then the background (panel, source, note, related).
        HLPage {
            HLSectionHeader("Measurement", rank: .area)
            LabReadingHero(
                reading: LabReadingHero.Reading(value: value, valueText: valueText, unit: unit, printed: printedValue),
                status: status,
                caption: LabsDateFormat.labDateTime(takenAt),
                conversion: detail.map(LabConversion.init) ?? LabConversion(summary),
                range: LabReadingHero.Range(low: referenceLow, high: referenceHigh)
            )
            assessmentSection
            backgroundSection
            // The records this one relates to (e.g. the scanned report).
            RelatedRecordsSection(links: detail?.related?.items ?? [])
            HLSyncStatusFooter(screenLoading: isLoading)
        }
        .navigationTitle(Text(verbatim: analyte))
        .navigationBarTitleDisplayMode(.inline)
        .hlPageActions([
            .more(identifier: "labs.detail.menu") {
                Button("labs.edit.action", systemImage: "pencil") {
                    showEdit = true
                }
                // The store keeps the way back: no question, the undo hint.
                HLDeleteMenuItem(.undoable {
                    await store.deleteLab(id: resultID, undoMessage: String(localized: "labs.delete.undo"))
                    dismiss()
                })
            }
        ])
        .task { await loadDetail() }
        .sheet(isPresented: $showEdit) {
            EditLabResultSheet(store: store, result: summary)
        }
    }

    /// The range the verdict is made against, in the form of the marker
    /// page's assessment. A reading without range and verdict has none.
    @ViewBuilder
    private var assessmentSection: some View {
        let range = BiomarkerSeries.referenceText(low: referenceLow, high: referenceHigh, unit: unit)
        if range != nil || status.rowStatus != nil {
            HLSectionHeader("biomarker.detail.assessment", rank: .area)
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    if let range {
                        HLFactGroup {
                            HLFactRow("labs.detail.reference", value: range)
                        }
                    }
                    // 1.0.3 / App Review 1.4.1: a reference range plus a
                    // verdict says where the range came from and offers the
                    // sources behind it.
                    LabReferenceSourceLine(topic: .labReferenceRanges)
                }
            }
        }
    }

    /// Panel, source and the note, under one head like the background
    /// block of the reference page.
    @ViewBuilder
    private var backgroundSection: some View {
        HLSectionHeader("labs.detail.background", rank: .area)
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLFactGroup {
                    if let panel = LabPanelName.display(panel) {
                        HLFactRow("labs.detail.panel", value: panel)
                    }
                    HLFactRow("labs.detail.source", value: LabUnit.sourceName(source))
                }
                if let loadError {
                    HLFormErrorText(loadError)
                }
            }
        }
        if let note = detail?.note, !note.isEmpty {
            HLCard("labs.detail.note") {
                Text(note)
                    .hlText(.prose)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The range line for given bounds; the unit follows the numbers, never
    /// the unity "1". `nil` without any bound.
    nonisolated static func rangeText(low referenceLow: Double?, high referenceHigh: Double?, unit: String) -> String? {
        func num(_ v: Double) -> String {
            HLValueFormat.number(v, fractionDigits: 0 ... 2)
        }
        let unitSuffix = LabUnit.suffix(unit).map { " \($0)" } ?? ""
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
