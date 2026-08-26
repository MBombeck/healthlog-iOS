import Foundation
import Observation

/// `@Observable` store backing the Daylio-style mood tagging picker. Owns the
/// `GET /api/mood/tags` catalog (Category → Tag tree) behind a daily-SWR
/// ``MoodTagCatalogRepository``. The picker reads ``catalog`` synchronously
/// during `body`; ``load()`` warms it (idempotent — a second call inside the
/// repo's TTL is a no-op fetch).
///
/// **Fail-soft.** The repository never throws — it degrades to the last good
/// snapshot, then the bundled fallback — so ``catalog`` is always renderable.
/// The store therefore carries no `error` surface: an empty grid is the only
/// failure worth guarding and the repo precludes it.
///
/// **Why `@MainActor`?** The picker reads `catalog` during view-body
/// evaluation; main-actor isolation keeps those reads cost-free.
@MainActor
@Observable
public final class MoodTagCatalogStore {
    /// Current best catalog. Seeded with the bundled fallback so the picker
    /// renders instantly on first present, then upgraded by ``load()``.
    public private(set) var catalog: MoodTagCatalog = MoodTagCatalogRepository.bundledFallback

    /// True once the first server-backed (or fallback) load has resolved. The
    /// picker doesn't spin on this — it's a debug affordance.
    public private(set) var didLoad = false

    private let repo: MoodTagCatalogRepository

    public init(repo: MoodTagCatalogRepository) {
        self.repo = repo
    }

    /// Warm the catalog. Idempotent — inside the repo's TTL this is a no-op
    /// fetch that returns the cached snapshot. Safe to call from `.task` on
    /// every picker present.
    public func load() async {
        catalog = await repo.catalog()
        didLoad = true
    }

    /// Resolve a stored tag-key to its localized label for read-back chips.
    /// Returns `nil` for a key the catalog doesn't know (a legacy free-text
    /// tag), so the caller can render it as a plain text chip instead.
    public func label(forTagKey key: String) -> String? {
        catalog.label(forTagKey: key)
    }

    /// True iff `key` is a known structured-tag key — lets the read-back
    /// surface split structured chips (icon + catalog label) from legacy
    /// free-text tags.
    public func isStructuredTag(_ key: String) -> Bool {
        catalog.containsTag(key)
    }

    /// v0.14.8 W3 (AUDIT-SECURITY-B175 M-1) — drop the per-user catalog back
    /// to the bundled fallback on logout. The catalog can contain the previous
    /// user's CUSTOM tags (health-revealing labels) which the container-
    /// lifetime store would otherwise paint into the next user's picker.
    public func clearOnLogout() {
        catalog = MoodTagCatalogRepository.bundledFallback
        didLoad = false
    }
}
