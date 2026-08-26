import Foundation
import Observation

/// `@Observable` store over ``CoachFactsRepository`` for the "What the assistant
/// knows" surface (list facts grouped by category, forget one, forget all).
///
/// **State machine.** `facts` is the authoritative active list (server order
/// preserved). `isLoading` drives the initial spinner. `isCoachDisabled` is set
/// when the server reports the Coach surface is off (`HLError.assistantDisabled`)
/// so the screen can render the calm disabled-surface placeholder instead of an
/// error banner — mirroring how the rest of the Coach stack honours the
/// kill-switch. `error` carries a user-facing string for genuine failures.
///
/// Read + delete only — there is no create/update path (facts are
/// server-extracted, not user-authored).
@MainActor
@Observable
public final class CoachFactsStore {
    public private(set) var facts: [CoachFactDTO] = []
    public private(set) var isLoading: Bool = false
    /// True once the server reports the Coach surface is operator-disabled. The
    /// screen renders the disabled-surface placeholder when set.
    public private(set) var isCoachDisabled: Bool = false
    public private(set) var error: String?
    /// True once a load has completed at least once (so the empty state only shows
    /// after a real round-trip, not during the first paint).
    public private(set) var didLoad: Bool = false

    private let repo: CoachFactsRepository

    public init(repo: CoachFactsRepository) {
        self.repo = repo
    }

    /// Facts grouped by `category`, preserving the server order within each group
    /// and ordering the groups by their first (highest-confidence) member. Returns
    /// `(category, facts)` tuples so the view can render stable `Section`s.
    public var groupedByCategory: [(category: String, facts: [CoachFactDTO])] {
        var order: [String] = []
        var buckets: [String: [CoachFactDTO]] = [:]
        for fact in facts {
            if buckets[fact.category] == nil {
                order.append(fact.category)
                buckets[fact.category] = []
            }
            buckets[fact.category]?.append(fact)
        }
        return order.map { (category: $0, facts: buckets[$0] ?? []) }
    }

    public var isEmpty: Bool {
        facts.isEmpty
    }

    public func load() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            didLoad = true
        }
        do {
            facts = try await repo.list()
            isCoachDisabled = false
        } catch HLError.assistantDisabled {
            // Operator turned the Coach surface off — render the calm placeholder,
            // not an error. Same kill-switch the rest of the Coach stack honours.
            isCoachDisabled = true
            facts = []
        } catch let err as HLError {
            error = err.userFacingDescription
        } catch {
            self.error = String(localized: "Couldn't load what the assistant knows. Please try again.")
        }
    }

    /// Forget one fact. Optimistically removes it from the list on a confirmed
    /// delete; a `deleted == false` (already gone) also drops it locally since the
    /// server says it is no longer active.
    public func forget(_ fact: CoachFactDTO) async {
        error = nil
        do {
            _ = try await repo.forget(id: fact.id)
            facts.removeAll { $0.id == fact.id }
        } catch HLError.assistantDisabled {
            isCoachDisabled = true
            facts = []
        } catch let err as HLError {
            error = err.userFacingDescription
        } catch {
            self.error = String(localized: "Couldn't forget that. Please try again.")
        }
    }

    /// Forget all facts ("forget all"). Clears the local list on success.
    public func forgetAll() async {
        error = nil
        do {
            _ = try await repo.forgetAll()
            facts = []
        } catch HLError.assistantDisabled {
            isCoachDisabled = true
            facts = []
        } catch let err as HLError {
            error = err.userFacingDescription
        } catch {
            self.error = String(localized: "Couldn't forget everything. Please try again.")
        }
    }

    public func clearError() {
        error = nil
    }

    public func clearOnLogout() {
        facts = []
        error = nil
        isCoachDisabled = false
        didLoad = false
    }
}
