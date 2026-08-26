import SwiftUI

// Vault Phase 2 (server v1.27.22, iOS issue #43) — the AI-assist area of the
// document detail: a quiet "Vorschlagen" (suggest → prefill the editable
// title/kind/date) affordance, a "Zusammenfassen" / "Text anzeigen"
// session-only description, and the per-document content-search state + index
// action. Everything here renders only inside `aiAssistEnabled` (server assist
// AND the app's existing AI consent), so it degrades to nothing when either is
// off — mirroring the web's restraint (calm affordances, never loud CTAs).
//
// Session-only by contract: the suggestion is a DRAFT the user applies field by
// field (title seeds the editable field; kind/date commit one field through the
// existing edit-on-commit path); the summary is transient and NOT a diagnosis
// (a discreet caveat is always shown). Neither is ever persisted here.

/// Which suggested fields the user has already applied — drives the "Übernommen"
/// state so an accepted row stops offering its apply button.
struct DocumentAssistApplied: Equatable {
    var title = false
    var kind = false
    var date = false
}

extension DocumentDetailScreen {
    // MARK: - Assist card

    /// **Wave 4.3.** The manual AI actions. No longer a heavy standalone
    /// "KI-Unterstützung" `HLCard` above the fields: it is the web's calm
    /// bordered `bg-muted/30` block, sits between the persisted summary and the
    /// editable fields, carries no section header (the web dropped its chrome in
    /// v1.28.22 — the summary above already names the AI tier), and collapses
    /// entirely once auto-read has settled (see
    /// `DocumentDetailScreen.showsAssistActions`).
    var assistCard: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLWrapLayout(spacing: HLSpace.xs) {
                HLButton(
                    "documents.assist.suggest",
                    icon: "sparkles",
                    variant: .secondary,
                    size: .compact,
                    isLoading: isSuggesting
                ) {
                    Task { await runSuggest() }
                }
                .accessibilityIdentifier("documents.assist.suggest")
                HLButton(
                    "documents.summary.summarise",
                    icon: "text.alignleft",
                    variant: .secondary,
                    size: .compact,
                    isLoading: isSummarising && summaryMode == .summary
                ) {
                    Task { await runSummary(.summary) }
                }
                HLButton(
                    "documents.summary.showText",
                    icon: "doc.plaintext",
                    variant: .ghost,
                    size: .compact,
                    isLoading: isSummarising && summaryMode == .text
                ) {
                    Task { await runSummary(.text) }
                }
            }

            if let suggestError {
                HLFormErrorText(suggestError)
            }
            if let suggestion {
                suggestionReview(suggestion)
            }
            if let summaryMode {
                summaryPanel(mode: summaryMode)
            }
        }
        .padding(HLSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HLRadius.md).fill(HLSurface.secondary))
        .accessibilityIdentifier("documents.assist.section")
    }

    // MARK: - Suggestion review (drafts → prefill)

    private func suggestionReview(_ suggestion: DocumentSuggestion) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(alignment: .top, spacing: HLSpace.xs) {
                Image(systemName: "sparkles")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("documents.assist.reviewTitle")
                        .font(.hlFootnote.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                    Text("documents.assist.reviewHint")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
                Spacer()
                Button {
                    self.suggestion = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
                .accessibilityLabel(Text("documents.assist.dismiss"))
            }

            if suggestion.hasAny {
                if let title = suggestion.title, !title.isEmpty {
                    reviewRow(
                        label: "documents.assist.suggestedTitle",
                        value: Text(verbatim: title),
                        applied: suggestApplied.title,
                        applyKey: "documents.assist.useTitle"
                    ) {
                        applySuggestedTitle(title)
                    }
                }
                if let kind = suggestion.kind {
                    reviewRow(
                        label: "documents.assist.suggestedKind",
                        value: Text(DocumentKindMeta.labelKey(kind)),
                        applied: suggestApplied.kind,
                        applyKey: "documents.assist.apply"
                    ) {
                        Task { await applySuggestedKind(kind) }
                    }
                }
                if let date = suggestion.documentDate, !date.isEmpty {
                    reviewRow(
                        label: "documents.assist.suggestedDate",
                        value: Text(verbatim: DocumentFormat.mediumDate(date)),
                        applied: suggestApplied.date,
                        applyKey: "documents.assist.apply"
                    ) {
                        Task { await applySuggestedDate(date) }
                    }
                }
            } else {
                Text("documents.assist.empty")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.tertiary)
            }
        }
        .padding(HLSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HLRadius.sm).fill(HLSurface.secondary))
    }

    private func reviewRow(
        label: LocalizedStringKey,
        value: Text,
        applied: Bool,
        applyKey: String,
        apply: @escaping () -> Void
    ) -> some View {
        HStack(spacing: HLSpace.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                value
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                    .lineLimit(2)
            }
            Spacer()
            if applied {
                Label("documents.assist.applied", systemImage: "checkmark")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                HLButton(applyKey, variant: .ghost, size: .compact, action: apply)
            }
        }
    }

    // MARK: - Summary panel (session-only; not a diagnosis)

    private func summaryPanel(mode: DocumentSummaryMode) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.hlFootnote.weight(.semibold))
                        .foregroundStyle(HLText.tertiary)
                        .accessibilityHidden(true)
                    HLSectionLabel(LocalizedStringKey(mode == .text ? "documents.summary.textTitle" : "documents.summary.summaryTitle"))
                }
                Spacer()
                Button {
                    summaryMode = nil
                    summary = nil
                    summaryError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
                .accessibilityLabel(Text("documents.summary.close"))
            }

            if isSummarising {
                HStack(spacing: HLSpace.xs) {
                    ProgressView().controlSize(.small)
                    Text("documents.summary.working")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.tertiary)
                }
            } else if let summaryError {
                HLFormErrorText(summaryError)
            } else if let prose = summary?.prose {
                HLInsightProse(text: prose)
            }

            Text("documents.summary.notSaved")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .padding(.top, HLSpace.xxs)
        }
        .padding(HLSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HLRadius.sm).fill(HLSurface.secondary))
    }

    // MARK: - Actions

    private func runSuggest() async {
        suggestError = nil
        isSuggesting = true
        defer { isSuggesting = false }
        do {
            suggestion = try await store.suggest(id: documentId)
            suggestApplied = DocumentAssistApplied()
        } catch {
            suggestError = Self.assistErrorMessage(error)
        }
    }

    private func runSummary(_ mode: DocumentSummaryMode) async {
        summaryError = nil
        summary = nil
        summaryMode = mode
        isSummarising = true
        defer { isSummarising = false }
        do {
            summary = try await store.summarise(id: documentId, mode: mode)
        } catch {
            summaryError = Self.assistErrorMessage(error)
        }
    }

    // MARK: - Apply (drafts → fields)

    /// Seed the editable title field with the suggested label. Matches the web:
    /// applying the title prefills the field; the user still commits it (the
    /// field's existing on-submit path writes it). Nothing is persisted here.
    private func applySuggestedTitle(_ title: String) {
        titleDraft = title
        suggestApplied.title = true
    }

    private func applySuggestedKind(_ kind: DocumentKind) async {
        guard kind != document.kind else {
            suggestApplied.kind = true
            return
        }
        if let detail = await store.updateMetadata(id: documentId, .kind(kind)) {
            document = detail.document
            syncEditState(from: detail.document)
            suggestApplied.kind = true
        } else {
            actionError = String(localized: "documents.detail.saveError")
        }
    }

    private func applySuggestedDate(_ raw: String) async {
        let day = String(raw.prefix(10))
        if let detail = await store.updateMetadata(id: documentId, .documentDate(day)) {
            document = detail.document
            syncEditState(from: detail.document)
            suggestApplied.date = true
        } else {
            actionError = String(localized: "documents.detail.saveError")
        }
    }

    // MARK: - Error copy

    /// Maps an assist failure to calm inline copy — never a raw provider string.
    /// `422 providerUnsupported` reads as "gerade nicht verfügbar" (the server
    /// withdrew assist mid-session); a rate-limit as its own line; anything else
    /// as the generic retry message.
    static func assistErrorMessage(_ error: Error) -> String {
        if DocumentsRepository.isProviderUnsupported(error) {
            return String(localized: "documents.assist.errorProvider")
        }
        if let hl = error as? HLError, case .rateLimited = hl {
            return String(localized: "documents.assist.errorRateLimited")
        }
        return String(localized: "documents.assist.errorGeneric")
    }
}
