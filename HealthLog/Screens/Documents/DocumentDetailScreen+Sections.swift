import SwiftUI

// The metadata + conditions cards for `DocumentDetailScreen`, plus the
// condition-link editor sheet and the file share sheet. Split out to keep the
// screen file within the length budget.

extension DocumentDetailScreen {
    // MARK: - Persisted summary section (Wave 4.2)

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
        if let prose = document.resolvedSummary {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    HLSectionLabel("documents.detail.summary.title")
                    // Web parity: the AI narrative is FOREGROUND content, not
                    // muted meta (only the generation date below is muted).
                    HLInsightProse(text: prose, color: HLText.primary)
                    if let generatedAt = document.summaryGeneratedAt, !generatedAt.isEmpty {
                        Text(verbatim: DocumentFormat.mediumDate(generatedAt))
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("documents.detail.summary")
        } else if contentIndexEnabled {
            Text("documents.detail.summary.pending")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("documents.detail.summary.pending")
        }
    }

    // MARK: - Lab-values jump (Wave 4.5)

    /// The web's `…lab-values-link`: when the labs module is on and this
    /// document staged ≥ 1 non-rejected OBSERVATION fact, a direct jump into
    /// Labs. Counted from the detail's own `facts` (already loaded) — the client
    /// never re-derives lab VALUES, only how many there are.
    @ViewBuilder
    var labValuesLink: some View {
        let count = InboundDocumentDetail.labFactCount(in: facts)
        if count > 0, labsModuleEnabled {
            NavigationLink {
                LabsScreen()
            } label: {
                Label {
                    Text(String(format: String(localized: "documents.detail.labValuesLink"), count))
                } icon: {
                    Image(systemName: "testtube.2")
                }
                .font(.hlSubhead)
            }
            .accessibilityIdentifier("documents.detail.labValues")
        }
    }

    // MARK: - AI-read provenance (Wave 4.6 / research A4.6)

    /// The web's muted `documents.ai.statusAiRead` line — shown only when the
    /// content index was produced by a provider READING the original (`vision`),
    /// never for a local extraction. Pure provenance, never a to-do.
    @ViewBuilder
    var aiReadProvenanceLine: some View {
        if document.isAiRead {
            Label("documents.ai.statusAiRead", systemImage: "sparkles")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("documents.detail.aiRead")
        }
    }

    // MARK: - Metadata card

    var metadataCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // Title.
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    fieldLabel("documents.detail.titleLabel")
                    TextField("documents.detail.titlePlaceholder", text: $titleDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.hlBody)
                        .submitLabel(.done)
                        .onSubmit { Task { await commitTitle() } }
                        .accessibilityIdentifier("documents.detail.title")
                }
                // Kind — a plain menu picker (no toggle).
                HStack {
                    fieldLabel("documents.detail.kindLabel")
                    Spacer()
                    Menu {
                        ForEach(DocumentKindMeta.order) { kind in
                            Button {
                                Task { await commitKind(kind) }
                            } label: {
                                Label(DocumentKindMeta.labelKey(kind), systemImage: DocumentKindMeta.icon(kind))
                            }
                        }
                    } label: {
                        HStack(spacing: HLSpace.xxs) {
                            Image(systemName: DocumentKindMeta.icon(document.kind))
                                .font(.hlSubhead)
                            Text(DocumentKindMeta.labelKey(document.kind))
                                .font(.hlSubhead)
                        }
                        .foregroundStyle(HLText.primary)
                    }
                    .accessibilityIdentifier("documents.detail.kind")
                }
                // Filing date — a direct inline DatePicker (no toggle).
                HStack {
                    fieldLabel("documents.detail.dateLabel")
                    Spacer()
                    DatePicker(
                        "documents.detail.dateLabel",
                        selection: $filingDate,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .onChange(of: filingDate) { _, _ in Task { await commitDate() } }
                    .accessibilityIdentifier("documents.detail.date")
                }
            }
        }
    }

    /// The shared card-field label — routed through the app-wide canonical
    /// `HLSectionLabel` (audit-01 C3) so the Documents detail speaks the same
    /// section-label language as every other screen.
    func fieldLabel(_ key: LocalizedStringKey) -> some View {
        HLSectionLabel(key)
    }

    // MARK: - Conditions card

    var conditionsCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                fieldLabel("documents.detail.conditionsLabel")
                if document.conditionLinks.isEmpty {
                    Text("documents.detail.noConditions")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.tertiary)
                } else {
                    HLFlowChips(items: document.conditionLinks.map(\.name))
                }
                HLButton("documents.detail.linkCondition", icon: "link", variant: .secondary, size: .compact) {
                    showConditionEditor = true
                }
                .disabled(availableEpisodes.isEmpty)
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
    @Environment(\.dismiss) private var dismiss

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
        NavigationStack {
            List {
                if available.isEmpty {
                    HLEmptyState(
                        icon: "cross.case",
                        title: "documents.linkPicker.noEpisodes"
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(available) { episode in
                        Button {
                            toggle(episode.id)
                        } label: {
                            HStack {
                                Text(verbatim: episode.label)
                                    .foregroundStyle(HLText.primary)
                                Spacer()
                                if selection.contains(episode.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(HLAccent.userBrandTint)
                                }
                            }
                        }
                        .accessibilityAddTraits(selection.contains(episode.id) ? [.isSelected] : [])
                    }
                }
            }
            .navigationTitle(Text("documents.detail.conditionsLabel"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("documents.action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("documents.action.save") {
                        onCommit(selection)
                        dismiss()
                    }
                    .disabled(!isDirty)
                }
            }
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

// MARK: - HLFlowChips

/// A simple wrapping row of read-only capsule chips (condition names).
struct HLFlowChips: View {
    let items: [String]

    var body: some View {
        HLWrapLayout(spacing: HLSpace.xxs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, name in
                Text(verbatim: name)
                    .font(.hlCaption)
                    .lineLimit(1)
                    .padding(.horizontal, HLSpace.xs)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(HLSurface.secondary))
                    .foregroundStyle(HLText.secondary)
            }
        }
    }
}

/// Minimal flow layout that wraps its children onto new lines.
struct HLWrapLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
                rows.append(0)
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let maxWidth = proposal.width ?? bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
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
