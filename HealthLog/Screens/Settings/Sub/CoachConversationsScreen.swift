import SwiftUI

/// **b182 (AUDIT-COACH-PARITY §B) — "Past conversations" (server read-only).**
///
/// Lists the Coach conversations the server retains (`GET /api/insights/chat`) and
/// re-hydrates a selected one's full, decrypted turns
/// (`GET /api/insights/chat/{id}`). This closes the felt gap behind the operator's
/// "weiß nicht ob er sich was merkt": iOS chat is local-first, so a relaunch — or
/// a chat started on web — used to show a blank transcript even though the server
/// kept the conversation + its rolling summary. Browsing them here makes the
/// coach's continuity visible across launches/devices, matching web.
///
/// **Server-only surface.** Conversation history lives on the server. When the
/// operator disabled the Coach surface, the store flips `isCoachDisabled` (from the typed
/// `HLError.aiUnavailable`) and we render the disabled-surface placeholder.
///
/// **Read + forget (#30, v1.18.0).** Beyond re-hydration, a native swipe-to-delete
/// (with a destructive confirmation) forgets a conversation server-side
/// (`DELETE /api/insights/chat/{id}`). The remove is optimistic; a server failure
/// (including a not-yet-deployed route on live ≤ v1.17.1) rolls the row back and
/// shows a calm hint instead of a crash.
///
/// Entry point: `Settings → Coach → Past conversations`.
struct CoachConversationsScreen: View {
    @Environment(\.appContainer) private var container

    @State private var store: CoachConversationHistoryStore?

    var body: some View {
        connectedBody
            // The page's canvas in every state, not pure black while empty.
            .hlScreenBackground()
            .navigationTitle("Past conversations")
            .navigationBarTitleDisplayMode(.inline)
            .hlAcknowledgeAlert(
                "Couldn't delete conversation",
                item: Binding(get: { store?.deleteError }, set: { if $0 == nil { store?.clearDeleteError() } })
            ) { message in
                Text(message)
            }
            .task {
                guard store == nil, let api = container?.api else { return }
                let s = CoachConversationHistoryStore(repo: CoachConversationHistoryRepository(api: api))
                store = s
                await s.load()
            }
    }

    @ViewBuilder
    private var connectedBody: some View {
        if let store {
            content(store: store)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(store: CoachConversationHistoryStore) -> some View {
        if store.isCoachDisabled {
            List {
                CoachUnavailableCard()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .hlPageMargins()
        } else if store.isLoading, !store.didLoad {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isEmpty {
            emptyState
        } else {
            conversationsList(store: store)
        }
    }

    /// Calm empty state — no conversations on the server yet. It scrolls,
    /// so at large text sizes the sentence wraps in full instead of being cut.
    private var emptyState: some View {
        ScrollView {
            HLEmptyState(
                icon: "bubble.left.and.bubble.right",
                title: "No conversations yet",
                message: "When you chat with the coach, your conversations are kept so you can pick them back up here — on any device."
            )
        }
    }

    private func conversationsList(store: CoachConversationHistoryStore) -> some View {
        // No lead section: where conversations are kept is said
        // once, in the Coach settings' (i).
        List {
            Section {
                ForEach(store.conversations) { conversation in
                    // A conversation is an entry, not a menu: the whole row
                    // opens it, without a chevron.
                    conversationRow(conversation)
                        .hlRowLink(inList: true) {
                            CoachConversationDetailView(store: store, conversation: conversation)
                        }
                        .accessibilityIdentifier("coachConversations.row.\(conversation.id)")
                        .hlSwipeDelete(.confirmed(
                            title: "Delete this conversation?",
                            message: "This removes it from your server on all devices. This can't be undone."
                        ) {
                            await store.deleteConversation(id: conversation.id)
                        })
                }

                // The last row fetches the next page as it scrolls in.
                HLLoadMoreRow(hasMore: store.canLoadMore, isLoading: store.isLoading, trigger: .onAppear) {
                    Task { await store.loadMore() }
                }
            }
            .hlFormRowSurface()
        }
        .hlPageMargins()
    }

    private func conversationRow(_ conversation: CoachConversationSummaryDTO) -> some View {
        HLRow(
            title: Text(verbatim: conversation.title.isEmpty ? String(localized: "Conversation") : conversation.title),
            detail: Text(
                String(
                    localized: "\(conversation.messageCount) messages",
                    comment: "Coach conversation row subtitle: number of messages"
                )
            )
        )
        .accessibilityElement(children: .combine)
    }
}

/// Read-only transcript of one re-hydrated conversation. Loads the full,
/// decrypted turns on appear and renders them oldest-first. The rolling summary
/// (when present) is surfaced first so the user sees what the coach folded away.
private struct CoachConversationDetailView: View {
    let store: CoachConversationHistoryStore
    let conversation: CoachConversationSummaryDTO

    var body: some View {
        Group {
            if store.isLoadingDetail, store.selected?.id != conversation.id {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = store.selected, detail.id == conversation.id {
                transcript(detail)
            } else {
                // No detail yet (e.g. load failed) — calm fallback, never a
                // blank. A real retry instead of "please try again"
                // with nothing to tap.
                HLErrorState("Couldn't load this conversation") {
                    await store.openConversation(id: conversation.id)
                }
                .padding(.horizontal, HLLayout.pageMargin)
            }
        }
        .navigationTitle(conversation.title.isEmpty ? String(localized: "Conversation") : conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: conversation.id) {
            await store.openConversation(id: conversation.id)
        }
    }

    private func transcript(_ detail: CoachConversationDetailDTO) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HLSpace.md) {
                if let summary = detail.summary, !summary.isEmpty {
                    summaryCard(summary)
                }
                ForEach(detail.messages) { message in
                    messageBubble(message)
                }
            }
            .padding(.horizontal, HLLayout.cardInset)
            .padding(.vertical, HLLayout.cardInset)
        }
        .hlScreenBackground()
    }

    private func summaryCard(_ summary: String) -> some View {
        HLCard("Earlier in this conversation") {
            Text(summary)
                .hlText(.factLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func messageBubble(_ message: CoachConversationMessageDTO) -> some View {
        // Mirror the canonical AskCoach transcript recipe: user bubble = adaptive
        // `HLSurface.tertiary` + `HLText.primary`; assistant bubble = the always-
        // dark `surfaceCanonicalDracula` + the tokenized AI-hero white ink.
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: HLSpace.xl) }
            Text(message.content)
                .font(.hlBody)
                .foregroundStyle(isUser ? HLText.primary : HLColor.aiHeroInk)
                .padding(.horizontal, HLSpace.md)
                .padding(.vertical, HLSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                        .fill(isUser ? HLSurface.tertiary : HLColor.surfaceCanonicalDracula)
                )
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: HLSpace.xl) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isUser
                ? Text("You: \(message.content)")
                : Text("Coach: \(message.content)")
        )
    }
}

#Preview("CoachConversationsScreen") {
    NavigationStack {
        CoachConversationsScreen()
    }
}
