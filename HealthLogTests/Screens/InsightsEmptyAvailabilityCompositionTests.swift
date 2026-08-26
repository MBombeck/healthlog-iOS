// 20-01 (R4) — the reduction behind "in den Insights fehlen die meisten
// Abschnitte", pinned so it stops being an argument.
//
// The operator's build-267 report (`WALKTHROUGH-B267-REGRESSIONS.md`, R4) names
// exactly five survivors on the Insights strip:
//
//     Überblick · Erholung · Workouts · Stimmung · EKG
//
// That set is not a coincidence and it is not a mount-condition change: it is
// precisely what `InsightsTabSelection.ordered(...)` emits when
// `availableKinds` is EMPTY and `.medications` is absent from
// `availableSpecials`. Reading `InsightsMetricTabStrip.swift:374-441` term by
// term:
//
//   - every `.metric` page dies at the `guard availableKinds.contains(kind)`
//     inside the layout loop (`:396`), so an empty availability set erases the
//     whole chartable universe at once;
//   - Erholung (`.recovery`) is inserted BEFORE the layout loop (`:386-389`)
//     and `InsightsContainerScreen+Ordering.liveAvailableSpecials` inserts it
//     unconditionally, so it cannot be gated away by missing measurements;
//   - Workouts is likewise unconditional in `liveAvailableSpecials`;
//   - Stimmung rides `moodStore.entries`, which are LOCAL — no
//     `MeasurementsStore` involvement at all;
//   - EKG is appended outside the layout loop (`:415-418`) and gated on
//     `ecgStore.hasRecordings`, another store entirely;
//   - Medikamente is a layout tile and IS gated on `medicationsStore`, so it
//     drops out whenever that list has not landed yet.
//
// So the five survivors are the *complement* of everything `MeasurementsStore`
// feeds. The report reduces to one fact: `MeasurementsStore` published neither
// `availableKinds` nor `recent`. WHY it did not is 20-01's measurement and
// 22-01's fix; this file only fixes the reduction in place so nobody has to
// re-derive it, and so 22-01 inherits a failing test the moment it changes the
// composition contract.
//
// **This pin is GREEN by construction against the current tree and carries no
// `EXPECTED_RED` marker** — stated plainly, as 14-06's "preflight-observe"
// precedent allows. It is a characterization test, not a defect claim.

import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

@Suite("Insights composition under empty availability (20-01 / R4)")
struct InsightsEmptyAvailabilityCompositionTests {
    /// The operator's five survivors, as a set — order is his server layout's
    /// business, membership is the mechanism's.
    private static let fiveSurvivors: Set<InsightsTabSelection> = [
        .overview,
        .special(.recovery),
        .special(.workouts),
        .special(.mood),
        .special(.ecg)
    ]

    /// A layout in the shipped server-default shape: every metric tile the
    /// strip can render, plus the mood / medications / workouts special slugs,
    /// all visible. This is the layout a signed-in operator has; the point of
    /// the test is that the LAYOUT is not what removed his sections.
    private func operatorLayout() -> InsightsLayout {
        let slugs = [
            InsightsLayoutTileId.weight,
            InsightsLayoutTileId.bloodPressure,
            InsightsLayoutTileId.pulse,
            InsightsLayoutTileId.restingPulse,
            InsightsLayoutTileId.mood,
            InsightsLayoutTileId.activeEnergy,
            InsightsLayoutTileId.medications,
            InsightsLayoutTileId.sleep,
            InsightsLayoutTileId.bmi,
            InsightsLayoutTileId.oxygen,
            InsightsLayoutTileId.hrv,
            InsightsLayoutTileId.workouts,
            InsightsLayoutTileId.steps
        ]
        var tiles = [InsightsLayoutTile(id: InsightsLayoutTileId.overview, visible: true, order: 0)]
        for (offset, slug) in slugs.enumerated() {
            tiles.append(InsightsLayoutTile(id: slug, visible: true, order: offset + 1))
        }
        return InsightsLayout(tiles: tiles)
    }

    /// What `liveAvailableSpecials` produces for the operator's situation:
    /// mood entries exist locally, ECG recordings exist, workouts and recovery
    /// are unconditional — and `.medications` is ABSENT because the medications
    /// list had not landed at the moment the strip composed.
    private static let survivingSpecials: Set<InsightsSpecialPage> = [
        .recovery, .workouts, .mood, .ecg
    ]

    // MARK: - 1) the reduction itself

    @Test("Leere Verfügbarkeit lässt genau die fünf Abschnitte übrig, die der Betreiber sieht")
    func emptyAvailabilityLeavesExactlyTheOperatorsFiveSections() {
        let ordered = InsightsTabSelection.ordered(
            layout: operatorLayout(),
            availableKinds: [],
            availableSpecials: Self.survivingSpecials
        )

        #expect(
            Set(ordered) == Self.fiveSurvivors,
            "R4's five survivors are exactly the complement of everything MeasurementsStore feeds"
        )
        #expect(ordered.count == 5, "and nothing appears twice")
        #expect(ordered.first == .overview, "Übersicht stays the mandatory first pill")
        #expect(
            ordered.contains(.special(.recovery)),
            "Erholung is inserted outside the layout loop, so availability cannot remove it"
        )
        #expect(
            !ordered.contains(where: { if case .metric = $0 { true } else { false } }),
            "every metric page dies at the availability guard inside the layout loop"
        )
    }

    /// The absent `.medications` half of the reduction, isolated: the pill is a
    /// layout tile like any other, and it is the medications STORE that gates
    /// it — so its disappearance is a second, independent store's silence, not
    /// a layout or a mount condition.
    @Test("Medikamente fehlt genau dann, wenn der Medikamenten-Store noch nichts veröffentlicht hat")
    func medicationsIsAbsentExactlyWhenItsOwnStoreIsSilent() {
        let withoutMedications = InsightsTabSelection.ordered(
            layout: operatorLayout(),
            availableKinds: [],
            availableSpecials: Self.survivingSpecials
        )
        #expect(!withoutMedications.contains(.special(.medications)))

        let withMedications = InsightsTabSelection.ordered(
            layout: operatorLayout(),
            availableKinds: [],
            availableSpecials: Self.survivingSpecials.union([.medications])
        )
        #expect(
            withMedications.contains(.special(.medications)),
            "the layout carries the tile; only the store's silence removed it"
        )
    }

    // MARK: - 2) and the sections come back the moment availability lands

    /// The other side of the same guard: a NON-empty `availableKinds` restores
    /// exactly the metric pages the layout carries for those kinds, and nothing
    /// else. This is the assertion 22-01 will have to keep true whichever fix
    /// the measurement selects.
    @Test("Sobald Verfügbarkeit ankommt, kehren genau die zugehörigen Metrik-Seiten zurück")
    func availabilityRestoresExactlyItsMetricPages() {
        let landed: Set<MetricKind> = [.weight, .bloodPressure, .pulse]
        let ordered = InsightsTabSelection.ordered(
            layout: operatorLayout(),
            availableKinds: landed,
            availableSpecials: Self.survivingSpecials
        )

        let metrics = Set(ordered.compactMap { selection -> MetricKind? in
            if case let .metric(kind) = selection { return kind }
            return nil
        })
        #expect(metrics == landed, "exactly the landed kinds, no more and no fewer")
        #expect(
            Self.fiveSurvivors.isSubset(of: Set(ordered)),
            "and the five survivors are still there — availability only ever adds"
        )
    }

    /// A single kind is enough to break the reported symptom, which is why the
    /// symptom is evidence of an EMPTY set rather than a slow or partial one.
    @Test("Schon eine einzige verfügbare Metrik widerlegt das gemeldete Bild")
    func oneAvailableKindAlreadyContradictsTheReportedPicture() {
        let ordered = InsightsTabSelection.ordered(
            layout: operatorLayout(),
            availableKinds: [.weight],
            availableSpecials: Self.survivingSpecials
        )
        #expect(Set(ordered) != Self.fiveSurvivors)
        #expect(ordered.contains(.metric(.weight)))
    }
}
