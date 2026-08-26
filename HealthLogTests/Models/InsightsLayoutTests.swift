import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.8.0 W10 — pure reorder / visibility / reconcile math for the
/// server-first Insights layout model. No network, no store: just the
/// value-type transforms the optimistic write path depends on.
@Suite("InsightsLayout — reorder / visibility / reconcile math")
struct InsightsLayoutTests {
    private func layout(_ ids: [String], visible: Set<String> = []) -> InsightsLayout {
        InsightsLayout(tiles: ids.enumerated().map { offset, id in
            InsightsLayoutTile(id: id, visible: visible.isEmpty ? true : visible.contains(id), order: offset)
        })
    }

    @Test("reordering renumbers order to match the new id sequence")
    func reorderingRenumbers() {
        let start = layout(["a", "b", "c"])
        let moved = start.reordering(["c", "a", "b"])
        let ordered = moved.orderedTiles
        #expect(ordered.map(\.id) == ["c", "a", "b"])
        #expect(ordered.map(\.order) == [0, 1, 2])
    }

    @Test("reordering preserves visibility flags per id")
    func reorderingPreservesVisibility() {
        let start = layout(["a", "b", "c"], visible: ["a", "c"])
        let moved = start.reordering(["b", "c", "a"])
        let byId = Dictionary(uniqueKeysWithValues: moved.tiles.map { ($0.id, $0.visible) })
        #expect(byId["a"] == true)
        #expect(byId["b"] == false)
        #expect(byId["c"] == true)
    }

    @Test("reordering appends ids missing from newOrder at the tail")
    func reorderingAppendsMissing() {
        let start = layout(["a", "b", "c", "d"])
        // Only reorder a subset — the rest must keep their relative position.
        let moved = start.reordering(["c", "a"])
        #expect(moved.orderedTiles.map(\.id) == ["c", "a", "b", "d"])
    }

    /// A2 (v0.8.2 W1a) — the grid only ever feeds the VISIBLE tile ids to
    /// `reordering`; the hidden rows must keep their relative sequence in the
    /// unmatched tail so the AddTileSheet (sorted by order) stays stable.
    @Test("reordering of visible-subset keeps hidden rows' relative sequence")
    func reorderingPreservesHiddenRelativeOrder() {
        // Visible: a, c, e (order 0,2,4). Hidden: b, d (order 1,3).
        let start = InsightsLayout(tiles: [
            InsightsLayoutTile(id: "a", visible: true, order: 0),
            InsightsLayoutTile(id: "b", visible: false, order: 1),
            InsightsLayoutTile(id: "c", visible: true, order: 2),
            InsightsLayoutTile(id: "d", visible: false, order: 3),
            InsightsLayoutTile(id: "e", visible: true, order: 4)
        ])
        // Operator drags the visible tiles into e, a, c.
        let moved = start.reordering(["e", "a", "c"])
        // Visible tiles take the lead in the new order; hidden b, d keep their
        // ORIGINAL relative sequence (b before d) at the tail.
        #expect(moved.orderedTiles.map(\.id) == ["e", "a", "c", "b", "d"])
        // Hidden rows stay hidden; visible rows stay visible.
        let byId = Dictionary(uniqueKeysWithValues: moved.tiles.map { ($0.id, $0.visible) })
        #expect(byId["b"] == false)
        #expect(byId["d"] == false)
        #expect(byId["e"] == true)
        // Order is contiguous 0..<5.
        #expect(moved.orderedTiles.map(\.order) == [0, 1, 2, 3, 4])
    }

    /// A2 — the hidden-tail sequence is preserved even when the stored array is
    /// NOT pre-sorted by `order` (a decoded server payload can arrive unsorted).
    @Test("reordering preserves hidden sequence for an unsorted source array")
    func reorderingHiddenSequenceUnsortedSource() {
        // Array order deliberately scrambled vs `order`.
        let start = InsightsLayout(tiles: [
            InsightsLayoutTile(id: "d", visible: false, order: 3),
            InsightsLayoutTile(id: "a", visible: true, order: 0),
            InsightsLayoutTile(id: "e", visible: true, order: 4),
            InsightsLayoutTile(id: "b", visible: false, order: 1),
            InsightsLayoutTile(id: "c", visible: true, order: 2)
        ])
        let moved = start.reordering(["c", "a", "e"])
        // Hidden b (order 1) must still precede hidden d (order 3) regardless
        // of the scrambled array order.
        #expect(moved.orderedTiles.map(\.id) == ["c", "a", "e", "b", "d"])
    }

    @Test("togglingVisibility flips exactly one tile, leaves order intact")
    func togglingVisibilityFlipsOne() {
        let start = layout(["a", "b", "c"], visible: ["a", "b", "c"])
        let toggled = start.togglingVisibility(forId: "b")
        let byId = Dictionary(uniqueKeysWithValues: toggled.tiles.map { ($0.id, $0.visible) })
        #expect(byId["a"] == true)
        #expect(byId["b"] == false)
        #expect(byId["c"] == true)
        #expect(toggled.orderedTiles.map(\.order) == [0, 1, 2])
    }

    @Test("togglingVisibility is a no-op for an unknown id")
    func togglingVisibilityUnknownNoOp() {
        let start = layout(["a", "b"])
        let toggled = start.togglingVisibility(forId: "zzz")
        #expect(toggled == start)
    }

    @Test("visibleTiles returns only visible rows, sorted by order")
    func visibleTilesFilterAndSort() {
        let l = InsightsLayout(tiles: [
            InsightsLayoutTile(id: "a", visible: true, order: 2),
            InsightsLayoutTile(id: "b", visible: false, order: 0),
            InsightsLayoutTile(id: "c", visible: true, order: 1)
        ])
        #expect(l.visibleTiles.map(\.id) == ["c", "a"])
    }

    @Test("filteringForServer drops ids outside the server catalogue")
    func filteringForServerDropsUnknown() {
        let l = InsightsLayout(tiles: [
            InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: true, order: 0),
            InsightsLayoutTile(id: "ios-only-future-tile", visible: true, order: 1),
            InsightsLayoutTile(id: InsightsLayoutTileId.pulse, visible: true, order: 2)
        ])
        let filtered = l.filteringForServer()
        #expect(filtered.tiles.map(\.id) == [InsightsLayoutTileId.weight, InsightsLayoutTileId.pulse])
    }

    @Test("filteringForServer is identity when every id is known")
    func filteringForServerIdentity() {
        let l = layout([InsightsLayoutTileId.weight, InsightsLayoutTileId.pulse])
        #expect(l.filteringForServer() == l)
    }

    @Test("reconciled keeps known ids in order, pushes unknown ids to the tail")
    func reconciledPartitions() {
        let l = InsightsLayout(tiles: [
            InsightsLayoutTile(id: "unknown-1", visible: true, order: 0),
            InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: true, order: 1),
            InsightsLayoutTile(id: InsightsLayoutTileId.pulse, visible: false, order: 2)
        ])
        let r = l.reconciled()
        #expect(r.orderedTiles.map(\.id) == [InsightsLayoutTileId.weight, InsightsLayoutTileId.pulse, "unknown-1"])
        // Order renumbered contiguously.
        #expect(r.orderedTiles.map(\.order) == [0, 1, 2])
        // Visibility survives the partition.
        let byId = Dictionary(uniqueKeysWithValues: r.tiles.map { ($0.id, $0.visible) })
        #expect(byId[InsightsLayoutTileId.pulse] == false)
    }

    @Test("serverId maps the iOS catalogue vocabulary to English wire slugs")
    func serverIdMapping() {
        #expect(InsightsLayoutTileId.serverId(forCatalogueType: "WEIGHT") == InsightsLayoutTileId.weight)
        #expect(InsightsLayoutTileId.serverId(forCatalogueType: "RESTING_HR") == InsightsLayoutTileId.restingPulse)
        #expect(InsightsLayoutTileId.serverId(forCatalogueType: "MOOD_SCORE") == InsightsLayoutTileId.mood)
        #expect(InsightsLayoutTileId.serverId(forCatalogueType: "MOOD_STABILITY") == InsightsLayoutTileId.mood)
        #expect(InsightsLayoutTileId.serverId(forCatalogueType: "ACTIVITY_STEPS") == InsightsLayoutTileId.activeEnergy)
        #expect(InsightsLayoutTileId.serverId(forCatalogueType: "UNMAPPED_FUTURE") == nil)
        // v1.8.0 — the catalogue map emits English canonical ids, so they are
        // all server-known and a fresh PUT carries English on the wire.
        #expect(InsightsLayoutTileId.serverKnownIds.contains(InsightsLayoutTileId.weight))
        #expect(InsightsLayoutTileId.serverKnownIds.contains(InsightsLayoutTileId.bloodPressure))
    }

    @Test("default layout is all-server-known and round-trips through the wire codec")
    func defaultLayoutWireRoundTrip() throws {
        let known = InsightsLayoutTileId.serverKnownIds
        #expect(InsightsLayout.default.tiles.allSatisfy { known.contains($0.id) })
        let data = try JSONEncoder.hlDefault.encode(InsightsLayout.default)
        let decoded = try JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data)
        #expect(decoded == .default)
    }

    // MARK: - v0.11 W28b — widened slug ↔ MetricKind coverage

    /// W28b — the slugs that carry a chartable `MetricKind` MUST each resolve
    /// to a real enum case (anti-hallucination guard: a typo or an invented kind
    /// would surface here, not as a silent dead pill). The four non-chart slugs
    /// (`overview`, `workouts`, `mood`, `medications`) plus the one pending
    /// HK-registry slug (`audio-events`) are exempt.
    ///
    /// W28d — `walking-steadiness` is no longer exempt: `appleWalkingSteadiness`
    /// is a clean 0–100 % mobility quantity, now wired end-to-end (HK registry +
    /// `slugToKind`), so it is one of the 33 chartable slugs.
    @Test("every chartable widened slug maps to a real MetricKind")
    func widenedSlugsMapToRealKinds() {
        let nonChart: Set<String> = [
            InsightsLayoutTileId.overview,
            InsightsLayoutTileId.workouts,
            InsightsLayoutTileId.mood,
            InsightsLayoutTileId.medications,
            InsightsLayoutTileId.audioEvents,
            // v0141 W-DATAPARITY (P4) — `nutrients` is server-known (so the layout
            // PUT round-trips it) but has no chartable iOS `MetricKind` yet.
            InsightsLayoutTileId.nutrients
        ]
        let chartableSlugs = InsightsLayoutTileId.serverKnownIds.subtracting(nonChart)
        for slug in chartableSlugs {
            let kind = InsightsTabSlug.metricKind(forSlug: slug)
            #expect(kind != nil, "chartable slug \(slug) must map to a MetricKind")
            // displayName comes from the kind descriptor — never empty.
            #expect(kind.map { !$0.displayName.isEmpty } ?? false)
        }
        // Parity Build 4 / 4.1 — five slugs joined `serverKnownIds`: `steps`
        // (a `SUB_PAGE_METRIC` key on the web since v1.12, previously an iOS-only
        // tail-append) plus the four v1.25 clinical slugs `pain` / `waist` /
        // `waist-to-height` / `grip-strength`, whose `MetricKind` + Dashboard tile
        // already shipped but which had no slug, so their tile was a dead tap.
        // All five are chartable. `recovery` is deliberately still NOT here — it
        // is a routed web page but not a `SUB_PAGE_METRIC` key, so the layout
        // route's `z.enum` would 422 the whole PUT body.
        // The 46 chartable slugs + 6 exempt = 52 server-known ids. v0141
        // W-DATAPARITY (P4) added the non-chart `nutrients` slug (a v1.29
        // `SUB_PAGE_METRIC` key), lifting the count from 51 → 52 and the exempt
        // set from 5 → 6.
        #expect(chartableSlugs.count == 46)
        #expect(InsightsLayoutTileId.serverKnownIds.count == 52)
        #expect(InsightsLayoutTileId.serverKnownIds.contains(InsightsLayoutTileId.nutrients))
        #expect(InsightsTabSlug.metricKind(forSlug: InsightsLayoutTileId.nutrients) == nil)
        #expect(!InsightsLayoutTileId.serverKnownIds.contains(InsightsLayoutTileId.recovery))
    }

    /// v0141 W-DATAPARITY (P4) — a layout carrying the `nutrients` tile survives
    /// `filteringForServer()` (is NOT dropped from the PUT body), the regression
    /// mirror of the `steps`-survives fix. Before the fix `nutrients` was outside
    /// `serverKnownIds`, so every iOS layout PUT silently dropped the operator's
    /// Nutrients tile order/visibility — the same destructive-write class as the
    /// old `steps` bug.
    @Test("filteringForServer keeps the nutrients tile (P4 — not dropped)")
    func filteringForServerKeepsNutrients() {
        let layout = InsightsLayout(tiles: [
            InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0),
            InsightsLayoutTile(id: InsightsLayoutTileId.nutrients, visible: true, order: 1),
            InsightsLayoutTile(id: InsightsLayoutTileId.weight, visible: false, order: 2)
        ])
        let filtered = layout.filteringForServer()
        #expect(filtered.tiles.contains { $0.id == InsightsLayoutTileId.nutrients })
        // Visibility + order of the nutrients row survive the filter untouched.
        let nutrientsTile = filtered.tiles.first { $0.id == InsightsLayoutTileId.nutrients }
        #expect(nutrientsTile?.visible == true)
        #expect(nutrientsTile?.order == 1)
    }

    /// W28b/W28d — `audio-events` is the sole remaining pending slug: it is
    /// accepted by the server enum (so a persisted layout round-trips) but
    /// deliberately renders no pill — `audioExposureEvent` is a HealthKit
    /// CATEGORY / event-marker type, not a continuous chartable series, so it
    /// has no chartable `MetricKind` (see W28d report). `walking-steadiness`
    /// now maps to `.walkingSteadiness` and is no longer pending.
    @Test("audio-events is server-known but maps to no chartable MetricKind")
    func pendingSlugsHaveNoKind() {
        #expect(InsightsLayoutTileId.serverKnownIds.contains(InsightsLayoutTileId.audioEvents))
        #expect(InsightsTabSlug.metricKind(forSlug: InsightsLayoutTileId.audioEvents) == nil)
        // Conversely walking-steadiness now resolves to a real kind.
        #expect(InsightsTabSlug.metricKind(forSlug: InsightsLayoutTileId.walkingSteadiness) == .walkingSteadiness)
    }

    /// B5 (v0.10.0 Walkthrough-1) — the PUT body MUST carry `version: 1`. The
    /// server route requires `version: z.literal(1)`; omitting it 422s with
    /// "Validation failed", breaking every insights-customize toggle.
    @Test("encoded PUT body includes version:1")
    func encodedBodyCarriesVersion() throws {
        let l = layout([InsightsLayoutTileId.weight, InsightsLayoutTileId.pulse])
        let data = try JSONEncoder.hlDefault.encode(l.filteringForServer())
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["version"] as? Int == 1)
        #expect(json["tiles"] != nil)
    }

    /// Forward-compat: a server GET without `version` (legacy cache) decodes to
    /// the current version rather than failing.
    @Test("decode tolerates an absent version, defaulting to current")
    func decodeToleratesAbsentVersion() throws {
        let json = """
        { "tiles": [ { "id": "weight", "visible": true, "order": 0 } ] }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data)
        #expect(decoded.version == InsightsLayout.currentVersion)
        #expect(decoded.tiles.count == 1)
    }

    // MARK: - v1.8.0 EN tile-id rename + DE alias compatibility

    /// v1.8.0 — a GET payload carrying the canonical English ids decodes, and
    /// every tile is server-known (so `reconciled` keeps all of them in the
    /// render path instead of dropping them to the unknown tail).
    @Test("v1.8.0: GET with English ids decodes and every tile renders")
    func englishGETDecodesAndRenders() throws {
        let json = """
        { "version": 1, "tiles": [
            { "id": "overview", "visible": true, "order": 0 },
            { "id": "blood-pressure", "visible": true, "order": 1 },
            { "id": "pulse", "visible": true, "order": 2 },
            { "id": "oxygen", "visible": false, "order": 3 },
            { "id": "body-temperature", "visible": false, "order": 4 },
            { "id": "weight", "visible": true, "order": 5 },
            { "id": "active-energy", "visible": true, "order": 6 },
            { "id": "sleep", "visible": false, "order": 7 },
            { "id": "resting-pulse", "visible": true, "order": 8 },
            { "id": "mood", "visible": true, "order": 9 },
            { "id": "medications", "visible": true, "order": 10 }
        ] }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data)
        let known = InsightsLayoutTileId.serverKnownIds
        // Every decoded id is server-known → none is forward-compat-dropped.
        #expect(decoded.tiles.allSatisfy { known.contains($0.id) })
        let reconciled = decoded.reconciled()
        #expect(reconciled.tiles.count == decoded.tiles.count)
        // The English mood slug renders the mood-pair in the grid render path.
        #expect(reconciled.tiles.contains { $0.id == InsightsLayoutTileId.mood && $0.visible })
        #expect(reconciled.tiles.contains { $0.id == InsightsLayoutTileId.bloodPressure })
    }

    /// v1.8.0 — a legacy DE payload (an older server, or a stale instant-paint
    /// cache persisted before the rename) still decodes: every German id is
    /// normalised onto its English canonical equivalent.
    @Test("v1.8.0: legacy German GET payload decodes via aliases to English")
    func legacyGermanGETDecodesViaAliases() throws {
        let json = """
        { "version": 1, "tiles": [
            { "id": "blutdruck", "visible": true, "order": 0 },
            { "id": "puls", "visible": true, "order": 1 },
            { "id": "sauerstoff", "visible": false, "order": 2 },
            { "id": "koerpertemperatur", "visible": false, "order": 3 },
            { "id": "gewicht", "visible": true, "order": 4 },
            { "id": "aktive-energie", "visible": true, "order": 5 },
            { "id": "schlaf", "visible": false, "order": 6 },
            { "id": "ruhepuls", "visible": true, "order": 7 },
            { "id": "stimmung", "visible": true, "order": 8 },
            { "id": "medikamente", "visible": true, "order": 9 }
        ] }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data)
        let ids = decoded.orderedTiles.map(\.id)
        #expect(ids == [
            InsightsLayoutTileId.bloodPressure, InsightsLayoutTileId.pulse,
            InsightsLayoutTileId.oxygen, InsightsLayoutTileId.bodyTemperature,
            InsightsLayoutTileId.weight, InsightsLayoutTileId.activeEnergy,
            InsightsLayoutTileId.sleep, InsightsLayoutTileId.restingPulse,
            InsightsLayoutTileId.mood, InsightsLayoutTileId.medications
        ])
        // After alias normalisation everything is server-known → nothing drops.
        let known = InsightsLayoutTileId.serverKnownIds
        #expect(decoded.tiles.allSatisfy { known.contains($0.id) })
    }

    /// v1.8.0 — the PUT wire body emits English ids. A layout decoded from a
    /// legacy German payload is already normalised in memory, so re-encoding it
    /// for the wire carries English, never the German aliases.
    @Test("v1.8.0: PUT body emits English ids even after a legacy German decode")
    func putBodyEmitsEnglishAfterLegacyDecode() throws {
        let json = """
        { "version": 1, "tiles": [
            { "id": "blutdruck", "visible": true, "order": 0 },
            { "id": "stimmung", "visible": true, "order": 1 }
        ] }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data)
        let wire = try JSONEncoder.hlDefault.encode(decoded.filteringForServer())
        let obj = try #require(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let tiles = try #require(obj["tiles"] as? [[String: Any]])
        let emittedIds = tiles.compactMap { $0["id"] as? String }
        #expect(emittedIds == [InsightsLayoutTileId.bloodPressure, InsightsLayoutTileId.mood])
        // Belt + braces: no German id survives onto the wire.
        #expect(!emittedIds.contains("blutdruck"))
        #expect(!emittedIds.contains("stimmung"))
    }

    // MARK: - v1.15.11 layout v2 — sections round-trip (A1 wipe fix)

    /// The fixture mirrors a real v1.16.3 GET: version 2, the 8 section ids in
    /// a user-shuffled order with mixed visibility, PLUS one id this client
    /// does not know — which must survive verbatim (no filter, no normalize).
    private var v2SectionsFixture: String {
        """
        { "version": 2,
          "sections": [
            { "id": "trends", "visible": true, "order": 0 },
            { "id": "wellness-scores", "visible": false, "order": 1 },
            { "id": "daily-briefing", "visible": true, "order": 2 },
            { "id": "vitals", "visible": true, "order": 3 },
            { "id": "period-review", "visible": false, "order": 4 },
            { "id": "cycle-summary", "visible": true, "order": 5 },
            { "id": "signals", "visible": true, "order": 6 },
            { "id": "rhythm-events", "visible": false, "order": 7 },
            { "id": "brand-new-section", "visible": true, "order": 8 }
          ],
          "tiles": [
            { "id": "weight", "visible": true, "order": 0 },
            { "id": "pulse", "visible": false, "order": 1 }
          ] }
        """
    }

    @Test("v2: sections decode verbatim — order, fields, unknown ids untouched")
    func v2SectionsDecodeVerbatim() throws {
        let data = try #require(v2SectionsFixture.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data)
        #expect(decoded.version == 2)
        let sections = try #require(decoded.sections)
        #expect(sections.count == 9)
        #expect(sections.map(\.id) == [
            "trends", "wellness-scores", "daily-briefing", "vitals",
            "period-review", "cycle-summary", "signals", "rhythm-events",
            "brand-new-section"
        ])
        #expect(sections.map(\.visible) == [true, false, true, true, false, true, true, false, true])
        #expect(sections.map(\.order) == Array(0 ... 8))
    }

    @Test("v2: every mutation helper carries sections through unchanged")
    func v2MutationHelpersPreserveSections() throws {
        let data = try #require(v2SectionsFixture.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data)
        let expected = decoded.sections
        #expect(decoded.reconciled().sections == expected)
        #expect(decoded.reordering(["pulse", "weight"]).sections == expected)
        #expect(decoded.togglingVisibility(forId: "weight").sections == expected)
        #expect(decoded.filteringForServer().sections == expected)
        // Chained store mutation (the real reorder path) keeps them too,
        // along with the server's version.
        let mutated = decoded.reconciled().reordering(["pulse", "weight"]).filteringForServer()
        #expect(mutated.sections == expected)
        #expect(mutated.version == 2)
    }

    @Test("v2: re-encode after a tiles edit emits the sections byte-faithfully")
    func v2ReencodePreservesSectionsExactly() throws {
        let data = try #require(v2SectionsFixture.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data)
        let wire = try JSONEncoder.hlDefault.encode(
            decoded.reordering(["pulse", "weight"]).filteringForServer()
        )
        let obj = try #require(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let emitted = try #require(obj["sections"] as? [[String: Any]])
        let originalRoot = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let original = try #require(originalRoot["sections"] as? [[String: Any]])
        // NSArray equality covers order + every field of every element.
        #expect(emitted as NSArray == original as NSArray)
    }

    @Test("v1 layouts encode WITHOUT a sections key (no explicit null)")
    func v1EncodeOmitsSections() throws {
        let l = layout([InsightsLayoutTileId.weight])
        #expect(l.sections == nil)
        let wire = try JSONEncoder.hlDefault.encode(l.filteringForServer())
        let obj = try #require(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(obj["sections"] == nil)
    }

    @Test("tolerant decode: a malformed section element is skipped, not fatal")
    func malformedSectionElementSkipped() throws {
        let json = """
        { "version": 2,
          "sections": [
            { "id": "vitals", "visible": true, "order": 0 },
            { "id": "broken" },
            42,
            { "id": "trends", "visible": false, "order": 3 }
          ],
          "tiles": [ { "id": "weight", "visible": true, "order": 0 } ] }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder.hlDefault.decode(InsightsLayout.self, from: data)
        #expect(decoded.sections?.map(\.id) == ["vitals", "trends"])
        #expect(decoded.tiles.count == 1)
    }
}
