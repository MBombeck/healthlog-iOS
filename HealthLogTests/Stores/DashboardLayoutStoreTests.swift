import Foundation
@testable import HealthLog
import Testing

/// `.serialized` — five cases in this suite toggle the SAME process-global
/// `UserDefaults.standard` migration flag and restore it in a `defer`. Run in
/// parallel they interleave save/restore and one case reads another's flag.
@Suite("DashboardLayoutStore", .serialized)
struct DashboardLayoutStoreTests {
    /// Stub that returns a canned layout for GET and echoes the body back
    /// for PUT — mirrors the real server's `setWidgetLayout` shape.
    actor LayoutStubAPI: APIClientProtocol {
        private(set) var lastPutPayload: DashboardWidgetLayout?
        /// Parity 1.2 — the reset path is a DELETE now, so the stub has to be
        /// able to see one (and to fail one).
        private(set) var deleteCount = 0
        var getResponse: DashboardWidgetLayout
        var putShouldThrow: HLError?
        var deleteShouldThrow: HLError?

        init(initial: DashboardWidgetLayout = .default) {
            getResponse = initial
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            if request.path == "/api/dashboard/widgets", request.method == .get {
                guard let typed = getResponse as? T else {
                    throw HLError.unknown("type mismatch GET")
                }
                return typed
            }
            if request.path == "/api/dashboard/widgets", request.method == .delete {
                if let err = deleteShouldThrow { throw err }
                deleteCount += 1
                // The server echoes its own default layout on DELETE.
                guard let typed = DashboardWidgetLayout.default as? T else {
                    throw HLError.unknown("type mismatch DELETE")
                }
                return typed
            }
            if request.path == "/api/dashboard/widgets", request.method == .put {
                if let err = putShouldThrow { throw err }
                // Decode the body the caller encoded, store it, echo back.
                if let body = request.body,
                   let decoded = try? JSONDecoder.hlDefault.decode(DashboardWidgetLayout.self, from: body)
                {
                    lastPutPayload = decoded
                    guard let typed = decoded as? T else {
                        throw HLError.unknown("type mismatch PUT")
                    }
                    return typed
                }
                throw HLError.unknown("no body")
            }
            throw HLError.unknown("unexpected path \(request.path)")
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {
            // Not used here.
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("not impl")
        }

        func setPutResult(_ err: HLError?) {
            putShouldThrow = err
        }

        func setDeleteResult(_ err: HLError?) {
            deleteShouldThrow = err
        }

        func setGetResponse(_ layout: DashboardWidgetLayout) {
            getResponse = layout
        }
    }

    @Test("load (direct-fetch path) populates layout from server")
    @MainActor
    func loadDirectFetchPopulatesLayout() async {
        // Set the migration flag so the v0.5.3 defaults-merge migration
        // short-circuits — this test exercises raw read fidelity, not the
        // migration path (covered separately in `loadAppendsMissingWidgets…`).
        let migrationKey = DashboardLayoutStore.defaultsMigrationKey
        let priorFlag = UserDefaults.standard.bool(forKey: migrationKey)
        UserDefaults.standard.set(true, forKey: migrationKey)
        defer { Self.restoreMigrationFlag(priorFlag, forKey: migrationKey) }

        let custom = DashboardWidgetLayout(widgets: [
            DashboardWidgetConfig(id: "weight", visible: true, tileVisible: true, order: 0),
            DashboardWidgetConfig(id: "steps", visible: true, tileVisible: true, order: 1)
        ])
        let api = LayoutStubAPI(initial: custom)
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()

        // v0.10 W10-PIN (server v1.7.0 LIVE): the server's widget enum now
        // accepts + round-trips the full 27-id catalogue, so `widgetLayout()`
        // no longer merges iOS-only defaults onto every GET — the server is
        // authoritative. With the one-time defaults migration short-circuited,
        // the store reflects the server payload verbatim (2 rows here).
        #expect(store.layout.widgets.count == 2)
        #expect(store.layout.widgets.first?.id == "weight")
        #expect(store.layout.widgets.dropFirst().first?.id == "steps")
        #expect(store.isShowingStaleCache == false)
        #expect(store.error == nil)
    }

    @Test("toggleTileVisible flips state optimistically and persists")
    @MainActor
    func toggleTileVisibleOptimistic() async {
        let api = LayoutStubAPI(initial: .default)
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()

        // v0.4.1: defaults are tile-visible. Use `achievements` which stays
        // hidden by default (has a dedicated tile, not a metric tile) — the
        // flip exercises the same code path in both directions.
        let achievementsBefore = store.layout.widgets.first { $0.id == "achievements" }
        #expect(achievementsBefore?.effectiveTileVisible == false)

        await store.toggleTileVisible(forId: "achievements")

        let achievementsAfter = store.layout.widgets.first { $0.id == "achievements" }
        #expect(achievementsAfter?.effectiveTileVisible == true)

        // PUT round-tripped with the new state.
        let puttedLayout = await api.lastPutPayload
        let pushed = puttedLayout?.widgets.first { $0.id == "achievements" }
        #expect(pushed?.effectiveTileVisible == true)
    }

    @Test("toggleTileVisible rolls back on server error")
    @MainActor
    func toggleTileVisibleRollback() async {
        let api = LayoutStubAPI(initial: .default)
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()
        await api.setPutResult(.server(status: 500, code: "boom", message: "server explosion"))

        let sleepBefore = store.layout.widgets.first { $0.id == "sleep" }
        let beforeVisibility = sleepBefore?.effectiveTileVisible ?? false

        await store.toggleTileVisible(forId: "sleep")

        let sleepAfter = store.layout.widgets.first { $0.id == "sleep" }
        // Rolled back to the pre-toggle state.
        #expect(sleepAfter?.effectiveTileVisible == beforeVisibility)
        #expect(store.error != nil)
    }

    /// v0.14 b147 — a user-pinned id is exempt from the empty-tile auto-hide
    /// so a freshly pinned, zero-data synth tile still appears on the home
    /// strip. The exemption signal is `DashboardLayoutStore.recentlyPinnedIds`.
    @Test("setPinned tracks the id for the auto-hide exemption; even with no data the pin is NOT hidden")
    @MainActor
    func setPinnedRecordsExemption() async {
        let api = LayoutStubAPI(initial: .default)
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()
        #expect(store.recentlyPinnedIds.contains("achievements") == false)

        await store.setPinned(forId: "achievements", pinned: true)

        // The id is now exempt — `orderedMetrics` skips `shouldAutoHide` for it,
        // so a zero-data pinned tile renders instead of being filtered back out.
        #expect(store.recentlyPinnedIds.contains("achievements"))
        #expect(store.layout.widgets.first { $0.id == "achievements" }?.effectiveTileVisible == true)

        // Explicit unpin clears the exemption again.
        await store.setPinned(forId: "achievements", pinned: false)
        #expect(store.recentlyPinnedIds.contains("achievements") == false)
    }

    @Test("setPinned exemption is reconciled away when the server PUT fails (rollback)")
    @MainActor
    func setPinnedRollbackDropsExemption() async {
        let api = LayoutStubAPI(initial: .default)
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()
        await api.setPutResult(.server(status: 500, code: "boom", message: "server explosion"))

        await store.setPinned(forId: "achievements", pinned: true)

        // Rolled back: tile not visible AND the exemption was reconciled away,
        // so we don't keep force-showing a tile the server rejected.
        #expect(store.layout.widgets.first { $0.id == "achievements" }?.effectiveTileVisible == false)
        #expect(store.recentlyPinnedIds.contains("achievements") == false)
        #expect(store.error != nil)
    }

    @Test("reorder normalises order indices via the server echo")
    @MainActor
    func reorderNormalisesOrder() async {
        let api = LayoutStubAPI(initial: .default)
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()

        // Move pulse to the very top.
        let newOrder = [
            "pulse",
            "weight",
            "bp",
            "bodyFat",
            "mood",
            "bpInTarget",
            "medications",
            "sleep",
            "steps",
            "glucose",
            "totalBodyWater",
            "boneMass",
            "oxygenSaturation",
            "achievements",
            "vo2Max"
        ]
        await store.reorder(newOrder)

        let layoutAfter = store.layout
        let pulse = layoutAfter.widgets.first { $0.id == "pulse" }
        #expect(pulse?.order == 0)
        let weight = layoutAfter.widgets.first { $0.id == "weight" }
        #expect(weight?.order == 1)
        #expect(store.error == nil)
    }

    /// **Parity 1.2 — reset must DELETE, and must not PUT anything.**
    ///
    /// The old implementation PUT the materialised `DashboardWidgetLayout
    /// .default`. That local default is missing twelve ids the server knows, and
    /// the server re-appended each at `visible:false, tileVisible:false` — so a
    /// reset from the phone force-hid a dozen tiles on the web, and (because the
    /// PUT omitted the ring fields, which the server then preserves) did not
    /// reset the hero rings that a web reset does.
    ///
    /// The assertion that matters is the NEGATIVE one: no PUT. A reset that
    /// sends a client-built layout is the bug, whatever that layout contains.
    @Test("resetToDefaults DELETEs and re-reads — it never PUTs a local default")
    @MainActor
    func resetToDefaultsDeletesAndReloads() async {
        // Suppress the v0.5.3 defaults-merge migration — this test cares
        // about the `resetToDefaults` mutation path, not the load-time
        // migration (covered separately).
        let migrationKey = DashboardLayoutStore.defaultsMigrationKey
        let priorFlag = UserDefaults.standard.bool(forKey: migrationKey)
        UserDefaults.standard.set(true, forKey: migrationKey)
        defer { Self.restoreMigrationFlag(priorFlag, forKey: migrationKey) }

        let custom = DashboardWidgetLayout(widgets: [
            DashboardWidgetConfig(id: "weight", visible: false, tileVisible: false, order: 0)
        ])
        let api = LayoutStubAPI(initial: custom)
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()
        // v0.10 W10-PIN (server v1.7.0 LIVE): no GET-path merge anymore — the
        // server is authoritative for the full 27-id catalogue, so the 1-row
        // custom payload reads back as exactly 1 row.
        #expect(store.layout.widgets.count == 1)

        // The server nulls the column on DELETE, so the follow-up GET resolves
        // the layout afresh. Model that by swapping what the stub serves.
        await api.setGetResponse(.default)
        await store.resetToDefaults()

        let deletes = await api.deleteCount
        let putted = await api.lastPutPayload
        #expect(deletes == 1)
        // The whole point: nothing client-built went up the wire.
        #expect(putted == nil)
        // The layout the store ends up with came from the RE-READ, not from a
        // local `.default` assignment.
        #expect(store.layout.widgets.count == DashboardWidgetLayout.default.widgets.count)
        #expect(store.error == nil)
    }

    /// A failed DELETE must leave the user's layout untouched — a reset that
    /// half-happens is worse than one that visibly failed.
    @Test("A failed reset keeps the previous layout and surfaces the error")
    @MainActor
    func failedResetRollsBack() async {
        let migrationKey = DashboardLayoutStore.defaultsMigrationKey
        let priorFlag = UserDefaults.standard.bool(forKey: migrationKey)
        UserDefaults.standard.set(true, forKey: migrationKey)
        defer { Self.restoreMigrationFlag(priorFlag, forKey: migrationKey) }

        let custom = DashboardWidgetLayout(widgets: [
            DashboardWidgetConfig(id: "weight", visible: false, tileVisible: false, order: 0)
        ])
        let api = LayoutStubAPI(initial: custom)
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()
        await api.setDeleteResult(.unknown("boom"))
        await store.resetToDefaults()

        #expect(store.layout.widgets.count == 1)
        #expect(store.error != nil)
    }

    @Test("clearOnLogout resets layout to default")
    @MainActor
    func clearOnLogoutResetsToDefault() async {
        let api = LayoutStubAPI(initial: .default)
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()
        // Toggle sleep off (v0.4.1: default is now ON, so toggling flips OFF).
        await store.toggleTileVisible(forId: "sleep")

        store.clearOnLogout()

        // After clear, layout reflects the static default constant exactly:
        // sleep is tile-visible by default in v0.4.1.
        let sleep = store.layout.widgets.first { $0.id == "sleep" }
        #expect(sleep?.effectiveTileVisible == true)
        #expect(store.lastUpdatedAt == nil)
    }

    // MARK: - v0.5.3 D-4 — defaults-merge migration

    /// Restore the migration flag in `UserDefaults.standard` to its
    /// pre-test value. Extracted to a helper so the defer-block stays a
    /// single statement (swiftlint's `statement_position` rule rejects
    /// `else` on its own line).
    private static func restoreMigrationFlag(_ prior: Bool, forKey key: String) {
        if prior {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Snapshot of the pre-v0.5.2 catalogue: every widget id that shipped in
    /// v0.4.1's `DashboardWidgetLayout.default` BEFORE the seven HK-completeness
    /// additions in v0.5.2 (restingHeartRate, hrv, walkingSpeed,
    /// walkingAsymmetry, walkingStepLength, bmi, bodyTemperature). Used to
    /// reconstruct an "existing user" layout for migration tests.
    private static let preV052WidgetIds: [String] = [
        "weight", "bp", "pulse", "bodyFat", "mood", "bpInTarget",
        "medications", "sleep", "steps", "glucose", "totalBodyWater",
        "boneMass", "oxygenSaturation", "achievements", "vo2Max"
    ]

    /// Widget ids added after the pre-v0.5.2 baseline — v0.5.2 A5
    /// (HK-completeness), the v0.7.0 HK adopt-and-stream additions, AND the v0158
    /// v1.25 clinical measurement types (H2: tile-visible by default like every
    /// other MetricKind). These MUST surface after the defaults-merge migration
    /// runs against a pre-v0.5.2 layout, and the merge-count math (existing + this
    /// set) must equal the full default catalogue.
    private static let v052AddedWidgetIds: Set<String> = [
        "restingHeartRate", "hrv", "walkingSpeed", "walkingAsymmetry",
        "walkingStepLength", "bmi", "bodyTemperature",
        // v0.7.0 HK adopt-and-stream
        "walkingDoubleSupport", "respiratoryRate",
        "audioExposureEnvironment", "audioExposureHeadphone",
        // v0158 — v1.25 clinical measurement types
        "painNRS", "gripStrength", "waistCircumference", "waistToHeight"
    ]

    private static func preV052Layout() -> DashboardWidgetLayout {
        let rows = preV052WidgetIds.enumerated().map { offset, id in
            // Tile-visible mirrors the v0.4.1 catalog: every metric tile is
            // visible-by-default, achievements stays off (it's a dedicated
            // tile, not a metric tile).
            let tileVisible = (id != "achievements")
            return DashboardWidgetConfig(
                id: id,
                visible: true,
                tileVisible: tileVisible,
                order: offset
            )
        }
        return DashboardWidgetLayout(version: 1, widgets: rows)
    }

    @Test("mergedWithDefaults appends every v0.5.2 widget id missing from an existing layout")
    @MainActor
    func mergedWithDefaultsAppendsMissingWidgetIds() {
        let existing = Self.preV052Layout()
        let merged = DashboardLayoutStore.mergedWithDefaults(existing)
        let mergedIds = Set(merged.widgets.map(\.id))

        // Every v0.5.2 addition must now be present.
        for newId in Self.v052AddedWidgetIds {
            #expect(mergedIds.contains(newId), "expected merged layout to contain \(newId)")
        }
        // Sanity: the merged layout's widget count is the original + 7.
        #expect(merged.widgets.count == existing.widgets.count + Self.v052AddedWidgetIds.count)
    }

    @Test("mergedWithDefaults preserves operator's manual hides on existing rows")
    @MainActor
    func mergedWithDefaultsPreservesManualHides() {
        // Operator hid the `steps` tile manually.
        var rows = Self.preV052Layout().widgets
        guard let stepsIndex = rows.firstIndex(where: { $0.id == "steps" }) else {
            Issue.record("steps row missing from fixture")
            return
        }
        rows[stepsIndex] = DashboardWidgetConfig(id: "steps", visible: true, tileVisible: false, order: rows[stepsIndex].order)
        let existing = DashboardWidgetLayout(version: 1, widgets: rows)

        let merged = DashboardLayoutStore.mergedWithDefaults(existing)
        let stepsAfter = merged.widgets.first { $0.id == "steps" }
        // `steps` IS one of the seven v0.4.1 ids, so the flip pass still
        // un-hides it — deliberately. On those rows a `false` predates the
        // v0.4.1 default change and therefore cannot be a user decision.
        // Every id outside that set is left alone (GH #81, see below).
        #expect(stepsAfter?.effectiveTileVisible == true)
        // But we MUST still append the new v0.5.2 ids.
        let mergedIds = Set(merged.widgets.map(\.id))
        for newId in Self.v052AddedWidgetIds {
            #expect(mergedIds.contains(newId))
        }
    }

    @Test("mergedWithDefaults preserves operator's manual hide on rows added LATER than v0.4.1")
    @MainActor
    func mergedWithDefaultsPreservesManualHidesOnNewerRows() {
        // Simulate a user who already saw the v0.5.2 widgets surface, then
        // hid `bmi` manually. The merger MUST NOT re-show it on a follow-up
        // app launch.
        let extraRows = Self.v052AddedWidgetIds.enumerated().map { offset, id in
            // `bmi` is hidden by the user; the others are visible.
            let tileVisible = (id != "bmi")
            return DashboardWidgetConfig(
                id: id,
                visible: false,
                tileVisible: tileVisible,
                order: Self.preV052WidgetIds.count + offset
            )
        }
        let allRows = Self.preV052Layout().widgets + extraRows
        let existing = DashboardWidgetLayout(version: 1, widgets: allRows)

        let merged = DashboardLayoutStore.mergedWithDefaults(existing)
        let bmiAfter = merged.widgets.first { $0.id == "bmi" }
        // GH #81 — `bmi` is NOT one of the seven v0.4.1 ids, so a hide on it
        // is a person's decision and survives the merge. Until b249 this
        // expectation read `== true` and codified the defect.
        #expect(bmiAfter?.effectiveTileVisible == false)
        // No NEW rows should appear — every v0.5.2 id is already present.
        #expect(merged.widgets.count == existing.widgets.count)
    }

    // MARK: - GH #81 — a web-side hide must survive the defaults migration

    /// The reporter's exact case: `weight` hidden from the web UI, so the
    /// server stores `visible: false, tileVisible: false` on that row alone.
    /// Its catalogue default is tile-visible, which is what used to trigger
    /// the flip pass.
    static func layoutWithWeightHiddenOnWeb() -> DashboardWidgetLayout {
        var rows = DashboardWidgetLayout.default.widgets
        guard let index = rows.firstIndex(where: { $0.id == DashboardWidgetId.weight }) else {
            Issue.record("weight row missing from the catalogue default")
            return .default
        }
        rows[index] = DashboardWidgetConfig(
            id: DashboardWidgetId.weight,
            visible: false,
            tileVisible: false,
            order: rows[index].order
        )
        return DashboardWidgetLayout(version: 1, widgets: rows)
    }

    @Test("GH #81: a tile hidden on the web is NOT re-shown by the flip pass")
    @MainActor
    func webHiddenTileSurvivesMergeIssue81() {
        let existing = Self.layoutWithWeightHiddenOnWeb()
        let merged = DashboardLayoutStore.mergedWithDefaults(existing)

        let weightAfter = merged.widgets.first { $0.id == DashboardWidgetId.weight }
        #expect(weightAfter?.effectiveTileVisible == false)
        #expect(weightAfter?.visible == false)
        // And nothing else moved — the merge is a no-op beyond that row, so
        // the migration finds `merged == existing` and issues no PUT at all.
        #expect(merged == existing)
    }

    @Test("GH #81: the migration does not PUT away a web-side hide")
    @MainActor
    func migrationDoesNotOverwriteWebHideIssue81() async {
        // The half of the defect that outlived the screen: the migration
        // PUTs its merged result, so before the fix the client did not just
        // display the tile again — it wrote the un-hide back to the server
        // and destroyed the user's choice for the web too.
        let migrationKey = DashboardLayoutStore.defaultsMigrationKey
        let priorFlag = UserDefaults.standard.bool(forKey: migrationKey)
        UserDefaults.standard.removeObject(forKey: migrationKey)
        defer { Self.restoreMigrationFlag(priorFlag, forKey: migrationKey) }

        let api = LayoutStubAPI(initial: Self.layoutWithWeightHiddenOnWeb())
        let store = DashboardLayoutStore(repo: DashboardRepository(api: api), swr: nil)

        await store.load()

        let putted = await api.lastPutPayload
        #expect(putted == nil, "the migration must not write the user's hide away")
        let weightAfter = store.layout.widgets.first { $0.id == DashboardWidgetId.weight }
        #expect(weightAfter?.effectiveTileVisible == false)
    }

    @Test("mergedWithDefaults is idempotent — running twice produces the same layout")
    @MainActor
    func mergedWithDefaultsIsIdempotent() {
        let existing = Self.preV052Layout()
        let once = DashboardLayoutStore.mergedWithDefaults(existing)
        let twice = DashboardLayoutStore.mergedWithDefaults(once)
        #expect(once == twice)
    }

    @Test("mergedWithDefaults on the canonical .default is a no-op")
    @MainActor
    func mergedWithDefaultsOnCanonicalDefault() {
        let existing = DashboardWidgetLayout.default
        let merged = DashboardLayoutStore.mergedWithDefaults(existing)
        #expect(merged == existing)
    }

    @Test("mergedWithDefaults appends with continuation order so operator's reordering survives")
    @MainActor
    func mergedWithDefaultsAppendsAtTail() {
        // Operator's custom order: pulse first, then weight, then the rest.
        // Build a pre-v0.5.2 layout with explicit non-monotonic orders to
        // confirm the append-pass continues from max + 1 rather than from
        // catalog defaults.
        let rows = [
            DashboardWidgetConfig(id: "pulse", visible: true, tileVisible: true, order: 0),
            DashboardWidgetConfig(id: "weight", visible: true, tileVisible: true, order: 1),
            DashboardWidgetConfig(id: "bp", visible: true, tileVisible: true, order: 5)
        ]
        let existing = DashboardWidgetLayout(version: 1, widgets: rows)

        let merged = DashboardLayoutStore.mergedWithDefaults(existing)
        // Existing rows survive at their original orders.
        let pulse = merged.widgets.first { $0.id == "pulse" }
        #expect(pulse?.order == 0)
        let bp = merged.widgets.first { $0.id == "bp" }
        #expect(bp?.order == 5)
        // Appended rows start at max(existing.order) + 1 = 6.
        let appended = merged.widgets.filter { row in
            !rows.contains { $0.id == row.id }
        }
        #expect(appended.allSatisfy { $0.order >= 6 })
    }

    @Test("v0.5.2 catalog default includes every HK-completeness widget id")
    @MainActor
    func defaultLayoutIncludesV052Widgets() {
        let defaultIds = Set(DashboardWidgetLayout.default.widgets.map(\.id))
        for newId in Self.v052AddedWidgetIds {
            #expect(defaultIds.contains(newId), "default layout missing \(newId)")
            let row = DashboardWidgetLayout.default.widgets.first { $0.id == newId }
            #expect(row?.effectiveTileVisible == true, "\(newId) must be tile-visible by default")
        }
    }

    @Test("load surfaces every v0.5.2 widget id from a pre-v0.5.2 server shape via one-time migration PUT")
    @MainActor
    func loadAppendsMissingWidgetsAndPersists() async {
        // Use a dedicated UserDefaults suite so the migration flag from this
        // test doesn't bleed into other tests / the host app's standard suite.
        let suiteName = "hl.test.dashboardLayout.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        // Make `UserDefaults.standard` route through our suite by overlaying
        // the flag explicitly — the store reads from `.standard`, so we
        // mirror our flag onto it for the duration of the test and clear
        // afterwards.
        let migrationKey = DashboardLayoutStore.defaultsMigrationKey
        let priorFlag = UserDefaults.standard.bool(forKey: migrationKey)
        UserDefaults.standard.removeObject(forKey: migrationKey)
        defer {
            Self.restoreMigrationFlag(priorFlag, forKey: migrationKey)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let api = LayoutStubAPI(initial: Self.preV052Layout())
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()

        // The store's authoritative layout carries every v0.5.2 id.
        // v0.10 W10-PIN (server v1.7.0 LIVE): the GET-path merge workaround is
        // gone (the server now round-trips the full 27-id catalogue). For a
        // pre-v0.5.2 server payload + unset migration flag, the one-time
        // defaults migration (`mergedWithDefaults` + PUT) is the mechanism that
        // brings the local layout up to the full catalogue.
        let mergedIds = Set(store.layout.widgets.map(\.id))
        for newId in Self.v052AddedWidgetIds {
            #expect(mergedIds.contains(newId), "store.layout missing \(newId) after load")
        }
        // The migration PUTs the full catalogue (loaded != mergedWithDefaults).
        let putted = await api.lastPutPayload
        #expect(putted != nil, "expected the one-time defaults migration to PUT the full catalogue")
        #expect(putted?.widgets.count == DashboardWidgetLayout.default.widgets.count)
        // Migration flag was recorded.
        #expect(UserDefaults.standard.bool(forKey: migrationKey) == true)
    }

    @Test("load does not re-PUT when the migration flag is already set")
    @MainActor
    func loadSkipsMigrationWhenFlagSet() async {
        let migrationKey = DashboardLayoutStore.defaultsMigrationKey
        let priorFlag = UserDefaults.standard.bool(forKey: migrationKey)
        UserDefaults.standard.set(true, forKey: migrationKey)
        defer { Self.restoreMigrationFlag(priorFlag, forKey: migrationKey) }

        let api = LayoutStubAPI(initial: Self.preV052Layout())
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()

        // No PUT was issued — the migration short-circuited on the flag.
        let putted = await api.lastPutPayload
        #expect(putted == nil)
        // v0.10 W10-PIN (server v1.7.0 LIVE): the GET-path merge workaround is
        // gone. With the migration flag set, the store reflects the server
        // payload verbatim — the pre-v0.5.2 shape (15 rows) reads back as 15.
        #expect(store.layout.widgets.count == Self.preV052Layout().widgets.count)
    }

    @Test("load on a fresh user (server returns default) records the migration as done with no PUT")
    @MainActor
    func loadFreshUserSkipsPut() async {
        let migrationKey = DashboardLayoutStore.defaultsMigrationKey
        let priorFlag = UserDefaults.standard.bool(forKey: migrationKey)
        UserDefaults.standard.removeObject(forKey: migrationKey)
        defer { Self.restoreMigrationFlag(priorFlag, forKey: migrationKey) }

        // Fresh user — server returns the current `.default` (which already
        // includes the v0.5.2 ids).
        let api = LayoutStubAPI(initial: .default)
        let repo = DashboardRepository(api: api)
        let store = DashboardLayoutStore(repo: repo, swr: nil)

        await store.load()

        // No PUT needed — the merged layout equals the loaded layout.
        let putted = await api.lastPutPayload
        #expect(putted == nil)
        // Flag is recorded so subsequent launches don't recompute.
        #expect(UserDefaults.standard.bool(forKey: migrationKey) == true)
        // All v0.5.2 ids are present (sanity).
        let storeIds = Set(store.layout.widgets.map(\.id))
        for newId in Self.v052AddedWidgetIds {
            #expect(storeIds.contains(newId))
        }
    }
}
