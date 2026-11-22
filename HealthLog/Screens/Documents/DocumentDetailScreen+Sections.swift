import SwiftUI

// The metadata + conditions cards for `DocumentDetailScreen`, plus the
// condition-link editor sheet and the file share sheet. Split out to keep the
// screen file within the length budget.

extension DocumentDetailScreen {
    // MARK: - Persisted summary section

    /// The server's PERSISTED background AI summary — generated once after
    /// upload by the auto-read job, not the session-only "Zusammenfassen" panel
    /// in the assist block. Web parity (`data-slot="document-detail-summary"`):
    /// a "Zusammenfassung" label, the narrative as foreground prose, and the
    /// generation date as muted meta. Rendered directly under the preview,
    /// ABOVE the AI actions and the fields.
    ///
    /// When auto-read is effectively on (iOS indexes silently on open — see
    /// `autoIndexIfNeeded`) but no summary has landed yet, one calm "wird
    /// erstellt" line stands in. With auto-read off there is nothing to wait
    /// for, so the whole section collapses.
    @ViewBuilder
    var summarySection: some View {
        // The card's title says the summary comes from AI (it was a
        // loose "Read by AI" caption at the end of the page), and the pending
        // state is the same card with a spinner instead of a loose line.
        if let prose = document.resolvedSummary {
            HLSectionHeader("documents.detail.summary.aiTitle", rank: .area)
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    // Web parity: the AI narrative is FOREGROUND content, not
                    // muted meta (only the generation date below is muted).
                    HLInsightProse(text: prose, color: HLText.primary)
                    if let generatedAt = document.summaryGeneratedAt, !generatedAt.isEmpty {
                        Text(verbatim: DocumentFormat.mediumDate(generatedAt))
                            .hlText(.footnote)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("documents.detail.summary")
        } else if contentIndexEnabled {
            HLSectionHeader("documents.detail.summary.aiTitle", rank: .area)
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    // A read that cannot finish here says why
                    // instead of spinning forever.
                    if let notice = summaryNotice {
                        Text(notice.message)
                            .hlText(.factLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: HLSpace.sm) {
                            ProgressView().controlSize(.small)
                            Text("documents.detail.summary.pending")
                                .hlText(.factLabel)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                summaryNotice == nil ? "documents.detail.summary.pending" : "documents.detail.summary.notice"
            )
        }
    }

    /// The sentence that replaces the pending spinner: "too large" from the
    /// stored outcome (no new attempt), else what the automatic read hit.
    var summaryNotice: DocumentReadNotice? {
        if document.isTooLargeToRead, !document.hasContentIndex { return .tooLarge }
        return readNotice
    }

    // MARK: - Lab-values jump

    /// The web's `…lab-values-link`: when the labs module is on and this
    /// document staged ≥ 1 non-rejected OBSERVATION fact, a direct jump into
    /// Labs. Counted from the detail's own `facts` (already loaded) — the client
    /// never re-derives lab VALUES, only how many there are. A read that
    /// stopped early says so in the same card, above the jump.
    @ViewBuilder
    var labValuesSection: some View {
        let count = InboundDocumentDetail.labFactCount(in: facts)
        let showsNote = extractionIncomplete && labsModuleEnabled
        let showsLink = count > 0 && labsModuleEnabled
        if showsNote || showsLink {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    if showsNote {
                        HLEmptyNote("documents.detail.extractIncomplete")
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("documents.detail.extractIncomplete")
                    }
                    if showsLink {
                        HLRow(
                            title: Text(String(format: String(localized: "documents.detail.labValuesLink"), count)),
                            accessory: .chevron
                        ) {
                            HLRowGlyph(symbol: "testtube.2")
                        }
                        .hlRowLink { LabsScreen() }
                        .accessibilityIdentifier("documents.detail.labValues")
                    }
                }
            }
        }
    }

    // MARK: - Metadata card

    var metadataCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // Title: the labelled field of the app's forms, on the
                // card's plate instead of a dark bordered box.
                HLTextField(title: String(localized: "documents.detail.titleLabel"), text: $titleDraft, kind: .plain)
                    .submitLabel(.done)
                    .onSubmit { Task { await commitTitle() } }
                    .accessibilityIdentifier("documents.detail.title")
                // Kind: the form's menu row, committed on pick.
                HLFormPicker(
                    "documents.detail.kindLabel",
                    selection: Binding(get: { document.kind }, set: { kind in Task { await commitKind(kind) } }),
                    options: DocumentKindMeta.order
                ) { Text(DocumentKindMeta.labelKey($0)) }
                    .accessibilityIdentifier("documents.detail.kind")
                // Filing date — a direct inline DatePicker (no toggle).
                DocumentFilingDateRow(date: $filingDate)
                    .onChange(of: filingDate) { _, _ in Task { await commitDate() } }
                // When and how big, as the card's last line. A scheduled
                // doctor report (server 1.49.0) says where it came from.
                if document.isScheduledReport {
                    Text("documents.detail.scheduledReport")
                        .hlText(.rowSubtitle)
                        .accessibilityIdentifier("documents.detail.scheduledReport")
                }
                Text(uploadedText)
                    .hlText(.rowSubtitle)
            }
        }
    }

    // MARK: - Conditions card

    /// The linked conditions as tags, and linking as an ordinary row. With
    /// no condition to link and none linked the card has nothing to say.
    @ViewBuilder
    var conditionsCard: some View {
        if !document.conditionLinks.isEmpty || !availableEpisodes.isEmpty {
            HLCard("documents.detail.conditionsLabel") {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    if !document.conditionLinks.isEmpty {
                        HLFlowLayout(spacing: HLSpace.xs) {
                            ForEach(document.conditionLinks, id: \.episodeId) { link in
                                HLBadge(link.name)
                            }
                        }
                    }
                    HLSettingsActionRow(icon: "link", title: "documents.detail.linkCondition", presents: .sheet) {
                        showConditionEditor = true
                    }
                    .disabled(availableEpisodes.isEmpty)
                    .accessibilityIdentifier("documents.detail.linkCondition")
                }
            }
        }
    }

    // MARK: - Commits

    private func commitTitle() async {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue: String? = trimmed.isEmpty ? nil : trimmed
        if newValue == document.title { return }
        if let detail = await store.updateMetadata(id: documentId, .title(newValue)) {
            document = detail.document
        } else {
            actionError = String(localized: "documents.detail.saveError")
        }
    }

    private func commitKind(_ kind: DocumentKind) async {
        guard kind != document.kind else { return }
        if let detail = await store.updateMetadata(id: documentId, .kind(kind)) {
            document = detail.document
        } else {
            actionError = String(localized: "documents.detail.saveError")
        }
    }

    private func commitDate() async {
        let newValue = Self.formatDay(filingDate)
        if newValue == document.documentDate { return }
        if let detail = await store.updateMetadata(id: documentId, .documentDate(newValue)) {
            document = detail.document
        } else {
            actionError = String(localized: "documents.detail.saveError")
        }
    }
}

// MARK: - DocumentConditionLinkEditor

/// Replace-set editor for a document's condition links: toggle any of the
/// caller's illness episodes on/off, then commit the whole set (PATCH
/// `episodeIds`). Server contract caps the set at 20.
struct DocumentConditionLinkEditor: View {
    let linkedEpisodeIds: Set<String>
    let available: [IllnessEpisodeDTO]
    let onCommit: (Set<String>) -> Void

    @State private var selection: Set<String>

    init(linkedEpisodeIds: Set<String>, available: [IllnessEpisodeDTO], onCommit: @escaping (Set<String>) -> Void) {
        self.linkedEpisodeIds = linkedEpisodeIds
        self.available = available
        self.onCommit = onCommit
        _selection = State(initialValue: linkedEpisodeIds)
    }

    private var isDirty: Bool {
        selection != linkedEpisodeIds
    }

    var body: some View {
        HLSheetScaffold(
            "documents.detail.conditionsSheetTitle",
            action: .save(isEnabled: isDirty) {
                onCommit(selection)
                return true
            },
            isDirty: isDirty
        ) {
            List {
                Section {
                    if available.isEmpty {
                        HLEmptyState(
                            icon: "cross.case",
                            title: "documents.linkPicker.noEpisodes"
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    } else {
                        // Several conditions at once: the circles of a multiple choice.
                        ForEach(available) { episode in
                            HLChoiceRow(
                                title: Text(verbatim: episode.label),
                                isSelected: selection.contains(episode.id),
                                mode: .multiple
                            ) {
                                toggle(episode.id)
                            }
                        }
                    }
                }
                .hlFormRowSurface()
            }
            .hlPageMargins()
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else if selection.count < 20 {
            selection.insert(id)
        }
    }
}

// MARK: - DocumentShareSheet

#if canImport(UIKit)
    import UIKit

    /// System share sheet for a prepared file URL (download / share of the
    /// decrypted original). The temp file is cleaned up on completion.
    struct DocumentShareSheet: UIViewControllerRepresentable {
        let url: URL
        let onComplete: () -> Void

        func makeUIViewController(context _: Context) -> UIActivityViewController {
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            controller.completionWithItemsHandler = { _, _, _, _ in
                try? FileManager.default.removeItem(at: url)
                onComplete()
            }
            return controller
        }

        func updateUIViewController(_: UIActivityViewController, context _: Context) {}
    }
#endif

/// The filing date row of the metadata card. A11Y (1.5): at the
/// accessibility sizes the label stands over the date button instead of
/// being squeezed into a column of letters beside it (F-AX-DATEROW, the case
/// `HLAdaptiveDatePickerStyle` cannot reach because the label is drawn here).
/// Its own small view with its own `dynamicTypeSize`, as POLISH-C advised:
/// a generic wrapper around the row crashed the page at XXXL.
struct DocumentFilingDateRow: View {
    @Binding var date: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                label
                picker
            }
        } else {
            HStack {
                label
                Spacer()
                picker
            }
        }
    }

    private var label: some View {
        HLRowTitle("documents.detail.dateLabel")
    }

    private var picker: some View {
        DatePicker("documents.detail.dateLabel", selection: $date, displayedComponents: .date)
            .labelsHidden()
            .accessibilityIdentifier("documents.detail.date")
    }
}
