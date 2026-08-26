import Foundation
import Observation

/// Wraps `/api/dashboard/widgets` for iOS — exposes the user's preferred
/// tile order + visibility to `DashboardScreen` and powers the new
/// `DashboardCustomizationScreen`.
///
/// Mirrors `DashboardStore`'s SWR-adoption pattern (see Alpha's reference
/// in `DashboardStore`): cache-first first paint, revalidate online,
/// graceful degradation offline. Optimistic write-through on customisation
/// changes — the UI updates instantly, the PUT runs in the background,
/// failures roll back + surface as `error`.
@MainActor
@Observable
public final class DashboardLayoutStore {
    /// Currently-resolved layout. Pre-load: `.default` so the dashboard has
    /// something to render against on the first frame. Post-first-load:
    /// server-resolved layout (which itself is defaults-merged).
    public private(set) var layout: DashboardWidgetLayout = .default
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    public private(set) var lastUpdatedAt: Date?
    /// True when the visible layout came from the cache and a revalidation
    /// is in flight. UI can suppress optimistic actions during this window.
    public private(set) var isShowingStaleCache: Bool = false

    /// v0.14 b147 — ids the user explicitly pinned this session via the
    /// "Add to Home" long-press. These are EXEMPT from the empty-tile
    /// auto-hide: the operator asked for the tile, so it must render (with a
    /// skeleton / em-dash) even before its per-kind data fan-out resolves.
    /// Without this exemption a freshly pinned, zero-data synth tile is
    /// filtered straight back out by `DashboardEmptyTilePolicy` and never
    /// appears — the exact operator bug. Cleared again on explicit unpin.
    public private(set) var recentlyPinnedIds: Set<String> = []

    /// W-B187 — memoized order/visibility lookup derived purely from
    /// `layout.widgets`. `DashboardScreen.orderedMetrics(_:)` rebuilt TWO
    /// `Dictionary(uniqueKeysWithValues:)` on every body eval (any of the
    /// dashboard's ~11 observed stores churning re-ran the build); these
    /// dictionaries depend ONLY on the layout, so they're cached here and
    /// recomputed lazily the first time the layout changes. Not `@Observable`
    /// state (it's a pure projection of `layout`), so `@ObservationIgnored`
    /// keeps it off the dependency graph — the screen still observes `layout`.
    @ObservationIgnored private var cachedLookup: WidgetOrderLookup?
    @ObservationIgnored private var cachedLookupLayout: DashboardWidgetLayout?

    /// The memoized `(order, effective-visibility)` lookup for the current
    /// `layout`. Recomputes only when `layout` differs from the layout the
    /// cache was built against; otherwise returns the cached value.
    public var widgetOrderLookup: WidgetOrderLookup {
        if let cachedLookup, cachedLookupLayout == layout {
            return cachedLookup
        }
        let lookup = WidgetOrderLookup(widgets: layout.widgets)
        cachedLookup = lookup
        cachedLookupLayout = layout
        return lookup
    }

    private let repo: DashboardRepository
    private let swr: SWRCoordinator?

    /// Legacy v0.4.1 migration flag. Pre-v0.4.1 users had a persisted server
    /// layout where seven kinds (sleep, steps, glucose, totalBodyWater,
    /// boneMass, oxygenSaturation, vo2Max) shipped with `tileVisible: false`.
    /// The v0.4.1 sweep flipped those defaults on. v0.5.3 supersedes this
    /// with `defaultsMigrationKey` (handles both flip + append, see below);
    /// the constant stays for back-compat readers and one-shot test fixtures.
    static let migrationKey = "hl.dashboardLayoutMigratedToV041"

    /// v0.5.3 D-4 migration flag — supersedes `migrationKey`.
    ///
    /// v0.5.2's A5 added seven new MetricKinds (`restingHeartRate`, `hrv`,
    /// `walkingSpeed`, `walkingAsymmetry`, `walkingStepLength`, `bmi`,
    /// `bodyTemperature`) to `DashboardWidgetLayout.default` with
    /// `tileVisible: true`. Operator walkthrough on the v0.5.2 build
    /// confirmed they did NOT surface on real device: existing users have
    /// a server-stored layout that predates those ids, so the new defaults
    /// never reach them.
    ///
    /// This pass does two things in one PUT:
    ///   1. Re-runs the v0.4.1 flip (idempotent — already-flipped rows are
    ///      untouched).
    ///   2. APPENDS any widget id present in `DashboardWidgetLayout.default`
    ///      that is missing from the user's stored layout. The appended
    ///      rows inherit their default `visible` / `tileVisible` flags;
    ///      order continues from the user's max-order + 1 so manual
    ///      reordering survives.
    ///
    /// Crucially the merger does NOT re-show widgets the operator has
    /// manually hidden (`tileVisible: false` on a row the operator pushed)
    /// — only DEFAULT-visible widgets that never reached their layout get
    /// added. Manual hides on already-existing rows are preserved as-is.
    static let defaultsMigrationKey = "hl.dashboardLayoutMigratedToV053HKCompleteness"

    public init(repo: DashboardRepository, swr: SWRCoordinator? = nil) {
        self.repo = repo
        self.swr = swr
    }

    /// Merges `existing` with `DashboardWidgetLayout.default` so the user
    /// surface honours every default-visible widget id, even ones added in
    /// later app versions. Two-step:
    ///
    /// 1. **Flip pass (v0.4.1 carry-over):** a row in `existing` whose
    ///    `tileVisible == false` BUT whose default is `tileVisible == true`
    ///    is flipped to true — **but only for the seven ids the v0.4.1 sweep
    ///    actually targeted** (``v041FlipIds``). Idempotent; already-flipped
    ///    rows pass through.
    ///
    ///    GH #81 — until b249 this restriction lived in the comment and not
    ///    in the code: the pass flipped ANY hidden row whose catalogue
    ///    default was visible. That is indistinguishable from "the user hid
    ///    this on purpose", so hiding e.g. `weight` on the web came back on
    ///    at the next fetch — and, because the migration PUTs its result,
    ///    the hide was overwritten on the server too. The bug only bit where
    ///    ``defaultsMigrationKey`` was unset (fresh install, second device,
    ///    or a device whose earlier migration PUT had failed), which is why
    ///    it looked intermittent.
    ///
    ///    The seven ids are a closed historical set: their DEFAULT changed
    ///    between two app versions, so a `false` on those rows genuinely
    ///    could not have been a user decision at the time. Nothing may be
    ///    added to this list — a future default change needs its own,
    ///    separately keyed migration, not a re-widening of this one.
    /// 2. **Append pass (v0.5.3 D-4):** any widget id in `.default` that's
    ///    missing from `existing.widgets` is appended at the end, with the
    ///    default flags and a continuation order (max(existing.order) + N).
    ///    Operator's manual hides on already-existing rows survive untouched.
    /// **The closed set the v0.4.1 flip pass may touch (GH #81).**
    ///
    /// These seven kinds shipped `tileVisible: false` before v0.4.1 and had
    /// their catalogue default flipped to `true` by that release. A `false`
    /// on one of these rows therefore predates any user choice.
    ///
    /// Every other id is off limits: for those, `tileVisible: false` means a
    /// person hid the tile, on this device or on the web, and the client does
    /// not get to overrule that.
    static let v041FlipIds: Set<String> = [
        DashboardWidgetId.sleep,
        DashboardWidgetId.steps,
        DashboardWidgetId.glucose,
        DashboardWidgetId.totalBodyWater,
        DashboardWidgetId.boneMass,
        DashboardWidgetId.oxygenSaturation,
        DashboardWidgetId.vo2Max
    ]

    static func mergedWithDefaults(_ existing: DashboardWidgetLayout) -> DashboardWidgetLayout {
        let defaults = DashboardWidgetLayout.default.widgets
        let defaultsById = Dictionary(uniqueKeysWithValues: defaults.map { ($0.id, $0) })

        // Step 1 — flip pass on existing rows, restricted to the v0.4.1 set.
        let flipped = existing.widgets.map { row -> DashboardWidgetConfig in
            guard Self.v041FlipIds.contains(row.id) else { return row }
            let defaultVisible = defaultsById[row.id]?.effectiveTileVisible ?? row.effectiveTileVisible
            if row.effectiveTileVisible == false, defaultVisible == true {
                return DashboardWidgetConfig(
                    id: row.id,
                    visible: row.visible,
                    tileVisible: true,
                    order: row.order
                )
            }
            return row
        }

        // Step 2 — append pass for widget ids the user has never seen.
        let existingIds = Set(flipped.map(\.id))
        let missing = defaults.filter { !existingIds.contains($0.id) }
        guard !missing.isEmpty else {
            // v1.27.7 — carry the existing ring selection through so the
            // migration equality check (`merged != loaded`) isn't perturbed by
            // the additive field and a no-op merge stays a no-op.
            return DashboardWidgetLayout(
                version: existing.version,
                widgets: flipped,
                selectedScoreRings: existing.selectedScoreRings,
                heroRingOrder: existing.heroRingOrder,
                // CU-34 — carried through for the same reason as the two ring
                // fields: the migration's `merged != loaded` check must not
                // register a difference just because an additive field was
                // dropped, or every launch would fire a pointless PUT.
                enabledHeroItemKinds: existing.enabledHeroItemKinds
            )
        }
        // Continue ordering from the user's current max so appended tiles
        // land at the tail. Sort the missing rows by their default order so
        // they retain the catalog's relative sequence.
        let baseOrder = (flipped.map(\.order).max() ?? -1) + 1
        let appended = missing
            .sorted { $0.order < $1.order }
            .enumerated()
            .map { offset, row in
                DashboardWidgetConfig(
                    id: row.id,
                    visible: row.visible,
                    tileVisible: row.tileVisible,
                    order: baseOrder + offset
                )
            }
        return DashboardWidgetLayout(
            version: existing.version,
            widgets: flipped + appended,
            selectedScoreRings: existing.selectedScoreRings,
            heroRingOrder: existing.heroRingOrder,
            enabledHeroItemKinds: existing.enabledHeroItemKinds
        )
    }

    /// Back-compat alias retained so external callers (tests, future
    /// audits) can still address the v0.4.1 flip-only behaviour by name.
    /// New code paths should consume `mergedWithDefaults` which also
    /// appends missing widget ids.
    static func mergedWithV041Defaults(_ existing: DashboardWidgetLayout) -> DashboardWidgetLayout {
        mergedWithDefaults(existing)
    }

    /// Run the defaults-merge migration if it hasn't been applied for this
    /// device + user yet. Idempotent — guarded by `defaultsMigrationKey`.
    /// Persists the merged layout via PUT and sets the flag on success.
    /// On failure, the flag stays false so the next `load()` retries.
    private func runDefaultsMigrationIfNeeded(_ loaded: DashboardWidgetLayout) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.defaultsMigrationKey) == false else { return }
        let merged = Self.mergedWithDefaults(loaded)
        guard merged != loaded else {
            // Nothing to do — record success so we don't re-check every load.
            defaults.set(true, forKey: Self.defaultsMigrationKey)
            // Also forward the legacy flag for completeness — a user whose
            // layout already lines up with current defaults has effectively
            // run both passes.
            defaults.set(true, forKey: Self.migrationKey)
            return
        }
        do {
            let saved = try await repo.setWidgetLayout(merged)
            layout = saved
            lastUpdatedAt = Date()
            if let swr {
                await swr.writeThrough(.dashboardWidgetLayout, value: saved)
            }
            defaults.set(true, forKey: Self.defaultsMigrationKey)
            defaults.set(true, forKey: Self.migrationKey)
        } catch {
            // Swallow — migration retries on next load. Don't clobber the
            // user-facing error stream. Log the error shape (type only, no
            // payload) so a persistent migration failure is diagnosable.
            // (audit-v0162 L-E1)
            HLLog.ui.debug(
                "Dashboard layout migration deferred: \(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }

    public func load() async {
        // 14-06 — see `MedicationsStore.load`.
        defer {
            if isLoading {
                StoreEffectDiagnostics.recordRefusal(.loadInterrupted, store: .dashboardLayout)
            }
            isLoading = false
        }
        guard let swr else {
            await loadDirect()
            return
        }
        let repo = repo
        for await state in await swr.observe(
            .dashboardWidgetLayout,
            decoding: DashboardWidgetLayout.self,
            fetch: { try await repo.widgetLayout() }
        ) {
            switch state {
            case .empty:
                isLoading = true
                error = nil
            case let .cached(value, _):
                layout = value
                lastUpdatedAt = Date()
                isShowingStaleCache = true
                isLoading = false
            case let .fresh(value):
                layout = value
                lastUpdatedAt = Date()
                isShowingStaleCache = false
                isLoading = false
                error = nil
                await runDefaultsMigrationIfNeeded(value)
            case let .failed(err, lastKnown):
                if let lastKnown {
                    layout = lastKnown
                    isShowingStaleCache = true
                }
                isLoading = false
                error = err
            }
        }
    }

    private func loadDirect() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let loaded = try await repo.widgetLayout()
            layout = loaded
            lastUpdatedAt = Date()
            isShowingStaleCache = false
            await runDefaultsMigrationIfNeeded(loaded)
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

    /// Optimistic toggle — flips the tile-visibility flag for one widget id
    /// and PUTs the new layout. Rolls back on server error.
    public func toggleTileVisible(forId id: String) async {
        let previous = layout
        let next = layout.togglingTileVisibility(forId: id)
        layout = next
        await persist(next, rollbackTo: previous)
    }

    /// True when the given widget id currently surfaces on the home tile-strip.
    /// Drives the pin/unpin context-menu label. `false` for unknown ids.
    public func isPinned(forId id: String) -> Bool {
        layout.widgets.first(where: { $0.id == id })?.effectiveTileVisible ?? false
    }

    /// v0.14 A — pin/unpin a metric to the home dashboard from a long-press.
    ///
    /// Pinning sets `tileVisible: true` AND moves the row to the tail
    /// (`order = max + 1`) so a freshly pinned tile lands at the bottom of
    /// the strip (the operator's expectation — "added to home" ⇒ "appears
    /// last"). Unpinning just clears `tileVisible`; the row keeps its order
    /// so re-pinning restores the same slot. Optimistic + rolls back on
    /// server error, identical durability to `toggleTileVisible`.
    public func setPinned(forId id: String, pinned: Bool) async {
        let previous = layout
        let next = layout.settingTileVisible(forId: id, visible: pinned, moveToTailWhenShowing: pinned)
        guard next != previous else { return }
        // Track / untrack the explicit-pin exemption BEFORE the optimistic
        // mutation so `orderedMetrics` sees the exemption on the very first
        // re-render the layout change triggers.
        if pinned {
            recentlyPinnedIds.insert(id)
        } else {
            recentlyPinnedIds.remove(id)
        }
        layout = next
        await persist(next, rollbackTo: previous)
    }

    /// Optimistic reorder — applies `newOrderIds` and PUTs.
    public func reorder(_ newOrderIds: [String]) async {
        let previous = layout
        let next = layout.reordering(newOrderIds)
        layout = next
        await persist(next, rollbackTo: previous)
    }

    /// **v1.27.7 — the current hero score-ring selection** (parsed back into the
    /// closed set, defaulted when the layout carries none). Pre-selects the
    /// picker + drives which rings the hero highlights.
    public var selectedScoreRings: [ScoreRingID] {
        layout.resolvedScoreRingSelection
    }

    /// **v1.27.7 — persist a new hero score-ring selection.** The ONLY path that
    /// sends `selectedScoreRings` on the widgets PUT (every other save omits it
    /// → server preserves). Optimistic + rolls back on error, identical
    /// durability to `reorder` / `toggleTileVisible`.
    public func setSelectedScoreRings(_ ids: [ScoreRingID]) async {
        await setScoreRings(selected: ids, heroOrder: nil)
    }

    /// **Parity Build 4 · 4.3/4.8 — true when the user has actually chosen a
    /// ring selection**, as opposed to the server handing back its default.
    ///
    /// Load-bearing for the Insights ring cards: `selectedScoreRings` defaults
    /// to `[MED_COMPLIANCE]`, which has no Insights card at all. Letting that
    /// default drive the Insights grid would blank out Daily condition / Sleep /
    /// Recovery for every user who never opened the picker — a silent
    /// regression dressed up as a feature. So the selection only governs the
    /// Insights cards once it is EXPLICIT.
    public var hasExplicitScoreRingSelection: Bool {
        layout.selectedScoreRings?.isEmpty == false
    }

    /// **Parity Build 4 · 4.8 — the hero ring order** (anchor + selection),
    /// reconciled against the current selection. Pre-fills the order editor.
    public var heroRingOrder: [HeroRingID] {
        layout.resolvedHeroRingOrder
    }

    /// **Parity Build 4 · 4.8 — persist selection + hero order in ONE PUT.**
    ///
    /// The server preserves either field when absent, so sending them together
    /// is safe and keeps the two from ever disagreeing mid-edit. Optimistic +
    /// rolls back on error, identical durability to `reorder`.
    public func setScoreRings(selected: [ScoreRingID], heroOrder: [HeroRingID]?) async {
        let previous = layout
        let next = layout.settingScoreRings(selected: selected, heroOrder: heroOrder)
        layout = next
        await persist(next, rollbackTo: previous)
    }

    // MARK: - CU-34 — Today hero items

    /// **CU-34 — the item kinds currently allowed in the Today hero rail.**
    /// Pre-selects the picker. Resolves a server that predates the field to the
    /// full catalogue (nothing is being filtered), and an explicit `[]` to an
    /// empty list (the user switched the rail off).
    public var enabledHeroItemKinds: [HeroItemKind] {
        layout.resolvedEnabledHeroItemKinds
    }

    /// **CU-34 — true when the layout carries an explicit choice** rather than
    /// the "no such field" of an older server.
    public var hasExplicitHeroItemKindSelection: Bool {
        layout.hasExplicitHeroItemKindSelection
    }

    /// **CU-34 — persist which kinds may appear in the Today hero rail.**
    ///
    /// The ONLY path that sends `enabledHeroItemKinds` on the widgets PUT
    /// (every other save omits it → the server preserves the stored set).
    /// Passing an EMPTY array is a real instruction — it sends `[]`, i.e. "no
    /// kind may appear" — and is deliberately not short-circuited into a
    /// no-op. Optimistic + rolls back on error, and the write rides the same
    /// `baseUpdatedAt`-guarded repository path as every other layout save
    /// (CU-20), so a stale write is rejected rather than clobbering another
    /// session.
    public func setEnabledHeroItemKinds(_ kinds: [HeroItemKind]) async {
        let previous = layout
        let next = layout.settingEnabledHeroItemKinds(kinds)
        layout = next
        await persist(next, rollbackTo: previous)
    }

    /// **Parity 1.2 — resets exactly the way the web does: `DELETE`.**
    ///
    /// The old implementation PUT the materialised `DashboardWidgetLayout
    /// .default`. That looked equivalent and was not: the local default is
    /// missing twelve ids the server catalogue knows, and the server
    /// re-appended each of them at `visible:false, tileVisible:false` instead
    /// of their web default visibility — so a reset FROM THE PHONE left the
    /// WEB dashboard with a dozen force-hidden tiles, silently. The PUT also
    /// omitted the ring fields (the server preserves what a payload omits —
    /// see AUDIT-REGISTER 1.5, which is why omission is safe on every OTHER
    /// save), so an iOS "reset" pointedly did NOT reset the hero rings that a
    /// web reset does.
    ///
    /// `DELETE` nulls the column; the layout then re-resolves from the server
    /// default on the next read — rings included. No optimistic paint here:
    /// the correct post-reset layout is the SERVER's resolved one, which we
    /// cannot construct locally (that is the whole bug), so the cache is
    /// dropped and the layout re-read.
    public func resetToDefaults() async {
        let previous = layout
        do {
            try await repo.resetWidgetLayout()
            if let swr {
                await swr.invalidate([.dashboardWidgetLayout])
            }
            await load()
        } catch let err as HLError {
            layout = previous
            error = err
        } catch {
            layout = previous
            self.error = .unknown(String(describing: error))
        }
    }

    private func persist(_ layoutToSave: DashboardWidgetLayout, rollbackTo previous: DashboardWidgetLayout) async {
        do {
            let saved = try await repo.setWidgetLayout(layoutToSave)
            layout = saved
            lastUpdatedAt = Date()
            isShowingStaleCache = false
            error = nil
            // Write-through cache so the next observer paints fresh.
            if let swr {
                await swr.writeThrough(.dashboardWidgetLayout, value: saved)
            }
        } catch let err as HLError {
            layout = previous
            reconcilePinExemptionsWithLayout()
            error = err
        } catch {
            layout = previous
            reconcilePinExemptionsWithLayout()
            self.error = .unknown(String(describing: error))
        }
    }

    /// After a rollback the optimistic pin no longer holds — drop any
    /// exemption whose id is not actually `tileVisible` in the restored
    /// layout, so we don't keep force-showing a tile the server rejected.
    private func reconcilePinExemptionsWithLayout() {
        recentlyPinnedIds = recentlyPinnedIds.filter { id in
            layout.widgets.first(where: { $0.id == id })?.effectiveTileVisible == true
        }
    }

    public func clearOnLogout() {
        layout = .default
        error = nil
        lastUpdatedAt = nil
        isShowingStaleCache = false
    }
}
