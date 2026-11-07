import SwiftUI

/// **Recently deleted (#151, server v1.46.0).** The deleted documents the
/// daily purge has not removed yet, newest deletion first: title, when it was
/// deleted, when it goes for good, and per row "Restore" and "Delete now".
/// "Delete now" asks in place (the frozen presentation inventory admits no new
/// dialog), a restored document is back in the vault list at once.
///
/// Reached only through ``RecentlyDeletedDocumentsLink`` under the vault list,
/// which shows while the server counts at least one deleted document. Inside
/// somebody else's record that count is 0, so the page is never offered there;
/// a `403` reaching it anyway shows the refusal card.
struct RecentlyDeletedDocumentsScreen: View {
    let vault: DocumentsStore
    @State private var model: DocumentsTrashStore?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        }
        Section {
            ForEach(model.rows) { row in
                DeletedDocumentRow(
                    row: row,
                    model: model,
                    stacked: dynamicTypeSize.isAccessibilitySize
                )
            }
        } footer: {
            footer(model)
        }
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
            Button("documents.outcome.dismiss") { model.acknowledgeOutcome() }
                .font(.hlCaption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("documents.trash.outcome")
    }
}

// MARK: - Row

/// One deleted document: what it is, when it was deleted, when it goes for
/// good, and its two actions. "Delete now" turns the action line into the
/// question with its own destructive button and a cancel.
private struct DeletedDocumentRow: View {
    let row: DeletedDocument
    let model: DocumentsTrashStore
    let stacked: Bool

    private var isConfirming: Bool {
        model.confirmingPurgeID == row.id
    }

    private var isBusy: Bool {
        model.busyIDs.contains(row.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Image(systemName: DocumentKindMeta.icon(row.kind))
                    .font(.hlIcon(HLIconSize.sm))
                    .foregroundStyle(HLText.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(verbatim: row.resolvedTitle ?? String(localized: "documents.card.untitled"))
                        .font(.hlBody)
                        .foregroundStyle(HLText.primary)
                    ForEach(DeletedDocumentRowDates.lines(for: row), id: \.self) { line in
                        Text(verbatim: line)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if isConfirming {
                confirmation
            } else {
                actions
            }
        }
        .padding(.vertical, HLSpace.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("documents.trash.row.\(row.id)")
    }

    @ViewBuilder
    private var actions: some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.sm))
            : AnyLayout(HStackLayout(spacing: HLSpace.lg))
        layout {
            Button {
                Task { await model.restore(row) }
            } label: {
                Label("documents.trash.restore", systemImage: "arrow.uturn.backward")
                    .foregroundStyle(.tint)
            }
            .accessibilityIdentifier("documents.trash.restore.\(row.id)")
            Button(role: .destructive) {
                model.confirmingPurgeID = row.id
            } label: {
                Label("documents.trash.purge", systemImage: "trash")
                    .foregroundStyle(HLColor.statusBad)
            }
            .accessibilityIdentifier("documents.trash.purge.\(row.id)")
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .font(.hlSubhead)
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("documents.trash.purgeConfirmTitle")
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            Text("documents.trash.purgeConfirmBody")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.sm))
                : AnyLayout(HStackLayout(spacing: HLSpace.lg))
            layout {
                Button(role: .destructive) {
                    Task { await model.purge(row) }
                } label: {
                    Text("documents.trash.purgeConfirm")
                        .fontWeight(.semibold)
                        .foregroundStyle(HLColor.statusBad)
                }
                .accessibilityIdentifier("documents.trash.purge.confirm.\(row.id)")
                Button {
                    model.confirmingPurgeID = nil
                } label: {
                    Text("illness.action.cancel").foregroundStyle(.tint)
                }
                .accessibilityIdentifier("documents.trash.purge.cancel.\(row.id)")
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.hlSubhead)
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
    }
}

/// "Deleted on …" and "Removed for good on …" for a row, each only when the
/// server sent a readable date.
enum DeletedDocumentRowDates {
    static func lines(for row: DeletedDocument) -> [String] {
        var lines: [String] = []
        if let deletedAt = row.deletedAt, DocumentFormat.instant(deletedAt) != nil {
            lines.append(String(format: String(localized: "documents.trash.deletedOn"), DocumentFormat.mediumDate(deletedAt)))
        }
        if let purgeAt = row.purgeAt, DocumentFormat.instant(purgeAt) != nil {
            lines.append(String(format: String(localized: "documents.trash.removesOn"), DocumentFormat.mediumDate(purgeAt)))
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
        NavigationLink {
            RecentlyDeletedDocumentsScreen(vault: vault)
        } label: {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "trash")
                    .font(.hlIcon(HLIconSize.sm))
                    .accessibilityHidden(true)
                Text(String(format: String(localized: "documents.trash.entryLabel"), count))
                    .font(.hlSubhead.weight(.semibold))
            }
            .foregroundStyle(HLText.secondary)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("documents.trash.link")
    }
}
