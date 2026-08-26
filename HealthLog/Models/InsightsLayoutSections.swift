import Foundation

// Parity Build 4 · Item 4.5 — the `sections` SLICE of the Insights layout.
//
// `InsightsLayoutSection` (the row shape) has existed since v1.15.11, but only
// as a byte-faithful ECHO: iOS round-tripped whatever the server sent and never
// read, ordered, filtered or mutated it. Section show/hide and reorder — a full
// web surface (`insights-edit-mode.tsx:369-418`) — were therefore completely
// unreachable from the phone (audit `12-layout-dashboard-insights-domains.md`
// §A P0 #1/#2, the only P0 in that cluster).
//
// This file adds the missing plumbing, deliberately mirroring the `tiles` slice
// that already works: a canonical id catalogue, a resolver that merges the
// server default set onto a partial/absent list, and the two pure mutation
// helpers (`reorderingSections` / `togglingSectionVisibility`) the store wraps
// with the same optimistic-write-through it uses for tiles.
//
// **The echo contract is NOT broken.** `reconciled(knownIds:)` still passes
// `sections` through verbatim, and an unknown section id introduced by a future
// server release still round-trips: `resolvedSections` is a RENDER/EDIT view
// computed on demand, never a rewrite of the stored array. Only an explicit
// section edit produces a PUT that carries a normalised list — exactly what the
// web editor does.

/// The server's `INSIGHTS_SECTION_IDS` catalogue (`src/lib/insights-layout.ts`)
/// — the overview's big semantic blocks, customizable on top of the per-metric
/// `tiles` list. Order here IS the default render order.
///
/// Hero / Score / Coach is deliberately absent: on both clients it is an
/// anchored, non-customizable top block, not a section.
///
/// English from birth — unlike the tile ids these never had a German phase, so
/// there is no alias map.
public enum InsightsLayoutSectionId {
    public static let wellnessScores = "wellness-scores"
    public static let dailyBriefing = "daily-briefing"
    public static let vitals = "vitals"
    public static let trends = "trends"
    public static let periodReview = "period-review"
    public static let cycleSummary = "cycle-summary"
    public static let signals = "signals"
    public static let rhythmEvents = "rhythm-events"
    public static let healthStatus = "health-status"
    public static let breathing = "breathing"
    public static let labsChanges = "labs-changes"
    /// v1.28.50 — the waveform-backed ECG recording surface, kept separate from
    /// the waveform-less `rhythm-events` timeline. iOS has no ECG screen yet
    /// (audit `02-insights.md` §B, scheduled for a later build), but the ROW
    /// rides this same array — so the operator can still order and hide it from
    /// the phone and have the web honour it.
    public static let ecg = "ecg"

    /// The canonical catalogue in default render order. Mirrors the server
    /// array element-for-element; a mismatch would silently desync the two
    /// editors, so `InsightsLayoutSectionsTests` pins it.
    public static let allInDefaultOrder: [String] = [
        wellnessScores, dailyBriefing, vitals, trends, periodReview,
        cycleSummary, signals, rhythmEvents, healthStatus, breathing,
        labsChanges, ecg
    ]

    /// Membership check for the render/edit resolver. Kept as a `Set` so the
    /// resolver stays linear.
    public static let known: Set<String> = Set(allInDefaultOrder)

    /// The default section list: every catalogue id, visible, in catalogue
    /// order. Mirrors `DEFAULT_INSIGHTS_LAYOUT.sections`.
    public static var defaultSections: [InsightsLayoutSection] {
        allInDefaultOrder.enumerated().map { order, id in
            InsightsLayoutSection(id: id, visible: true, order: order)
        }
    }
}

// MARK: - Resolution (read view)

public extension InsightsLayout {
    /// The section list to RENDER and EDIT from: known ids in their stored
    /// order, with any catalogue id the stored blob never mentioned appended at
    /// the tail in catalogue order (so a server-side section addition shows up
    /// without a migration), and unknown ids dropped.
    ///
    /// Mirrors the server `resolveInsightsSections` (`insights-layout.ts:254-295`)
    /// so both editors agree on what the user is looking at. A `nil` / empty
    /// `sections` (a v1 blob, a legacy cache, a fresh install) yields the full
    /// default set.
    ///
    /// This is a computed VIEW — it never mutates ``sections``, so the verbatim
    /// echo an unknown future id relies on is untouched.
    var resolvedSections: [InsightsLayoutSection] {
        guard let sections, !sections.isEmpty else {
            return InsightsLayoutSectionId.defaultSections
        }
        var seen = Set<String>()
        let kept = sections
            .filter { InsightsLayoutSectionId.known.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { $0.order < $1.order }
        let missing = InsightsLayoutSectionId.allInDefaultOrder
            .filter { !seen.contains($0) }
            .map { InsightsLayoutSection(id: $0, visible: true, order: 0) }
        return (kept + missing).enumerated().map { order, row in
            InsightsLayoutSection(id: row.id, visible: row.visible, order: order)
        }
    }

    /// The ids of the sections the operator wants rendered, in render order.
    /// The overview composes itself from exactly this list.
    var visibleSectionIds: [String] {
        resolvedSections.filter(\.visible).map(\.id)
    }

    /// True when `id` is currently visible. Unknown ids report `false` rather
    /// than fail-open — an id outside the catalogue has no iOS surface anyway.
    func isSectionVisible(_ id: String) -> Bool {
        resolvedSections.first { $0.id == id }?.visible ?? false
    }
}

// MARK: - Mutation (pure, mirrors the tiles helpers)

public extension InsightsLayout {
    /// Re-orders sections by replacing each row's `order` with its position in
    /// `newOrder` (matched by id); catalogue ids absent from `newOrder` keep
    /// their relative sequence after the listed entries.
    ///
    /// Deliberately the same shape as ``reordering(_:)`` for tiles — the store,
    /// the settings screen and the tests all read as one idiom.
    func reorderingSections(_ newOrder: [String]) -> InsightsLayout {
        var remaining = resolvedSections
        var output: [InsightsLayoutSection] = []
        for id in newOrder {
            guard let index = remaining.firstIndex(where: { $0.id == id }) else { continue }
            let original = remaining.remove(at: index)
            output.append(
                InsightsLayoutSection(id: original.id, visible: original.visible, order: output.count)
            )
        }
        let baseOrder = output.count
        for (offset, row) in remaining.enumerated() {
            output.append(
                InsightsLayoutSection(id: row.id, visible: row.visible, order: baseOrder + offset)
            )
        }
        return InsightsLayout(version: version, sections: output, tiles: tiles)
    }

    /// Flips the `visible` flag for one section id. No-op for ids outside the
    /// catalogue. Resolves first, so the very first toggle on a layout that
    /// carried no `sections` at all materialises the full default set with just
    /// that one row flipped (what the web editor sends too).
    func togglingSectionVisibility(forId id: String) -> InsightsLayout {
        guard InsightsLayoutSectionId.known.contains(id) else { return self }
        let updated = resolvedSections.map { row -> InsightsLayoutSection in
            guard row.id == id else { return row }
            return InsightsLayoutSection(id: row.id, visible: !row.visible, order: row.order)
        }
        return InsightsLayout(version: version, sections: updated, tiles: tiles)
    }
}

// MARK: - P8 — the ECG sub-page slug

public extension InsightsLayoutTileId {
    /// v0141 W-PARITY (P8) — the ECG recording surface slug (web
    /// `/insights/ecg`, server v1.28.50). A composite special page: ECG carries
    /// no `MeasurementType` at all, so it has no chartable `MetricKind`.
    ///
    /// Lives here rather than in ``InsightsLayout`` so it sits beside its
    /// sibling ``InsightsLayoutSectionId/ecg`` (the overview SECTION row) —
    /// same feature, one file.
    ///
    /// **Deliberately NOT in ``InsightsLayoutTileId/serverKnownIds``** — for
    /// exactly the reason `recovery` is not: `ecg` is a routed page and a
    /// section id, but NOT a `SUB_PAGE_METRIC` key, so it is absent from the
    /// server's `INSIGHTS_TILE_IDS` and the layout route's `z.enum` would 422
    /// the WHOLE PUT body. The pill reaches the strip as a data-gated entry
    /// instead (`InsightsTabSelection.ordered`), mirroring the web tab strip,
    /// which injects ECG into the Heart group outside the slug-driven
    /// availability model (`insights-tab-strip.tsx:172-181, 588`).
    static let ecg = "ecg"
}
