import SwiftUI

/// **Recently deleted (#151, server v1.46.0).** The deleted documents the
/// daily purge has not removed yet, newest deletion first: title, when it was
/// deleted, when it goes for good; "Restore" and "Delete now" on the swipe
/// and in the context menu. "Delete now" asks first through the delete
/// ladder, a restored document is back in the vault list at once.
///
/// Reached only through ``RecentlyDeletedDocumentsLink`` under the vault list,
/// which shows while the server counts at least one deleted document. Inside
/// somebody else's record that count is 0, so the page is never offered there;
/// a `403` reaching it anyway shows the refusal card.
struct RecentlyDeletedDocumentsScreen: View {
    let vault: DocumentsStore
    @State private var model: DocumentsTrashStore?

    var body: some View {
        ZStack {
            switch model?.phase {
            case .moduleOff:
                refusalCard(reason: nil)
            case .notOffered:
                refusalCard(reason: String(localized: "documents.trash.notOffered"))
            default:
                HLAsyncListScreen(
                    phase: listPhase,
                    refresh: { await model?.load() },
                    loading: { HLAsyncListSkeletonRows(rowCount: 3) },
                    empty: { emptyRows },
                    content: { if let model { loadedRows(model) } }
                )
                .hlPageMargins()
            }
        }
        .navigationTitle(Text("documents.trash.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = DocumentsTrashStore(vault: vault) }
            await model?.load()
        }
    }

    private var listPhase: HLAsyncListPhase {
        guard let model else { return .loading }
        switch model.phase {
        case .loading: return .loading
        case .failed: return model.rows.isEmpty ? .error(retry: { await model.load() }) : .loaded
        case .loaded, .moduleOff, .notOffered: return model.rows.isEmpty ? .empty : .loaded
        }
    }

    private func refusalCard(reason: String?) -> some View {
        FeatureDisabledCard(variant: .hero, reason: reason)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(HLSurface.primary)
    }

    private var emptyRows: some View {
        Section {
            HLEmptyState(icon: "trash", title: "documents.trash.emptyTitle")
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func loadedRows(_ model: DocumentsTrashStore) -> some View {
        if let message = model.outcome {
            Section { outcomeBanner(message, model: model) }
                .hlFormRowSurface()
        }
        Section {
            ForEach(model.rows) { row in
                DeletedDocumentRow(row: row, model: model)
            }
        } footer: {
            footer(model)
        }
        .hlFormRowSurface()
    }

    private func footer(_ model: DocumentsTrashStore) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            if let days = model.graceDays, days > 0 {
                Text(String(format: String(localized: "documents.trash.subtitle"), days))
            }
            if model.isTruncated, let limit = model.cap?.limit {
                Text(String(format: String(localized: "documents.trash.truncated"), limit))
                    .accessibilityIdentifier("documents.trash.truncated")
            }
        }
    }

    private func outcomeBanner(_ message: String, model: DocumentsTrashStore) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HLColor.statusBad)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.hlCaption)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.sm)
            HLLinkButton("documents.outcome.dismiss", alignment: .leading) { model.acknowledgeOutcome() }
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("documents.trash.outcome")
    }
}

// MARK: - Row

/// One deleted document as a data row: what it is, and when it was deleted
/// and goes for good in one detail line. Restoring and deleting for good sit
/// on the swipe and in the context menu, like every other row; two full
/// buttons under each entry made this the loudest list of the app. "Delete
/// now" removes it for good, so it asks first.
private struct DeletedDocumentRow: View {
    let row: DeletedDocument
    let model: DocumentsTrashStore

    private var isBusy: Bool {
        model.busyIDs.contains(row.id)
    }

    var body: some View {
        HLRow(
            title: Text(verbatim: row.resolvedTitle ?? String(localized: "documents.card.untitled")),
            detail: HLRowDetail.text(DeletedDocumentRowDates.lines(for: row))
        ) {
            HLRowGlyph(symbol: DocumentKindMeta.icon(row.kind))
        }
        .opacity(isBusy ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("documents.trash.row.\(row.id)")
        .hlSwipeDelete(purge) {
            restoreButton
                .tint(HLAccent.userBrandTint)
        }
        .contextMenu {
            restoreButton
            HLDeleteMenuItem(purge)
        }
        .hlDeleteConfirmation()
        .disabled(isBusy)
    }

    private var restoreButton: some View {
        Button {
            Task { await model.restore(row) }
        } label: {
            Label("documents.trash.restore", systemImage: "arrow.uturn.backward")
        }
        .accessibilityIdentifier("documents.trash.restore.\(row.id)")
    }

    private var purge: HLDeleteAction {
        .confirmed(
            title: "documents.trash.purgeConfirmTitle",
            message: "documents.trash.purgeConfirmBody",
            word: "documents.trash.purgeConfirm"
        ) { await model.purge(row) }
    }
}

/// "Gelöscht am 4. Nov., wird am 4. Dez. entfernt" for a row: two parts of
/// one sentence, each only when the server sent a readable date. The year
/// shows only outside the current one.
enum DeletedDocumentRowDates {
    static func lines(for row: DeletedDocument, now: Date = .now) -> [String] {
        var lines: [String] = []
        if let deletedAt = row.deletedAt, let date = DocumentFormat.instant(deletedAt) {
            lines.append(String(format: String(localized: "documents.trash.deletedOn.part"), HLDateFormat.dayMonth(date, relativeTo: now)))
        }
        if let purgeAt = row.purgeAt, let date = DocumentFormat.instant(purgeAt) {
            let part = String(format: String(localized: "documents.trash.removesOn.part"), HLDateFormat.dayMonth(date, relativeTo: now))
            // Alone, the second part starts the line.
            lines.append(lines.isEmpty ? part.prefix(1).localizedUppercase + part.dropFirst() : part)
        }
        return lines
    }
}

// MARK: - Link under the vault list

/// The centred text link under the vault list, like "Advanced" elsewhere.
/// Shown only while `deletedCount` is above 0, which a server before v1.46.0
/// never sends and which is 0 inside somebody else's record.
struct RecentlyDeletedDocumentsLink: View {
    let vault: DocumentsStore
    let count: Int

    /// Whether the usage answer offers the link at all.
    nonisolated static func isOffered(_ usage: DocumentUsage?) -> Bool {
        (usage?.deletedCount ?? 0) > 0
    }

    var body: some View {
        // The count is already in words; as a key it finds no entry and
        // stands as it is.
        HLLinkButton(
            LocalizedStringKey(String(format: String(localized: "documents.trash.entryLabel"), count)),
            systemImage: "trash",
            destination: { RecentlyDeletedDocumentsScreen(vault: vault) }
        )
        .accessibilityIdentifier("documents.trash.link")
    }
}
