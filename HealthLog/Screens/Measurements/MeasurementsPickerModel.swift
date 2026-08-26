import Foundation

/// v0.14.2 (#136) — pure, view-free model for the **Messwerte** metric-type
/// picker (`MeasurementsPickerScreen`).
///
/// The operator asked for "ein Menü, in dem ich eine Messgröße auswähle
/// (Puls / Gewicht / Blutdruck / …) → dann eine Tabelle der Werte". The
/// values table ALREADY exists: `MeasurementListScreen(kind:)` (the
/// Apple-Health-style day/week/month bucketed list with edit/delete + source
/// filter), today only reachable via the chart drill-down. So the only missing
/// piece is the *picker* — this model decides which kinds to list, in which
/// section, in which order. The screen renders one `NavigationLink` per kind
/// that pushes the existing list (no new values table is built).
///
/// **Taxonomy parity.** Sections mirror the app's own metric taxonomy used by
/// Insights (`InsightsMetricCategory` via `InsightsCategoryGroups`): every
/// grouped kind lands in its category section; the flat (ungrouped) primary
/// kinds — `blood-pressure · pulse · weight · bmi · sleep · glucose · steps …`
/// — fold into a leading **Core** section, exactly the set the web/Insights
/// keep as direct pills. Ordering inside a section follows the stable
/// `MetricKind.allCases` declaration order so the list never re-shuffles.
///
/// **Availability.** When `kindsWithData` is non-empty the picker shows ONLY
/// those kinds (Apple-Health "Browse" only lists categories that have data).
/// When it's empty — a brand-new account, or the availability probe hasn't
/// resolved yet — the model returns no sections and the screen paints its calm
/// empty state instead of a wall of zero-data rows.
enum MeasurementsPickerModel {
    /// One rendered section in the picker.
    struct Section: Identifiable, Equatable {
        /// Stable id — the leading core section is `"core"`, category sections
        /// use the `InsightsMetricCategory.rawValue`.
        let id: String
        /// Localized section header. `nil` for the Core section, which renders
        /// headerless at the top (its rows ARE the primary metrics).
        let category: InsightsMetricCategory?
        let kinds: [MetricKind]
    }

    /// The canonical declaration order of every `MetricKind` — drives the
    /// within-section ordering so the list is deterministic + matches the
    /// descriptor catalogue order callers see elsewhere.
    private static let canonicalOrder: [MetricKind: Int] = {
        var map: [MetricKind: Int] = [:]
        for (index, kind) in MetricKind.allCases.enumerated() {
            map[kind] = index
        }
        return map
    }()

    /// Builds the picker sections.
    ///
    /// - Parameter kindsWithData: kinds the user actually has measurements for.
    ///   Pass the empty set to signal "nothing to browse yet" (→ no sections,
    ///   empty state). Kinds absent here are never listed.
    /// - Returns: Core section first (flat/primary kinds), then one section per
    ///   `InsightsMetricCategory` that has ≥1 available member, in category
    ///   order. Empty sections are dropped.
    static func sections(kindsWithData: Set<MetricKind>) -> [Section] {
        guard !kindsWithData.isEmpty else { return [] }

        var coreKinds: [MetricKind] = []
        var byCategory: [InsightsMetricCategory: [MetricKind]] = [:]

        for kind in kindsWithData {
            if let category = InsightsCategoryGroups.category(for: kind) {
                byCategory[category, default: []].append(kind)
            } else {
                coreKinds.append(kind)
            }
        }

        var sections: [Section] = []
        if !coreKinds.isEmpty {
            sections.append(
                Section(id: "core", category: nil, kinds: sorted(coreKinds))
            )
        }
        for category in InsightsMetricCategory.allCases {
            guard let members = byCategory[category], !members.isEmpty else { continue }
            sections.append(
                Section(id: category.rawValue, category: category, kinds: sorted(members))
            )
        }
        return sections
    }

    /// Flat, sorted list of every kind the picker would show — used by the
    /// screen's accessibility / count affordances and by tests.
    static func orderedKinds(kindsWithData: Set<MetricKind>) -> [MetricKind] {
        sections(kindsWithData: kindsWithData).flatMap(\.kinds)
    }

    private static func sorted(_ kinds: [MetricKind]) -> [MetricKind] {
        kinds.sorted { (canonicalOrder[$0] ?? .max) < (canonicalOrder[$1] ?? .max) }
    }
}
