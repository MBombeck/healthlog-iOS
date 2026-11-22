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

    /// The manual AI actions. No longer a heavy standalone
    /// "KI-Unterstützung" card with a section header above the fields: it sits
    /// between the persisted summary and the editable fields, carries no head
    /// (the summary above already names the AI tier), and collapses entirely
    /// once auto-read has settled (see `DocumentDetailScreen.showsAssistActions`).
    /// A suggestion or a summary opens as its own card under it, with a head
    /// and the cross that puts it away.
    var assistCard: some View {
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLButtonPair {
                        HLButton(
                            "documents.assist.suggest",
                            systemImage: "sparkles",
                            variant: .secondary,
                            isLoading: isSuggesting
                        ) {
                            Task { await runSuggest() }
                        }
                        .accessibilityIdentifier("documents.assist.suggest")
                    } secondary: {
                        HLButton(
                            "documents.summary.summarise",
                            systemImage: "text.alignleft",
                            variant: .secondary,
                            isLoading: isSummarising && summaryMode == .summary
                        ) {
                            Task { await runSummary(.summary) }
                        }
                    }
                    HLLinkButton("documents.summary.showText") {
                        Task { await runSummary(.text) }
                    }
                    .disabled(isSummarising)

                    if let suggestError {
                        HLFormErrorText(suggestError)
                    }
                }
            }
            if let suggestion {
                suggestionReview(suggestion)
            }
            if let summaryMode {
                summaryPanel(mode: summaryMode)
            }
        }
        .accessibilityIdentifier("documents.assist.section")
    }

    // MARK: - Suggestion review (drafts → prefill)

    private func suggestionReview(_ suggestion: DocumentSuggestion) -> some View {
        // The title says the suggestions are AI's; the hint line under it is gone.
        HLCard("documents.assist.reviewTitle") {
            HLDismissButton(label: "documents.assist.dismiss") {
                self.suggestion = nil
            }
        } content: {
            if suggestion.hasAny {
                HLFactGroup {
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
                }
            } else {
                HLEmptyNote("documents.assist.empty")
            }
        }
    }

    /// One suggested field: the fact (label and value), and under it either
    /// the action that applies it or the note that it has been applied.
    private func reviewRow(
        label: LocalizedStringKey,
        value: Text,
        applied: Bool,
        applyKey: String,
        apply: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .trailing, spacing: HLSpace.xxs) {
            HLFactRow(label: Text(label), value: value)
            if applied {
                HLBadge(String(localized: "documents.assist.applied"), icon: "checkmark", form: .text)
            } else {
                HLLinkButton(LocalizedStringKey(applyKey), action: apply)
            }
        }
    }

    // MARK: - Summary panel (session-only; not a diagnosis)

    private func summaryPanel(mode: DocumentSummaryMode) -> some View {
        HLCard(LocalizedStringKey(mode == .text ? "documents.summary.textTitle" : "documents.summary.summaryTitle")) {
            HLDismissButton(label: "documents.summary.close") {
                summaryMode = nil
                summary = nil
                summaryError = nil
            }
        } content: {
            if isSummarising {
                HStack(spacing: HLSpace.xs) {
                    ProgressView().controlSize(.small)
                    Text("documents.summary.working")
                        .hlText(.factLabel)
                }
            } else if let summaryError {
                HLFormErrorText(summaryError)
            } else if let prose = summary?.prose {
                HLInsightProse(text: prose)
            }
            // "made for this view only, not saved" is gone.
        }
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
        // One sentence per v1.39 refusal code.
        switch DocumentsRepository.aiRefusalKind(error) {
        case .operatorDisabled:
            return String(localized: "documents.assist.errorOperatorDisabled")
        case .recordNotPermitted:
            return String(localized: "documents.assist.errorRecordNotPermitted")
        case .noProvider:
            return String(localized: "documents.assist.errorProvider")
        case .unavailable, nil:
            break
        }
        if let hl = error as? HLError, case .rateLimited = hl {
            return String(localized: "documents.assist.errorRateLimited")
        }
        // A busy reader or a read cut off before any value each
        // get their own sentence instead of the generic one.
        if let notice = DocumentReadNotice.from(error: error) {
            return notice.message
        }
        return String(localized: "documents.assist.errorGeneric")
    }
}
