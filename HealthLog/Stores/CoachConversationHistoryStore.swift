import Foundation
import Observation

/// `@Observable` store over ``CoachConversationHistoryRepository`` for the
/// "Past conversations" surface — the read-only re-hydration path (b182) that
/// makes server-retained Coach conversations browsable on iOS again, so the
/// coach no longer *feels* forgetful across relaunch / cross-device.
///
/// **State machine.** `conversations` is the rail list (server order preserved).
/// `selected` holds the most recently opened conversation's full, decrypted
/// turns. `isLoading` / `isLoadingDetail` drive the spinners. `isCoachDisabled`
/// is set from the typed ``HLError/assistantDisabled(_:)`` so the screen renders
/// the calm disabled-surface placeholder instead of an error banner — mirroring
/// ``CoachFactsStore``. `error` carries a user-facing string for genuine failures.
///
/// **Read + forget (#30).** Beyond re-hydration, ``deleteConversation(id:)``
/// forgets a conversation server-side with an *optimistic* remove: the row
/// disappears immediately, and on a server failure (including a not-yet-deployed
/// route, live ≤ v1.17.1) it is rolled back into its original position and
/// `deleteError` carries a calm hint. The SSE send still lives in
/// ``CoachServerService``; this store owns the read + the forget.
@MainActor
@Observable
public final class CoachConversationHistoryStore {
    public private(set) var conversations: [CoachConversationSummaryDTO] = []
    public private(set) var selected: CoachConversationDetailDTO?
    public private(set) var isLoading: Bool = false
    public private(set) var isLoadingDetail: Bool = false
    /// True once the server reports the Coach surface is operator-disabled.
    public private(set) var isCoachDisabled: Bool = false
    public private(set) var error: String?
    /// User-facing hint shown when a forget (DELETE) fails and the row was rolled
    /// back. Kept separate from `error` so a failed delete doesn't blank the list.
    public private(set) var deleteError: String?
    /// True once a list load has completed at least once (so the empty state only
    /// shows after a real round-trip, not during first paint).
    public private(set) var didLoad: Bool = false
    /// Cursor for the next page, or `nil` at the end of the list.
    public private(set) var nextCursor: String?

    private let repo: CoachConversationHistoryRepository

    public init(repo: CoachConversationHistoryRepository) {
        self.repo = repo
    }

    public var isEmpty: Bool {
        conversations.isEmpty
    }

    public var canLoadMore: Bool {
        nextCursor != nil
    }

    /// Load the first page of conversations (SWR-style: replaces the list).
    public func load() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            didLoad = true
        }
        do {
            let page = try await repo.list()
            conversations = page.conversations
            nextCursor = page.nextCursor
            isCoachDisabled = false
        } catch HLError.assistantDisabled {
            isCoachDisabled = true
            conversations = []
            nextCursor = nil
        } catch let err as HLError {
            error = err.userFacingDescription
        } catch {
            self.error = String(localized: "Couldn't load your past conversations. Please try again.")
        }
    }

    /// Append the next page when one exists. No-op at the end of the list.
    public func loadMore() async {
        guard let cursor = nextCursor, !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = try await repo.list(cursor: cursor)
            conversations.append(contentsOf: page.conversations)
            nextCursor = page.nextCursor
        } catch HLError.assistantDisabled {
            isCoachDisabled = true
        } catch let err as HLError {
            error = err.userFacingDescription
        } catch {
            self.error = String(localized: "Couldn't load more conversations. Please try again.")
        }
    }

    /// Re-hydrate one conversation's full, decrypted turns from the server.
    public func openConversation(id: String) async {
        isLoadingDetail = true
        error = nil
        defer { isLoadingDetail = false }
        do {
            selected = try await repo.detail(id: id)
            isCoachDisabled = false
        } catch HLError.assistantDisabled {
            isCoachDisabled = true
            selected = nil
        } catch let err as HLError {
            error = err.userFacingDescription
        } catch {
            self.error = String(localized: "Couldn't open that conversation. Please try again.")
        }
    }

    /// Forget one conversation server-side with an optimistic remove.
    ///
    /// The row (and any open detail) vanishes *immediately* for a snappy gesture;
    /// the server `DELETE` then confirms it. On any failure — including a disabled
    /// surface, a disabled module, a 404 (already gone / foreign id) or a
    /// not-yet-deployed route (live ≤ v1.17.1) — the row is restored to its
    /// original index and `deleteError` carries a calm hint. Never crashes; the
    /// list is always left coherent.
    public func deleteConversation(id: String) async {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let removed = conversations.remove(at: index)
        if selected?.id == id { selected = nil }
        deleteError = nil
        do {
            try await repo.deleteConversation(id: id)
        } catch {
            // Rollback: re-insert at the original position (clamped — the list may
            // have shifted under a concurrent load).
            let insertAt = min(index, conversations.count)
            conversations.insert(removed, at: insertAt)
            deleteError = String(localized: "Couldn't delete that conversation. Please try again.")
        }
    }

    public func clearError() {
        error = nil
    }

    public func clearDeleteError() {
        deleteError = nil
    }

    public func clearOnLogout() {
        conversations = []
        selected = nil
        nextCursor = nil
        error = nil
        deleteError = nil
        isCoachDisabled = false
        didLoad = false
    }
}
