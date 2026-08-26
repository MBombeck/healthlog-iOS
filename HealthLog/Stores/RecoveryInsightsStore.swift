import Foundation
import Observation

/// `@Observable` wrapper over `RecoveryInsightsRepository`. Hydrates the
/// Insights **Recovery** sub-page (web `/insights/recovery`, server v1.17.1 —
/// GH #23): the server-computed recovery family (strain, training-load /
/// `CARDIO_LOAD`, autonomic-charge / `ANS_CHARGE`, and the daily
/// heart-and-energy items).
///
/// **HONEST-ONLY + server-authoritative.** The store surfaces ONLY the family
/// the server returns — it never recomputes strain/load and never fabricates a
/// value. An absent / insufficient payload leaves ``family`` `nil` so the page
/// renders its honest empty state.
///
/// **Server-derived (paired only).** Pure server compute, no on-device
/// fallback — the page additionally gates on a cloud surface being available so
/// it hides in standalone / no-server.
@MainActor
@Observable
public final class RecoveryInsightsStore {
    /// The latest decoded recovery family, or `nil` when the server returned
    /// nothing renderable (route absent, empty, or below the data gate).
    public private(set) var family: RecoveryInsightsDTO?
    public private(set) var isLoading: Bool = false
    /// `true` once a load has completed at least once this session — lets the
    /// page distinguish "still loading" (show skeleton/nothing) from "settled +
    /// empty" (show the honest empty state).
    public private(set) var hasSettledOnce: Bool = false

    private let repo: RecoveryInsightsRepository

    public init(repo: RecoveryInsightsRepository) {
        self.repo = repo
    }

    /// `true` when the server returned at least one renderable family item.
    public var hasContent: Bool {
        family?.hasContent ?? false
    }

    /// Only the items that carry a renderable value, in server order. These are
    /// the readings the page actually paints; valueless items are dropped
    /// (HONEST-ONLY — never a fabricated "—" row).
    public var presentableItems: [RecoveryInsightsDTO.Item] {
        (family?.items ?? []).filter(\.hasValue)
    }

    public func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasSettledOnce = true
        }
        family = await repo.fetch()
    }

    public func refresh() async {
        await load()
    }

    public func clearOnLogout() {
        family = nil
        hasSettledOnce = false
    }
}
