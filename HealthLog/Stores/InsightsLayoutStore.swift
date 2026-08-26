import Foundation
import Observation

/// v0.8.0 W10 — server-first Insights tile layout (order + visibility).
///
/// Replaces the prior iOS-local `@AppStorage` persistence
/// (`InsightsTileCatalogue.tileOrderStorageKey` / `enabledTilesStorageKey`)
/// with the server-backed `/api/insights/layout` endpoint so the operator's
/// Insights layout syncs across devices — closing the desync gap the v0.8.0
/// UX/QoL audit flagged.
///
/// **Instant paint:** the resolved layout is mirrored into `UserDefaults`
/// (`layoutCacheKey`) on every successful load/write so a cold launch paints
/// the operator's real order on the first frame, before the GET round-trip
/// lands. This is a UI-pref cache (no PII), consistent with the PROJECT_GUIDE.md
/// rule that only UI-prefs live in `UserDefaults`.
///
/// **Optimistic write-through:** reorder / visibility-toggle / reset update
/// the in-memory `layout` instantly, then PUT/DELETE in the background.
/// Failures roll back + surface as `error`; on a retriable failure the repo
/// has already enqueued the write to the Outbox for replay.
@MainActor
@Observable
public final class InsightsLayoutStore {
    /// Currently-resolved layout. Pre-load: the `UserDefaults` cache (or
    /// `.default` on a fresh install) so Insights renders the operator's
    /// real order on the first frame. Post-load: the server-resolved layout.
    public private(set) var layout: InsightsLayout
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    public private(set) var lastUpdatedAt: Date?

    private let repo: InsightsLayoutRepository
    private let defaults: UserDefaults

    /// `UserDefaults` key the instant-paint cache lives under. Never rename —
    /// the cold-launch paint would silently fall back to `.default`.
    static let layoutCacheKey = "hl.insights.layoutCache.v1"

    /// v0.8.1 WB — `UserDefaults` key for the intra-mood-pair order
    /// (`MOOD_SCORE` ↔ `MOOD_STABILITY` left/right). Both mood halves share the
    /// single server `stimmung` slug, so the server layout can't express which
    /// half is first — this iOS-local UI-pref does (PROJECT_GUIDE.md allows UI-prefs
    /// in `UserDefaults`). A server follow-up (per-half slugs) would let this
    /// sync cross-device; until then the pair's intra-order is device-local.
    static let moodHalfOrderKey = "hl.insights.moodHalfOrder.v1"

    /// Catalogue types whose mood halves the operator dragged into; default
    /// is score-then-stability. `nil`/empty → the default order.
    public private(set) var moodHalfOrder: [String]

    public init(repo: InsightsLayoutRepository, defaults: UserDefaults = .standard) {
        self.repo = repo
        self.defaults = defaults
        layout = Self.readCache(from: defaults) ?? .default
        moodHalfOrder = (defaults.array(forKey: Self.moodHalfOrderKey) as? [String]) ?? []
    }

    /// v0.8.1 WB — persist the intra-mood-pair left/right order (iOS-local).
    /// Filtered to the two known mood half types so a stray id can't poison it.
    public func setMoodHalfOrder(_ order: [String]) {
        let allowed: Set = ["MOOD_SCORE", "MOOD_STABILITY"]
        let cleaned = order.filter { allowed.contains($0) }
        moodHalfOrder = cleaned
        defaults.set(cleaned, forKey: Self.moodHalfOrderKey)
    }

    /// GET on app start (and tab-revisit). Hydrates `layout` from the server,
    /// writes through the instant-paint cache. Stale cache stays on screen on
    /// failure (the repo serves its own stale snapshot when present).
    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let loaded = try await repo.fetch()
            layout = loaded
            lastUpdatedAt = Date()
            writeCache(loaded)
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func refresh() async {
        await load()
    }

    // MARK: - Mutations

    /// Optimistic reorder — applies `newOrderIds` and PUTs. Rolls back on error.
    public func reorder(_ newOrderIds: [String]) async {
        let previous = layout
        let next = layout.reordering(newOrderIds)
        layout = next
        await persist(next, rollbackTo: previous)
    }

    /// Optimistic visibility toggle for one tile id and PUT. Rolls back on error.
    public func toggleVisible(forId id: String) async {
        let previous = layout
        let next = layout.togglingVisibility(forId: id)
        layout = next
        await persist(next, rollbackTo: previous)
    }

    // MARK: - Sections (parity Build 4 · 4.5)

    /// The overview sections in render order, defaults-merged. The Insights
    /// overview composes itself from this; the customisation screen edits it.
    public var sections: [InsightsLayoutSection] {
        layout.resolvedSections
    }

    /// Optimistic section reorder — applies `newOrderIds` and PUTs. Rolls back
    /// on error. Deliberately the twin of ``reorder(_:)`` for tiles.
    public func reorderSections(_ newOrderIds: [String]) async {
        let previous = layout
        let next = layout.reorderingSections(newOrderIds)
        layout = next
        await persist(next, rollbackTo: previous)
    }

    /// Optimistic section visibility toggle and PUT. Rolls back on error.
    public func toggleSectionVisible(forId id: String) async {
        let previous = layout
        let next = layout.togglingSectionVisibility(forId: id)
        guard next != previous else { return }
        layout = next
        await persist(next, rollbackTo: previous)
    }

    /// Resets to server defaults via DELETE. Optimistic to `.default`; rolls
    /// back on error (the server echo replaces the optimistic guess on success).
    public func resetToDefaults() async {
        let previous = layout
        layout = .default
        writeCache(.default)
        do {
            let echoed = try await repo.reset()
            layout = echoed
            lastUpdatedAt = Date()
            error = nil
            writeCache(echoed)
        } catch let err as HLError {
            layout = previous
            writeCache(previous)
            error = err
        } catch {
            layout = previous
            writeCache(previous)
            self.error = .unknown(String(describing: error))
        }
    }

    private func persist(_ layoutToSave: InsightsLayout, rollbackTo previous: InsightsLayout) async {
        writeCache(layoutToSave)
        do {
            let saved = try await repo.update(layoutToSave)
            layout = saved
            lastUpdatedAt = Date()
            error = nil
            writeCache(saved)
        } catch let err as HLError {
            layout = previous
            writeCache(previous)
            error = err
        } catch {
            layout = previous
            writeCache(previous)
            self.error = .unknown(String(describing: error))
        }
    }

    public func clearOnLogout() {
        layout = .default
        error = nil
        lastUpdatedAt = nil
        moodHalfOrder = []
        defaults.removeObject(forKey: Self.layoutCacheKey)
        defaults.removeObject(forKey: Self.moodHalfOrderKey)
    }

    // MARK: - Instant-paint cache

    private func writeCache(_ value: InsightsLayout) {
        guard let data = try? JSONEncoder.hlDefault.encode(value) else { return }
        defaults.set(data, forKey: Self.layoutCacheKey)
    }

    private static func readCache(from defaults: UserDefaults) -> InsightsLayout? {
        guard let data = defaults.data(forKey: layoutCacheKey),
              let decoded = try? JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data) else
        {
            return nil
        }
        return decoded.reconciled()
    }
}
