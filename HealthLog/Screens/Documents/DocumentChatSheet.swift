import SwiftUI

/// Vault Phase 4 — the per-document chat sheet (server v1.27.33, iOS issue #43).
/// A document-scoped Q&A that looks like the Coach transcript (same bubble
/// surfaces + typing indicator + composer language) but is grounded ONLY in this
/// one document's own figures. A discreet caveat states that plainly, and the
/// honest gate / limit / error states never dead-end silently.
///
/// Gating happens before this ever opens (the detail screen ANDs `hasContentIndex`
/// + server assist + the app's remote-AI consent); the sheet additionally reflects
/// a mid-session gate withdrawal (`notIndexed` / `consentRequired`) or a budget
/// bucket (`limitReached`) surfaced by the store.
struct DocumentChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let store: DocumentChatStore

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                caveat
                transcript
                if let state = store.errorState {
                    errorBanner(state)
                }
                if showsInput {
                    inputRow
                }
            }
            .hlScreenBackground()
            .navigationTitle(Text("documents.chat.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.cancel()
                        dismiss()
                    } label: {
                        Text("documents.chat.close")
                    }
                    .accessibilityIdentifier("documents.chat.close")
                }
            }
            .task { await store.loadHistory() }
        }
    }

    // MARK: - Caveat (no diagnosis, document-scoped)

    private var caveat: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
            Text("documents.chat.caveat")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HLSpace.lg)
        .padding(.vertical, HLSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HLSurface.secondary)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HLSpace.md) {
                    if store.isEmpty, store.errorState == nil, !store.isLoadingHistory {
                        emptyPrompt
                    }
                    ForEach(store.messages) { turn in
                        DocumentChatBubble(role: turn.role, text: turn.text)
                            .id(turn.id)
                    }
                    if store.isResponding {
                        if store.streamingText.isEmpty {
                            DocumentChatTypingBubble()
                                .id("typing-indicator")
                        } else {
                            DocumentChatBubble(role: .assistant, text: store.streamingText)
                                .id("streaming-tail")
                        }
                    }
                    Color.clear.frame(height: 1).id("transcript-tail")
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.vertical, HLSpace.md)
            }
            .onChange(of: store.messages) { _, _ in scrollToTail(proxy) }
            .onChange(of: store.streamingText) { _, _ in scrollToTail(proxy) }
            .onChange(of: store.isResponding) { _, _ in scrollToTail(proxy) }
        }
    }

    private func scrollToTail(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            proxy.scrollTo("transcript-tail", anchor: .bottom)
        }
    }

    private var emptyPrompt: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text("documents.chat.empty.title")
                // Audit-01 C2 — sheet-header role on the app standard
                // `.hlTitle3` (vgl. AskCoachSheet, DocumentUploadSheet).
                .font(.hlTitle3)
                .foregroundStyle(HLText.primary)
            Text("documents.chat.empty.hint")
                .font(.hlSubhead)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, HLSpace.xl)
    }

    // MARK: - Error / limit / gate states

    private func errorBanner(_ state: DocumentChatStore.ErrorState) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Label {
                Text(errorMessageKey(state))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: errorIcon(state))
                    .foregroundStyle(HLText.tertiary)
            }
            if state == .limitReached || state == .generic {
                HLButton("documents.chat.retry", variant: .secondary, size: .compact) {
                    Task { await store.retry() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HLSpace.md)
        .background(HLSurface.secondary)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
        .padding(.horizontal, HLSpace.lg)
        .padding(.bottom, HLSpace.sm)
    }

    private func errorMessageKey(_ state: DocumentChatStore.ErrorState) -> LocalizedStringKey {
        switch state {
        case .notIndexed: "documents.chat.notIndexed"
        case .consentRequired: "documents.chat.consentRequired"
        case .limitReached: "documents.chat.limitReached"
        case .generic: "documents.chat.error"
        }
    }

    private func errorIcon(_ state: DocumentChatStore.ErrorState) -> String {
        switch state {
        case .notIndexed: "text.magnifyingglass"
        case .consentRequired: "lock.shield"
        case .limitReached: "hourglass"
        case .generic: "exclamationmark.triangle"
        }
    }

    /// The composer is hidden on a dead-end gate state (nothing the user can send
    /// resolves it here); shown otherwise (including the retriable limit / error).
    private var showsInput: Bool {
        store.errorState != .notIndexed && store.errorState != .consentRequired
    }

    // MARK: - Composer

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: HLSpace.sm) {
            TextField(
                String(localized: "documents.chat.placeholder"),
                text: $draft,
                axis: .vertical
            )
            .lineLimit(1 ... 5)
            .textFieldStyle(.plain)
            .font(.hlBody)
            .foregroundStyle(HLText.primary)
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.sm)
            .background(HLSurface.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
            .focused($inputFocused)
            .submitLabel(.send)
            .disabled(store.isResponding)
            .onSubmit(submit)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.hlIcon(HLIconSize.lg))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(canSend ? HLAccent.primary : HLText.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Text("documents.chat.send"))
        }
        .padding(.horizontal, HLSpace.lg)
        .padding(.vertical, HLSpace.sm)
        // 08-14 — the composer bar is the document chat's one translucent
        // surface. `HLMaterialBackground` keeps the material as the standard
        // presentation and hands Reduce Transparency the opaque fill, which is
        // the shared seam 08-04 built and the clause 08-02 wrote about this file.
        .background(HLMaterialBackground(.thinMaterial))
    }

    private var canSend: Bool {
        !store.isResponding && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !store.isResponding else { return }
        draft = ""
        Task { await store.send(trimmed) }
    }
}

// MARK: - Bubble (mirrors the Coach transcript surfaces)

/// One message bubble. Role distinction comes from alignment + surface, not a hue
/// — identical to the Coach: the user bubble fills the neutral `HLSurface.tertiary`
/// with adaptive ink; the assistant bubble keeps the always-dark canonical surface
/// with the AI-hero ink. Assistant prose renders as PLAIN text (document chat is
/// plain text by contract — no markdown).
private struct DocumentChatBubble: View {
    let role: DocumentChatMessageRole
    let text: String

    private var isUser: Bool {
        role == .user
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: HLSpace.xxl) }
            Text(verbatim: text)
                .font(.hlBody)
                .foregroundStyle(isUser ? HLText.primary : HLColor.aiHeroInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, HLSpace.md)
                .padding(.vertical, HLSpace.sm)
                .background(isUser ? HLSurface.tertiary : HLColor.surfaceCanonicalDracula)
                .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
            if !isUser { Spacer(minLength: HLSpace.xxl) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            (isUser ? String(localized: "You: ") : String(localized: "documents.chat.assistantPrefix")) + text
        )
    }
}

/// Three-dot typing indicator on the assistant surface — mirrors the Coach's
/// `CoachTypingBubble` (reduce-motion renders static dots, no pulse).
private struct DocumentChatTypingBubble: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: HLSpace.xs) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(HLColor.aiHeroInk.opacity(dotOpacity(index)))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, HLSpace.md)
        .padding(.vertical, HLSpace.sm)
        .background(HLColor.surfaceCanonicalDracula)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
        .accessibilityLabel(Text("documents.chat.typing"))
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                phase = (phase + 1) % 3
            }
        }
    }

    private func dotOpacity(_ index: Int) -> Double {
        if reduceMotion { return 0.35 }
        return phase == index ? 0.9 : 0.35
    }
}
