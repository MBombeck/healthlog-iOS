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
/// **Server-only surface.** Conversation history lives on the server, so the
/// screen gates on `BackendAvailability.hasServer` (standalone → the calm
/// `HLCloudDerivedPlaceholder`, never a dead list). When paired but the operator
/// disabled the Coach surface, the store flips `isCoachDisabled` (from the typed
/// `HLError.assistantDisabled`) and we render the disabled-surface placeholder.
///
/// **Read + forget (#30, v1.18.0).** Beyond re-hydration, a native swipe-to-delete
/// (with a destructive confirmation) forgets a conversation server-side
/// (`DELETE /api/insights/chat/{id}`). The remove is optimistic; a server failure
/// (including a not-yet-deployed route on live ≤ v1.17.1) rolls the row back and
/// shows a calm hint instead of a crash.
///
/// Entry point: `Settings → Coach → Past conversations`.
struct CoachConversationsScreen: View {
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) private var container

    @State private var store: CoachConversationHistoryStore?
    /// The conversation the user has swiped to delete, awaiting confirmation.
    @State private var pendingDelete: CoachConversationSummaryDTO?

    var body: some View {
        Group {
            if backend.hasServer {
                connectedBody
            } else {
                List {
                    HLCloudDerivedPlaceholder(
                        variant: .inline,
                        surfaceName: String(localized: "your past conversations"),
                        onConnect: { authStore.beginServerPairing() }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("Past conversations")
        .navigationBarTitleDisplayMode(.inline)
        .hlConfirmDestructive(
            Text("Delete this conversation?"),
            presenting: $pendingDelete,
            message: { _ in
                Text("This removes it from your server on all devices. This can't be undone.")
            },
            confirm: Text("Delete"),
            confirmIdentifier: "coachConversations.confirmDelete",
            cancel: Text("Cancel"),
            onCancel: { pendingDelete = nil },
            action: { conversation in
                let id = conversation.id
                pendingDelete = nil
                Task { await store?.deleteConversation(id: id) }
            }
        )
        .alert(
            Text("Couldn't delete conversation"),
            isPresented: deleteErrorBinding,
            presenting: store?.deleteError
        ) { _ in
            Button {
                store?.clearDeleteError()
            } label: {
                Text("OK")
            }
        } message: { message in
            Text(message)
        }
        .task {
            guard backend.hasServer, store == nil, let api = container?.api else { return }
            let s = CoachConversationHistoryStore(repo: CoachConversationHistoryRepository(api: api))
            store = s
            await s.load()
        }
    }

    /// Drives the confirmation dialog from `pendingDelete` (set/clear only).
    private var confirmDeleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    /// Drives the failure alert from the store's `deleteError`.
    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { store?.deleteError != nil },
            set: { if !$0 { store?.clearDeleteError() } }
        )
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
                HLCloudDerivedPlaceholder(
                    variant: .inline,
                    surfaceName: String(localized: "the coach")
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        } else if store.isLoading, !store.didLoad {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isEmpty {
            emptyState
        } else {
            conversationsList(store: store)
        }
    }

    /// Calm empty state — no conversations on the server yet.
    private var emptyState: some View {
        HLEmptyState(
            icon: "bubble.left.and.bubble.right",
            title: "No conversations yet",
            message: "When you chat with the coach, your conversations are kept so you can pick them back up here — on any device."
        )
        .containerCentered()
    }

    private func conversationsList(store: CoachConversationHistoryStore) -> some View {
        List {
            Section {
                Text(
                    "These conversations are kept on your server. Open one to read it back — the coach remembers them across your devices."
                )
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(store.conversations) { conversation in
                    NavigationLink {
                        CoachConversationDetailView(store: store, conversation: conversation)
                    } label: {
                        conversationRow(conversation)
                    }
                    .accessibilityIdentifier("coachConversations.row.\(conversation.id)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = conversation
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityLabel(Text("Delete conversation"))
                        .accessibilityIdentifier("coachConversations.delete.\(conversation.id)")
                    }
                }

                if store.canLoadMore {
                    Button {
                        Task { await store.loadMore() }
                    } label: {
                        if store.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Show more")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .accessibilityIdentifier("coachConversations.loadMore")
                }
            }
        }
    }

    private func conversationRow(_ conversation: CoachConversationSummaryDTO) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(conversation.title.isEmpty ? String(localized: "Conversation") : conversation.title)
                .font(.hlBody.weight(.semibold))
                .foregroundStyle(HLText.primary)
                .lineLimit(2)
            Text(
                String(
                    localized: "\(conversation.messageCount) messages",
                    comment: "Coach conversation row subtitle: number of messages"
                )
            )
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
        }
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
                // No detail yet (e.g. load failed) — calm fallback, never a blank.
                HLEmptyState(
                    icon: "exclamationmark.bubble",
                    title: "Couldn't load this conversation",
                    message: "Please try again."
                )
                .containerCentered()
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
            .padding(.horizontal, HLSpace.lg)
            .padding(.vertical, HLSpace.lg)
        }
        .hlScreenBackground()
    }

    private func summaryCard(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text("Earlier in this conversation")
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
            Text(summary)
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HLSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                .fill(HLSurface.secondary)
        )
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
