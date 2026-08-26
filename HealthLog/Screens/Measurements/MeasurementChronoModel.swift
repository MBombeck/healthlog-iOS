import Foundation

/// v0.14.8 — pure, view-free model for the **chronological** cross-category
/// measurement feed (`MeasurementsChronoFeed`, mounted as the "Chronologisch"
/// mode of `MeasurementsPickerScreen`).
///
/// The existing Messwerte entry is a metric-TYPE picker (grouped by category,
/// each row pushing the per-kind values table). The operator asked for the
/// complementary view: "manchmal möchte man einfach nur sehen, was die letzten
/// Messwerte sind — chronologisch, über alle Kategorien hinweg" plus a way to
/// "zwischen den Kategorien hin- und her-sliden". This model owns the
/// pure decisions for that feed:
///   • which category chips the strip shows (only categories that carry data),
///   • the time-sorted (newest-first) row order,
///   • the per-chip filter.
///
/// **Taxonomy parity.** Categories mirror the app's own Insights taxonomy
/// (`InsightsMetricCategory` via `InsightsCategoryGroups`). The flat/primary
/// kinds that Insights keeps as direct pills — `blood-pressure · pulse · weight
/// · bmi · sleep · glucose · steps …` — have no `InsightsMetricCategory`; here
/// they fold into a synthetic leading **Core** chip (`ChronoFilter.core`) so the
/// strip covers every kind, exactly the Core-section idiom the type-picker uses.
enum MeasurementChronoModel {
    /// One selectable chip in the category strip. `all` always leads; `core`
    /// holds the flat/primary kinds; `category` holds one Insights category.
    enum ChronoFilter: Hashable, Identifiable {
        case all
        case core
        case category(InsightsMetricCategory)

        var id: String {
            switch self {
            case .all: "all"
            case .core: "core"
            case let .category(category): category.rawValue
            }
        }

        /// Stable UI-test identifier for the chip.
        var accessibilityIdentifier: String {
            "measurements.chrono.chip.\(id)"
        }

        /// The localized chip label. `all` reuses the existing "All"/"Alle" key;
        /// `core` reuses "General"/"Allgemein" (the flat/primary bucket); a
        /// category defers to `InsightsMetricCategory.label` (web-parity names),
        /// so the strip shares the Insights vocabulary.
        var label: String {
            switch self {
            case .all: String(localized: "All")
            case .core: String(localized: "General")
            case let .category(category): category.label
            }
        }
    }

    /// The chrono filter a measurement belongs to — its Insights category, or
    /// `.core` for a flat/primary kind. Never `.all` (that's the strip-only
    /// "show everything" pseudo-filter).
    static func filter(for kind: MetricKind) -> ChronoFilter {
        if let category = InsightsCategoryGroups.category(for: kind) {
            return .category(category)
        }
        return .core
    }

    /// Builds the ordered chip strip from the measurements on hand.
    ///
    /// - `all` always leads (it is meaningful whenever there is ≥1 row).
    /// - then `core` if any flat/primary kind has data,
    /// - then each `InsightsMetricCategory` that has data, in category order.
    /// Returns `[]` for an empty feed so the screen paints its empty state
    /// instead of a lone "Alle" chip with nothing behind it.
    static func chips(for measurements: [Measurement]) -> [ChronoFilter] {
        guard !measurements.isEmpty else { return [] }

        var hasCore = false
        var categories: Set<InsightsMetricCategory> = []
        for measurement in measurements {
            switch filter(for: measurement.kind) {
            case .core: hasCore = true
            case let .category(category): categories.insert(category)
            case .all: break
            }
        }

        var chips: [ChronoFilter] = [.all]
        if hasCore { chips.append(.core) }
        for category in InsightsMetricCategory.allCases where categories.contains(category) {
            chips.append(.category(category))
        }
        return chips
    }

    /// The time-sorted (newest-first) rows for a given chip selection.
    ///
    /// - `.all` → every row interleaved by time.
    /// - `.core` / `.category` → only rows whose kind maps to that chip.
    /// The sort is a stable newest-first ordering on `recordedAt`, with `id` as
    /// the tie-breaker so equal-timestamp rows keep a deterministic order
    /// (important for tests + a jitter-free list across reloads).
    static func rows(
        _ measurements: [Measurement],
        filter selection: ChronoFilter
    ) -> [Measurement] {
        let scoped: [Measurement] = switch selection {
        case .all:
            measurements
        case .core, .category:
            measurements.filter { filter(for: $0.kind) == selection }
        }
        return scoped.sorted { lhs, rhs in
            if lhs.recordedAt != rhs.recordedAt {
                return lhs.recordedAt > rhs.recordedAt
            }
            return lhs.id > rhs.id
        }
    }

    // MARK: - High-frequency-vital collapse (D1 #34, display-only)

    /// One rendered line in the chronological feed: either a single measurement
    /// (the unchanged default) or a *collapsed* run of consecutive same-minute
    /// high-frequency-vital samples shown as one honest summary row.
    ///
    /// **Display-only, no data loss.** A `.collapsed` entry keeps ALL underlying
    /// `Measurement`s in `samples`; nothing is deleted, deduped, or recomputed on
    /// the server. It exists purely so the operator's Apple-Watch heart-rate
    /// stream (e.g. ~10× "46 bpm" in one minute, RCA-D1) reads as a single
    /// `"46 bpm · 10×"` line instead of ten near-identical rows.
    enum ChronoEntry: Identifiable {
        case single(Measurement)
        /// `samples` are newest-first, ≥2, all same `kind` + same clock-minute,
        /// all a high-frequency vital. `representative` is the newest sample
        /// (drives glyph, kind, timestamp, navigation target).
        case collapsed(representative: Measurement, samples: [Measurement])

        var id: String {
            switch self {
            case let .single(measurement): measurement.id
            // Stable across reloads: the newest sample's id keys the cluster.
            case let .collapsed(representative, _): "collapsed-\(representative.id)"
            }
        }

        /// The measurement that drives glyph / kind / timestamp / tap-target.
        var representative: Measurement {
            switch self {
            case let .single(measurement): measurement
            case let .collapsed(representative, _): representative
            }
        }

        /// Every underlying measurement this entry stands for (1 for `.single`).
        var samples: [Measurement] {
            switch self {
            case let .single(measurement): [measurement]
            case let .collapsed(_, samples): samples
            }
        }

        /// Only a single, user-owned row has one unambiguous canonical editor
        /// target. Collapsed runs stay navigation-only and computed server rows
        /// keep the same read-only contract as the per-kind list.
        var editableMeasurement: Measurement? {
            guard case let .single(measurement) = self,
                  !measurement.isServerDerivedReadOnly else { return nil }
            return measurement
        }
    }

    /// Paint the repository-confirmed edit into the host's cross-kind snapshot
    /// immediately. Matching the original id preserves paired blood-pressure
    /// replacement even if a future server response changes another field.
    static func replacing(
        _ updated: Measurement,
        matching originalID: String,
        in measurements: [Measurement]
    ) -> [Measurement] {
        measurements.map { $0.id == originalID ? updated : $0 }
    }

    /// The chronological feed entries for a chip selection: same newest-first
    /// order as ``rows(_:filter:)``, but with consecutive same-minute
    /// high-frequency-vital samples folded into one ``ChronoEntry/collapsed``
    /// line. Everything else (single rows, low-frequency vitals, manual entries,
    /// BP pairs, meds) passes through verbatim as ``ChronoEntry/single``.
    ///
    /// Collapse rule (must hold for ALL members of a run):
    /// 1. `kind` is a ``MetricKind/isHighFrequencyVital`` (pulse / respiratory /
    ///    SpO₂),
    /// 2. consecutive in the sorted feed,
    /// 3. same `kind`,
    /// 4. same clock-minute (`calendar` minute granularity).
    /// A run of length 1 stays a `.single` (no "·1×" noise).
    static func entries(
        _ measurements: [Measurement],
        filter selection: ChronoFilter,
        calendar: Calendar = .current
    ) -> [ChronoEntry] {
        let sorted = rows(measurements, filter: selection)
        var result: [ChronoEntry] = []
        var index = 0
        while index < sorted.count {
            let head = sorted[index]
            guard head.kind.isHighFrequencyVital else {
                result.append(.single(head))
                index += 1
                continue
            }
            let minute = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: head.recordedAt)
            var run: [Measurement] = [head]
            var lookahead = index + 1
            while lookahead < sorted.count {
                let next = sorted[lookahead]
                guard next.kind == head.kind, next.kind.isHighFrequencyVital else { break }
                let nextMinute = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next.recordedAt)
                guard nextMinute == minute else { break }
                run.append(next)
                lookahead += 1
            }
            if run.count >= 2 {
                result.append(.collapsed(representative: head, samples: run))
            } else {
                result.append(.single(head))
            }
            index = lookahead
        }
        return result
    }

    /// The honest summary string for a collapsed run — value(s) + count.
    /// - All samples share one rounded value → `"46 bpm · 10×"`.
    /// - Values vary → range + count → `"45–48 bpm · 10×"`.
    /// BP never collapses (not a high-frequency vital), so this only ever
    /// formats scalar values. High-frequency vitals (pulse / respiratory / SpO₂)
    /// have no re-unitable family, so the displayed numbers are unit-independent;
    /// `unit` is resolved unit-aware at the call-site for consistency.
    static func collapsedValueLabel(for samples: [Measurement], unit: String) -> String {
        let values = samples.map(\.primaryValue)
        let count = samples.count
        let countLabel = String(localized: "· \(count)×")
        let lo = values.min() ?? 0
        let hi = values.max() ?? 0
        let loRounded = lo.rounded()
        let hiRounded = hi.rounded()
        let unitSuffix = unit.isEmpty ? "" : " \(unit)"
        if loRounded == hiRounded {
            return "\(Int(loRounded))\(unitSuffix) \(countLabel)"
        }
        return "\(Int(loRounded))–\(Int(hiRounded))\(unitSuffix) \(countLabel)"
    }

    /// The display value+unit string for a measurement — the SINGLE formatter
    /// shared by the per-kind drill-down row (`MeasurementListScreen`) and the
    /// chronological feed row, so the two surfaces never disagree on a value.
    ///
    /// **A360-5 C-1.** Routes through `MetricValueFormatter` so the value is
    /// rendered in the user's chosen unit (kg→lb, mmHg→kPa, mg/dL→mmol/L),
    /// exactly like the dashboard tile — not the raw canonical value. List rows
    /// come from the list endpoint, which is canonical for ALL kinds (including
    /// glucose), so `glucose: .canonical`. Default-unit users see the same
    /// numbers as before.
    static func formattedValue(_ measurement: Measurement, units: UnitPreferences) -> String {
        let value = MetricValueFormatter.formattedValue(measurement, units: units)
        let suffix = MetricValueFormatter.unitSuffix(for: measurement.kind, units: units)
        return suffix.isEmpty ? value : "\(value) \(suffix)"
    }
}
