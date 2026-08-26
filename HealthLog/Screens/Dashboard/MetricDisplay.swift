import Foundation

/// Single source of truth for "what does this metric look like right now"
/// across the dashboard cards (`HLDashboardTile` / `MetricsGrid`).
///
/// Computed from the (summary-endpoint `DashboardMetric`) + (unified
/// `MetricDataState` from `DashboardStore.metricStates[kind]`). The state
/// shadows the summary endpoint once it resolves, so every surface gets
/// the SAME empty-vs-ready predicate the chart detail consumes. This is
/// the PB5-review F2 fix: every card now reads the same projection.
///
/// **Rendering contract:**
/// - `.unknown` / `.loading` → fall through to the summary snapshot
///   (`metric.formattedPrimary()`) so cold-launch first-paint still
///   shows a value when the summary said something.
/// - `.empty(.outsideRange(latestAt:))` → "—" with a "Letzte Messung vor
///   X Tagen" secondary line.
/// - `.empty(.sourceFiltered)` → "—" with "Keine Messungen für die
///   gewählte Quelle".
/// - `.empty(.noData)` → "—" with "Noch keine Daten".
/// - `.ready(latest:_)` → format the latest measurement; BP composite
///   short-circuits to "—" when the diastolic peer is missing.
public struct MetricDisplay: Equatable, Sendable {
    public let valueText: String
    public let secondaryLine: String?
    public let isEmptyForDisplay: Bool
    /// Unit-aware suffix for this metric (v0.11 N1). For the re-unitable
    /// families (weight / blood-pressure / glucose) this reflects the user's
    /// chosen unit; otherwise the descriptor's canonical `unitLabel`.
    public let unitSuffix: String

    /// Compose a display projection from the dashboard summary metric +
    /// the unified data-state. Calendar-day math is clamped at 0 so a
    /// clock-skewed future timestamp doesn't render "vor -2 Tagen"
    /// (defensive against HK background-delivery race / manual entry).
    ///
    /// `now` + `calendar` are injectable so tests can fixture a stable
    /// "today" without freezing the real clock. Production call-sites omit
    /// them and pick up `Date.now` + `Calendar.current` — the same values
    /// `cumulativeTodaySum` used pre-HP3, so behaviour is unchanged for
    /// runtime callers.
    public init(
        metric: DashboardMetric,
        dataState: MetricDataState,
        now: Date = .now,
        calendar: Calendar = .current,
        liveTodayStepsOverride: Double? = nil,
        units: UnitPreferences = .standard
    ) {
        let descriptor = metric.kind.descriptor
        unitSuffix = metric.unitSuffix(units: units)

        switch dataState {
        case let .ready(latest, samples):
            // Composite metrics need both components — half-loaded BP would
            // render "124" with no diastolic, contradicting the accessibility
            // label ("noch keine Daten") for the same surface.
            if descriptor.formatStyle == .bloodPressureCompound, metric.secondaryValue == nil {
                valueText = "—"
                secondaryLine = String(localized: "No data yet")
                isEmptyForDisplay = true
                return
            }
            // BP composite happy-path uses the paired value carried inside
            // `MeasurementValue.bloodPressure`; scalar metrics format the
            // primary directly.
            if descriptor.formatStyle == .bloodPressureCompound {
                if case let .bloodPressure(s, d) = latest.value {
                    valueText = MetricDisplay.formatBloodPressure(systolic: s, diastolic: d, units: units)
                } else {
                    valueText = "—"
                }
            } else if metric.kind.isCumulative {
                // **V0.5.4-BF-3.** Cumulative kinds (Steps and any future
                // sum-per-day metric) display today's day-cumulative as the
                // tile value, not the latest single sample. Sums every
                // sample whose `recordedAt` falls inside today's calendar
                // day (user TZ — `Calendar.current`); falls back to the
                // latest sample's primary value when no same-day sample
                // exists so the tile never silently blanks. Pre-BF-3 the
                // tile read `latest.primaryValue` which on a HK setup
                // that emits per-sample step rows landed as the most-
                // recent batch's count, not the day total.
                //
                // **v0.6.2.x bug-c10-ios-direct.** For Steps the server's
                // batch route is insert-only on `(type, stats:<id>:<day>)`,
                // so the day-sum derived from server snapshots is stale
                // after the first sync of the day. When the dashboard
                // supplies a `liveTodayStepsOverride` (read straight from
                // HK), prefer it over the derived sum so the tile reflects
                // the operator's freshly-walked steps. Falls back to the
                // server-derived path when the live read isn't available
                // (no permission, simulator, transient HK error).
                let todaySum = Self.cumulativeTodaySum(samples: samples, now: now, calendar: calendar)
                let liveValue = (metric.kind == .steps) ? liveTodayStepsOverride : nil
                let value = liveValue ?? todaySum ?? latest.primaryValue
                valueText = MetricDisplay.formatScalar(value, kind: metric.kind, style: descriptor.formatStyle, units: units)
                // v0.14.8 AUDIT-HOME M5 — the cumulative value is only stale
                // when BOTH today-paths missed and we fell back to the latest
                // (possibly old) sample; a live HK read or a today-sum is by
                // definition current, so no recency hint then.
                secondaryLine = (liveValue == nil && todaySum == nil)
                    ? Self.recencyLine(latestAt: latest.recordedAt, now: now, calendar: calendar)
                    : nil
                isEmptyForDisplay = false
                return
            } else {
                valueText = MetricDisplay.formatScalar(latest.primaryValue, kind: metric.kind, style: descriptor.formatStyle, units: units)
            }
            // v0.14.8 AUDIT-HOME M5 — fresh-but-old data carries a visible
            // recency hint ("Last measurement X days ago") once the newest
            // sample is ≥ 7 days old. Pre-fix a `.ready` tile with a
            // 3-week-old weight showed the value with zero context.
            secondaryLine = Self.recencyLine(latestAt: latest.recordedAt, now: now, calendar: calendar)
            isEmptyForDisplay = false

        case let .empty(reason):
            valueText = "—"
            isEmptyForDisplay = true
            switch reason {
            case .noData:
                secondaryLine = String(localized: "No data yet")
            case let .outsideRange(latestAt):
                let raw = calendar.dateComponents([.day], from: latestAt, to: now).day ?? 0
                let days = max(0, raw)
                secondaryLine = String(localized: "Last measurement \(days) days ago")
            case .sourceFiltered:
                secondaryLine = String(localized: "No measurements for the selected source")
            }

        case .unknown, .loading:
            // No state resolved yet — defer to the summary snapshot for
            // first paint. Composite-incomplete short-circuits to empty
            // for the same reason as the ready branch above.
            // #33 — a BP snapshot must carry BOTH components AND both > 0 to
            // paint on the cold-launch first frame; otherwise a malformed
            // `0/77` server snapshot would flash before the guarded
            // MetricDataState fan-out resolves the real latest.
            if descriptor.formatStyle == .bloodPressureCompound,
               !metric.hasDisplayableBloodPressureSnapshot
            {
                valueText = "—"
                secondaryLine = String(localized: "No data yet")
                isEmptyForDisplay = true
                return
            }
            // v0.6.2.x bug-c10-ios-direct — Steps tile reads the HK-direct
            // value even before the dashboard fan-out has resolved a per-
            // kind `MetricDataState`. Otherwise the operator sees the
            // (frozen) server snapshot during the ~50-300ms it takes the
            // wide-page derivation to land, even when the live read
            // already has the right number cached.
            if metric.kind == .steps, let liveValue = liveTodayStepsOverride {
                valueText = MetricDisplay.formatScalar(liveValue, kind: metric.kind, style: descriptor.formatStyle, units: units)
                secondaryLine = nil
                isEmptyForDisplay = false
                return
            }
            valueText = metric.formattedPrimary(units: units)
            secondaryLine = nil
            isEmptyForDisplay = metric.latestValue == nil
        }
    }

    /// Mirrors `MetricKindDescriptor.formattedPrimary` for the scalar
    /// formatters. Kept local so callers that hold a `Measurement`
    /// directly (not a `DashboardMetric`) can route through the same
    /// formatter path.
    private static func formatScalar(
        _ latest: Double,
        kind: MetricKind,
        style: MetricKindDescriptor.FormatStyle,
        units: UnitPreferences
    ) -> String {
        // W-CRASHGUARD — `latest` is an unsanitized server / HK-direct scalar;
        // every `Int(...)` below traps on non-finite AND out-of-`Int.range`.
        // Reject non-finite at the gate; route each integer conversion through
        // `Int(safeServer:)` → em-dash on an unrepresentable value.
        guard latest.isFinite else { return "—" }
        // v0.11 N1 — re-unitable families convert at display time. Weight
        // family always renders 1 decimal; glucose is integer for mg/dL and
        // 1 decimal for mmol/L. All other kinds use the descriptor style.
        switch kind.unitFamily {
        case .weight:
            return units.convertWeight(latest).formatted(.number.precision(.fractionLength(1)))
        case .glucose:
            let v = units.convertGlucose(latest)
            return units.glucose == .mgdL
                ? v.safeServerIntString()
                : v.formatted(.number.precision(.fractionLength(1)))
        case .bloodPressure, .none:
            break
        }
        switch style {
        case .integer:
            return latest.safeServerIntString()
        case .decimal1:
            return latest.formatted(.number.precision(.fractionLength(1)))
        case .decimal2:
            return latest.formatted(.number.precision(.fractionLength(0 ... 2)))
        case .bloodPressureCompound:
            // Unreachable for scalar — caller checks `formatStyle` first.
            return latest.safeServerIntString()
        case .durationHM:
            return latest.safeServerSleepDurationHM
        case .groupedInteger:
            return latest.safeServerGroupedIntString
        case .signedDecimal1:
            // W-B189 (#23) — signed deviation (body-temperature deviation).
            return MetricKindDescriptor.formatSignedDecimal1(latest)
        }
    }

    /// v0.11 N1 — formats a `sys/dia` pair in the chosen BP unit. mmHg stays
    /// integer-grained; kPa renders 1 decimal.
    private static func formatBloodPressure(
        systolic s: Double,
        diastolic d: Double,
        units: UnitPreferences
    ) -> String {
        let sysValue = units.convertBloodPressure(s)
        let diaValue = units.convertBloodPressure(d)
        if units.bloodPressure == .mmHg {
            // W-CRASHGUARD — em-dash if either BP operand is non-finite / OOR.
            return Double.safeServerBPString(systolic: sysValue, diastolic: diaValue)
        }
        return "\(sysValue.formatted(.number.precision(.fractionLength(1))))/\(diaValue.formatted(.number.precision(.fractionLength(1))))"
    }

    /// v0.14.8 AUDIT-HOME M5 — staleness threshold (in calendar days) above
    /// which a `.ready` value carries the visible "Last measurement X days
    /// ago" recency hint. Below it the tile stays clean (a value from this
    /// week needs no caveat).
    nonisolated static let recencyHintThresholdDays = 7

    /// v0.14.8 AUDIT-HOME M5 — recency hint for fresh-but-old `.ready`
    /// values. Returns `nil` when the sample is younger than
    /// ``recencyHintThresholdDays``. Day-math is clamped at 0 (clock-skewed
    /// future timestamps must never render "vor -2 Tagen" — same F7 guard as
    /// the `.outsideRange` line). Pure + nonisolated for Swift Testing.
    nonisolated static func recencyLine(
        latestAt: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String? {
        let raw = calendar.dateComponents([.day], from: latestAt, to: now).day ?? 0
        let days = max(0, raw)
        guard days >= recencyHintThresholdDays else { return nil }
        return String(localized: "Last measurement \(days) days ago")
    }

    /// **V0.5.4-BF-3 helper.** Sums every sample whose `recordedAt` falls
    /// inside today's calendar day in the caller's TZ (default
    /// `Calendar.current` — picks up the user's locale TZ from the OS).
    /// Returns `nil` when no sample is from today so the caller can fall
    /// back to a different display (e.g. the latest sample's primary value)
    /// rather than misleadingly rendering "0" when today's HK upload
    /// hasn't landed yet. Pure + nonisolated — pinnable from Swift
    /// Testing without spinning up the dashboard store.
    nonisolated static func cumulativeTodaySum(
        samples: [Measurement],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Double? {
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        let todaySamples = samples.filter { $0.recordedAt >= dayStart && $0.recordedAt < dayEnd }
        guard !todaySamples.isEmpty else { return nil }
        return todaySamples.reduce(0.0) { $0 + $1.primaryValue }
    }
}
