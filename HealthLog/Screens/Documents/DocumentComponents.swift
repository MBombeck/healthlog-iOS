import SwiftUI

// Shared presentation pieces for the document-vault browse screen: the
// usage/quota bar, the filter chip rail, and the document list row.

// MARK: - DocumentUsageBar

/// The storage usage/quota bar. Mirrors the web behaviour: it only appears once
/// usage crosses 80 % of quota (calm until it matters), showing the used/quota
/// label + an "almost full" note.
struct DocumentUsageBar: View {
    let usage: DocumentUsage

    private var isNearFull: Bool {
        usage.usedFraction >= 0.8
    }

    var body: some View {
        if isNearFull {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack {
                    Text("documents.upload.quotaAlmostFull")
                        .hlText(.groupHeader, status: HLColor.statusWarn)
                    Spacer()
                    Text(usedLabel)
                        .font(.hlCaption.monospacedDigit())
                        .foregroundStyle(HLText.secondary)
                }
                ProgressView(value: usage.usedFraction)
                    .tint(usage.usedFraction >= 0.95 ? HLColor.statusBad : HLColor.statusWarn)
            }
            .padding(.vertical, HLSpace.xxs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(usedLabel))
        }
    }

    private var usedLabel: String {
        let template = String(localized: "documents.upload.quotaUsed")
        return String(format: template, DocumentFormat.bytes(usage.usedBytes), DocumentFormat.bytes(usage.quotaBytes))
    }
}

// MARK: - DocumentFilterMenu

/// The entries of the documents filter in the bar (`hlPageActions` `.filter`):
/// a Type group of multi-select toggles (checkmarks), a single-select linked
/// condition, a single-select year, plus "clear filters" while anything is
/// active. Mutates a working ``DocumentListFilter`` through plain `Binding`s
/// and calls `apply` on every change.
struct DocumentFilterMenu: View {
    let filter: DocumentListFilter
    let conditionChips: [DocumentConditionLink]
    let years: [Int]
    let apply: (DocumentListFilter) -> Void
    let clear: () -> Void

    var body: some View {
        Section("documents.filter.kindSection") {
            ForEach(DocumentKindMeta.order) { kind in
                Toggle(isOn: kindBinding(kind)) {
                    Label(DocumentKindMeta.labelKey(kind), systemImage: DocumentKindMeta.icon(kind))
                }
            }
        }
        if !conditionChips.isEmpty {
            Picker("documents.filter.conditionSection", selection: episodeBinding) {
                Text("documents.filter.allConditions").tag(String?.none)
                ForEach(conditionChips) { chip in
                    Text(verbatim: chip.name).tag(String?.some(chip.episodeId))
                }
            }
        }
        if !years.isEmpty {
            Picker("documents.filter.yearSection", selection: yearBinding) {
                Text("documents.filter.allYears").tag(Int?.none)
                ForEach(years, id: \.self) { year in
                    Text(verbatim: String(year)).tag(Int?.some(year))
                }
            }
        }
        if filter.isActive {
            Section {
                Button("documents.filter.clear", systemImage: "arrow.counterclockwise", role: .destructive, action: clear)
            }
        }
    }

    private func kindBinding(_ kind: DocumentKind) -> Binding<Bool> {
        Binding(
            get: { filter.kinds.contains(kind) },
            set: { isOn in
                var next = filter
                if isOn {
                    if !next.kinds.contains(kind) { next.kinds.append(kind) }
                } else {
                    next.kinds.removeAll { $0 == kind }
                }
                apply(next)
            }
        )
    }

    private var episodeBinding: Binding<String?> {
        Binding(
            get: { filter.episodeId },
            set: { value in
                var next = filter
                next.episodeId = value
                apply(next)
            }
        )
    }

    private var yearBinding: Binding<Int?> {
        Binding(
            get: { filter.year },
            set: { value in
                var next = filter
                next.year = value
                apply(next)
            }
        )
    }
}

// MARK: - DocumentRowContent

/// What one document row says, as plain data: the title, one detail line
/// (filename, date, size) and at most one status. Every other fact (linked
/// conditions, extraction state) lives on the detail page.
struct DocumentRowContent: Equatable {
    /// The one status a row may carry, most urgent first.
    enum Status: Equatable {
        /// The upload is still being read.
        case processing
        /// The read finished while the list was on screen.
        case ready
        /// The file opens only as a download.
        case downloadOnly
    }

    let title: String
    let detail: String?
    let status: Status?

    init(document: InboundDocument, isProcessing: Bool, isReady: Bool) {
        let title = document.resolvedTitle ?? String(localized: "documents.card.untitled")
        self.title = title
        // The filename repeats the title when the document has no label of its
        // own, so it only joins the line when it adds something.
        let filename = document.filename.flatMap { $0.isEmpty || $0 == title ? nil : $0 }
        detail = HLRowDetail.joined([
            filename,
            DocumentFormat.mediumDate(document.displayDate),
            DocumentFormat.bytes(document.byteSize)
        ])
        if isProcessing {
            status = .processing
        } else if isReady {
            status = .ready
        } else if document.servingClass == .attachment {
            status = .downloadOnly
        } else {
            status = nil
        }
    }

    var rowStatus: HLRowStatus? {
        switch status {
        case .processing:
            HLRowStatus(String(localized: "documents.card.processing"), icon: "clock.arrow.circlepath")
        case .ready:
            HLRowStatus(String(localized: "documents.card.ready"), icon: "checkmark.circle", tone: .success)
        case .downloadOnly:
            HLRowStatus(String(localized: "documents.card.attachmentBadge"), icon: "arrow.down.circle")
        case nil:
            nil
        }
    }

    /// Title, detail line and status in the order they are seen.
    var accessibilityText: String {
        HLRowDetail.joined([title, detail, rowStatus?.title]) ?? title
    }
}

// MARK: - DocumentCardRow

/// One document as a list row: kind symbol, title and one detail line, at
/// most one status as text on the right. In selection mode a leading
/// checkmark column reflects the bulk selection.
struct DocumentCardRow: View {
    let document: InboundDocument
    let selectionMode: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    /// The row is the one whose preview stands beside the list.
    var isPaneSelected = false

    /// "Bereit" flash. The auto-index (+ background AI summary) job
    /// is fire-and-forget server-side; nothing pushes its completion. `isReady`
    /// is purely local: it flips on when a row that WAS processing while this
    /// list was on screen stops processing, so the user sees the transition
    /// instead of a status silently disappearing. It never resurrects for a row
    /// that was already indexed when the list loaded.
    @State private var sawProcessing = false
    @State private var isReady = false

    private var isProcessing: Bool {
        DocumentFormat.isProcessing(document)
    }

    private var content: DocumentRowContent {
        DocumentRowContent(document: document, isProcessing: isProcessing, isReady: isReady)
    }

    /// The recessed surface of the row shown beside the list, the soft tint of
    /// a row the screen points at, else the section's own.
    private var rowBackground: Color? {
        if isPaneSelected { return HLSurface.tertiary }
        return isHighlighted ? HLAccent.userBrandTint.opacity(0.12) : nil
    }

    var body: some View {
        let said = content
        HLRow(
            title: Text(verbatim: said.title),
            detail: said.detail.map { Text(verbatim: $0) },
            status: said.rowStatus
        ) {
            HStack(spacing: HLRowMetrics.gap) {
                // The circle of every multiple choice, from the choice row
                // itself, so selecting documents reads like selecting anything.
                if selectionMode, let mark = HLChoiceRow.symbol(mode: .multiple, isSelected: isSelected) {
                    HLRowGlyph(symbol: mark, tint: isSelected ? HLText.primary : HLText.tertiary)
                }
                HLRowGlyph(symbol: DocumentKindMeta.icon(document.kind))
            }
        }
        .listRowBackground(rowBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: said.accessibilityText))
        .accessibilityAddTraits(selectionMode && isSelected ? .isSelected : [])
        .onAppear { sawProcessing = isProcessing }
        .onChange(of: isProcessing) { wasProcessing, nowProcessing in
            if wasProcessing, !nowProcessing, sawProcessing {
                isReady = true
            }
            sawProcessing = nowProcessing
        }
    }
}
