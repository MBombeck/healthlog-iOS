import Foundation
import SwiftUI
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Pure-function helpers backing `MetricChartContent` — covered in isolation so
/// the chart UI doesn't have to be instantiated to verify domain math.
@Suite("MetricChartContent helpers")
struct MetricChartContentHelpersTests {
    private static func point(idx: Int, value: Double) -> SeriesPoint {
        let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(idx) * 86400)
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: nil)
    }

    @Test("personalBaseline returns nil for fewer than 5 readings")
    func belowMinimumSampleSize() {
        let pts = (0 ..< 4).map { Self.point(idx: $0, value: 70.0) }
        #expect(personalBaseline(pts) == nil)
    }

    @Test("personalBaseline equals the median value for odd counts")
    func medianOfOddCounts() {
        // Values 70, 71, 72, 73, 74 → median = 72
        let pts = (0 ..< 5).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        #expect(personalBaseline(pts) == 72.0)
    }

    @Test("personalBaseline averages the two middle values for even counts")
    func medianOfEvenCounts() {
        // Values 70, 71, 72, 73, 74, 75 → median = (72 + 73) / 2 = 72.5
        let pts = (0 ..< 6).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        #expect(personalBaseline(pts) == 72.5)
    }

    @Test("personalBaseline only uses the most recent 90 readings")
    func windowedToLast90() {
        // 95 readings: ascending 0..94. Last 90 are 5..94 → median of those = 49.5
        let pts = (0 ..< 95).map { Self.point(idx: $0, value: Double($0)) }
        let baseline = personalBaseline(pts)
        // 90 values from 5..94 (sorted) → middle two are 49 and 50 → 49.5
        #expect(baseline == 49.5)
    }

    @Test("personalBaseline tolerates unsorted input by sorting internally")
    func unsortedInput() {
        let pts = [
            Self.point(idx: 0, value: 73),
            Self.point(idx: 1, value: 70),
            Self.point(idx: 2, value: 74),
            Self.point(idx: 3, value: 71),
            Self.point(idx: 4, value: 72)
        ]
        #expect(personalBaseline(pts) == 72.0)
    }
}

/// C-10 (2026-05-16) smoke test for the new `emphasisTint:` parameter on
/// `MetricChartContent.marks(...)`. We cannot pixel-snapshot a `ChartContent`
/// builder in a Swift Testing host (Charts require a UI render context), so
/// the strongest available lock is "builds for every MetricKind with and
/// without an emphasis tint" — guarantees the optional parameter signature
/// stays consistent across every per-kind branch.
@Suite("MetricChartContent.marks emphasisTint plumbing")
struct MetricChartContentEmphasisTintTests {
    private static func point(idx: Int, value: Double) -> SeriesPoint {
        let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(idx) * 86400)
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: nil)
    }

    @Test("Every MetricKind builds with the default emphasisTint (nil)")
    func defaultPathBuildsForAllKinds() {
        let pts = (0 ..< 3).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        for kind in MetricKind.allCases {
            // Force the @ChartContentBuilder to run through every case.
            // The static call alone is sufficient — we only need the
            // compiler to enforce the closed-switch contract end-to-end.
            _ = MetricChartContent.marks(for: kind, points: pts)
        }
    }

    @Test("Every MetricKind builds with a non-nil emphasisTint override")
    func explicitTintBuildsForAllKinds() {
        let pts = (0 ..< 3).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        for kind in MetricKind.allCases {
            _ = MetricChartContent.marks(
                for: kind,
                points: pts,
                emphasisTint: Color.orange
            )
        }
    }
}

/// v0.14.1 §1 — Home dashboard tile charts suppress the per-metric clinical
/// threshold / target rules (the red + grey "ideal" lines). The flag defaults
/// to `true` so the Insights detail charts keep their thresholds; the
/// `HLTileMetricChart` path passes `includeThresholds: false`.
@Suite("MetricChartContent.marks includeThresholds plumbing (v0.14.1 §1)")
struct MetricChartContentThresholdSuppressionTests {
    private static func point(idx: Int, value: Double) -> SeriesPoint {
        let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(idx) * 86400)
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: nil)
    }

    @Test("Every MetricKind builds with thresholds suppressed (tile path)")
    func suppressedThresholdsBuildForAllKinds() {
        let pts = (0 ..< 3).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        for kind in MetricKind.allCases {
            _ = MetricChartContent.marks(for: kind, points: pts, includeThresholds: false)
            _ = MetricChartContent.marks(
                for: kind,
                points: pts,
                emphasisTint: HLColor.inkGraphite,
                includeThresholds: false
            )
        }
    }

    /// Structural lock: the tile chart wires `includeThresholds: false`. A
    /// regression that drops the flag would let the red/grey target lines back
    /// onto the Home tiles.
    @Test("HLTileMetricChart passes includeThresholds: false")
    func tileChartSuppressesThresholds() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Charts")
            .appendingPathComponent("HLTileMetricChart.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("includeThresholds: false"),
            "HLTileMetricChart must pass `includeThresholds: false` so Home tiles render the series line only."
        )
    }

    /// The threshold gating happens inside each per-metric struct — every
    /// `ThresholdRule(` and the weight baseline `RuleMark` sit behind an
    /// `if includeThresholds` guard. Lock that the production source guards
    /// them so the tile path actually omits the rules.
    @Test("Threshold + baseline rules are gated behind includeThresholds")
    func rulesAreGatedInSource() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Charts")
            .appendingPathComponent("MetricChartContent.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // The shared param + at least the gate keyword must be present.
        #expect(source.contains("includeThresholds: Bool"))
        #expect(source.contains("if includeThresholds"))
    }
}

/// v0.14.3 §A1/§A2 (FW-HOME) — Home dashboard tile charts render ONE calm,
/// uniform line: no per-measurement dots (`showsPoints: false`) and a fixed
/// `HLChartGrid.tileSeriesWidth` stroke that matches the medication-compliance
/// primitive's quiet graphite. The flags default to the Insights-detail
/// behaviour (`showsPoints: true`, `seriesLineWidth: nil`) so the detail
/// charts stay byte-identical; only the `HLTileMetricChart` path passes the
/// tile values.
@Suite("MetricChartContent.marks tile line-only plumbing (v0.14.3 §A1/§A2)")
struct MetricChartContentTileLineOnlyTests {
    private static func point(idx: Int, value: Double) -> SeriesPoint {
        let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(idx) * 86400)
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: nil)
    }

    private static func metricChartContentSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../HealthLogTests/Screens/
            .deletingLastPathComponent() // .../HealthLogTests/
            .deletingLastPathComponent() // .../<repo-root>/
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Charts")
            .appendingPathComponent("MetricChartContent.swift")
    }

    private static func tileChartSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Charts")
            .appendingPathComponent("HLTileMetricChart.swift")
    }

    /// Every MetricKind builds through the tile path (dots off + fixed width).
    @Test("Every MetricKind builds with showsPoints:false + a fixed line width")
    func tilePathBuildsForAllKinds() {
        let pts = (0 ..< 3).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        for kind in MetricKind.allCases {
            _ = MetricChartContent.marks(
                for: kind,
                points: pts,
                emphasisTint: HLColor.inkGraphite,
                includeThresholds: false,
                showsPoints: false,
                seriesLineWidth: HLChartGrid.tileSeriesWidth
            )
        }
    }

    /// Structural lock: the tile chart wires BOTH tile knobs — `showsPoints:
    /// false` (line-only, no dots) and the unified `HLChartGrid.tileSeriesWidth`
    /// stroke. A regression dropping either lets the intense dots / per-tile
    /// inconsistent line weights back onto the Home tiles.
    @Test("HLTileMetricChart passes showsPoints:false + tileSeriesWidth")
    func tileChartPassesLineOnlyFlags() throws {
        let source = try String(contentsOf: Self.tileChartSourceURL(), encoding: .utf8)
        #expect(
            source.contains("showsPoints: false"),
            "HLTileMetricChart must pass `showsPoints: false` so Home tiles render the series line only (no dots)."
        )
        #expect(
            source.contains("seriesLineWidth: HLChartGrid.tileSeriesWidth"),
            "HLTileMetricChart must pass the unified `HLChartGrid.tileSeriesWidth` so all Home tiles share ONE calm line weight."
        )
    }

    /// The point symbols sit behind the `showsPoints` flag in production source:
    /// BP routes its circle symbol through `hlTileSymbol(showsPoints)` and the
    /// glucose `PointMark` is gated behind `if showsPoints`. Lock the gating so
    /// the tile path actually omits the dots.
    @Test("Point symbols are gated behind showsPoints in source")
    func pointSymbolsGatedInSource() throws {
        let source = try String(contentsOf: Self.metricChartContentSourceURL(), encoding: .utf8)
        #expect(source.contains("showsPoints: Bool"))
        #expect(source.contains("hlTileSymbol(showsPoints)"))
        #expect(source.contains("if showsPoints {"))
    }

    /// The unified tile line width is a single shared token applied via one
    /// `hlSeriesLineWidth(...)` helper on every series LineMark — so all tiles
    /// get the SAME calm weight from ONE source of truth.
    @Test("Series line width routes through the shared hlSeriesLineWidth helper")
    func lineWidthRoutesThroughSharedHelper() throws {
        let source = try String(contentsOf: Self.metricChartContentSourceURL(), encoding: .utf8)
        #expect(source.contains("seriesLineWidth: CGFloat?"))
        #expect(source.contains("hlSeriesLineWidth(lineWidth)"))
    }

    /// v0.14.7 A1 — the unified tile stroke width token equals the EXACT weight
    /// the medication-compliance `HLSparkline` + the Insights detail chart use
    /// (`HLChartStyle.lineWidth`), so every Home tile reads identically to the
    /// compliance line the operator anchored on. (It briefly diverged to 2.1 in
    /// v0.14.6; the felt mismatch was actually the dark-mode tint, not the width.)
    @Test("tileSeriesWidth token matches the compliance/detail line weight")
    func tileSeriesWidthTokenIsCalm() {
        #expect(HLChartGrid.tileSeriesWidth == HLChartStyle.lineWidth)
        #expect(HLChartGrid.tileSeriesWidth == 2.0)
    }
}

/// C-2 (2026-05-16) structural lock: per R2 §C the gradient `AreaMark` was
/// dropped from every metric branch (weight, body_fat, sleep, steps,
/// body_water, bone_mass, plus the dual-line BP and threshold-band metrics
/// that never had one). Because SwiftUI Charts content can't be
/// pixel-snapshotted outside a UI render context — and the per-metric
/// helper structs are `private`, hiding their body trees behind opaque
/// `some ChartContent` returns — the strongest available lock is a
/// **source-text invariant**: the production file `MetricChartContent.swift`
/// must contain zero `AreaMark(` call-sites. Re-adding one will be caught
/// by this test before it ships.
@Suite("MetricChartContent.marks AreaMark removal (C-2)")
struct MetricChartContentNoAreaMarkTests {
    private static func point(idx: Int, value: Double) -> SeriesPoint {
        let at = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(TimeInterval(idx) * 86400)
        return SeriesPoint(id: "p-\(idx)", at: at, value: value, secondary: nil)
    }

    /// Smoke-test that the `@ChartContentBuilder` switch still compiles for
    /// every metric kind after the AreaMark removal — guards against an
    /// accidental case-arm regression. Companion to the source-text
    /// invariant below.
    @Test("Every MetricKind still builds after AreaMark removal")
    func allKindsStillBuild() {
        let pts = (0 ..< 3).map { Self.point(idx: $0, value: 70.0 + Double($0)) }
        for kind in MetricKind.allCases {
            _ = MetricChartContent.marks(for: kind, points: pts)
            _ = MetricChartContent.marks(for: kind, points: pts, emphasisTint: HLColor.inkGraphite)
        }
    }

    /// Hard structural invariant: the production source file contains
    /// **zero** `AreaMark(` call-sites. Doc-comment occurrences of the word
    /// `AreaMark` are explicitly allowed — only the `AreaMark(` constructor
    /// form (with opening paren) is forbidden, matching how the Charts
    /// builder actually emits the mark.
    ///
    /// The source file path is resolved from `#filePath` on the test file
    /// itself, walking up two directory levels (`HealthLogTests/Screens/` →
    /// repo root) and then into `HealthLog/Screens/Charts/`. This is
    /// resilient to derived-data relocation since `#filePath` is captured
    /// at compile-time relative to the active build root.
    @Test("MetricChartContent.swift contains zero AreaMark( call-sites")
    func sourceFileHasNoAreaMarkCalls() throws {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../HealthLogTests/Screens/
            .deletingLastPathComponent() // .../HealthLogTests/
            .deletingLastPathComponent() // .../<repo-root>/
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Charts")
            .appendingPathComponent("MetricChartContent.swift")

        let source = try String(contentsOf: sourceFileURL, encoding: .utf8)

        // Count strict call-site forms: `AreaMark(` opens a constructor call,
        // distinguishing it from the substring `AreaMark` that may legitimately
        // appear inside a doc comment. Both `AreaMark(` and `Charts.AreaMark(`
        // variants are caught by the trailing paren.
        let callSiteCount = source.components(separatedBy: "AreaMark(").count - 1

        #expect(
            callSiteCount == 0,
            "Expected zero `AreaMark(` call-sites in MetricChartContent.swift after C-2; found \(callSiteCount). Path: \(sourceFileURL.path)"
        )
    }
}

/// C-3 (2026-05-16) structural lock: per R2 visual-design-spec §D red was
/// removed from primary metric series. Two surfaces had drift from the
/// canonical "red lives only on threshold overlays" rule:
///
/// 1. `.bodyTemperature` defaulted to `HLColor.statusWarn` (orange) — fixed
///    to `HLColor.pink` per R2 §1.4 / §D.
/// 2. `GlucoseMarks` painted per-point dots via the now-deleted
///    `glucoseSeverityColor(_:)` helper, splashing red on every out-of-range
///    sample. Replaced by uniform `primaryTint` dots over hypo / hyper
///    `statusBad` background bands at 0.16 opacity.
///
/// Like the C-2 suite this leans on source-text invariants because Swift
/// Charts' opaque `some ChartContent` returns hide the per-metric helper
/// bodies from runtime reflection. A future regression that re-adds either
/// the orange default or the severity-coloured dots will be caught here.
@Suite("MetricChartContent red-removal recolor (C-3)")
struct MetricChartContentNoRedOnPrimarySeriesTests {
    private static func sourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../HealthLogTests/Screens/
            .deletingLastPathComponent() // .../HealthLogTests/
            .deletingLastPathComponent() // .../<repo-root>/
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Charts")
            .appendingPathComponent("MetricChartContent.swift")
    }

    /// **T2-3 (2026-05-16) update.** The C-3 spec banned orange (`statusWarn`)
    /// on the body-temperature primary line and routed the default to
    /// `HLColor.pink`. Theme-2.0 Tonal-Mono collapses every primary line
    /// onto the single Dracula-Purple accent — pink dies for the same reason
    /// orange did: it's a per-metric hue and the dashboard now reads as a
    /// single calm material across every metric. Red survives only on
    /// threshold overlays (`HLChartTints.thresholdHigh`, dashed `RuleMark`).
    @Test("bodyTemperature default tint is HLChartTints.series (Tonal-Mono)")
    func bodyTemperatureDefaultIsSingleAccent() throws {
        // v0.14.1 — whitespace-normalised so the assertion survives the FB1
        // (#126) `includeThresholds:` argument that wraps the call across lines.
        // The semantic under test is unchanged: bodyTemperature defaults to
        // `HLChartTints.series`, never `statusWarn` (orange) or `pink`.
        let raw = try String(contentsOf: Self.sourceURL(), encoding: .utf8)
        let source = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        #expect(
            source.contains("BodyTemperatureMarks( points: points, primaryTint: emphasisTint ?? HLChartTints.series"),
            "Expected the .bodyTemperature branch to default to `HLChartTints.series` per Theme-2.0 / T2-3."
        )
        #expect(
            !source.contains("BodyTemperatureMarks( points: points, primaryTint: emphasisTint ?? HLColor.statusWarn"),
            "Expected the .bodyTemperature branch to no longer default to `HLColor.statusWarn` (warning-orange ban from C-3 still holds)."
        )
        #expect(
            !source.contains("BodyTemperatureMarks( points: points, primaryTint: emphasisTint ?? HLColor.pink"),
            "Expected the .bodyTemperature branch to no longer default to `HLColor.pink` — T2-3 collapses every primary line onto `HLChartTints.series`."
        )
    }

    /// The legacy `glucoseSeverityColor(_:)` helper painted red dots for
    /// every hypo/hyper sample. R2 §D moved that semantic onto background
    /// bands; the helper had no other callers and was removed entirely.
    ///
    /// Match the C-2 invariant pattern: look for the call-site form
    /// (`glucoseSeverityColor(`) rather than the bare identifier, so
    /// historical doc-comment mentions of the removed helper don't
    /// false-positive. Both the function-definition `private func
    /// glucoseSeverityColor(_ value:...)` and its single former call-site
    /// `.foregroundStyle(glucoseSeverityColor(point.value))` have the
    /// trailing paren, so this catches both.
    @Test("glucoseSeverityColor helper has been removed (no per-point red on glucose)")
    func glucoseSeverityHelperRemoved() throws {
        let source = try String(contentsOf: Self.sourceURL(), encoding: .utf8)
        let callOrDefCount = source.components(separatedBy: "glucoseSeverityColor(").count - 1
        #expect(
            callOrDefCount == 0,
            """
            Expected zero `glucoseSeverityColor(` call-sites or definitions after C-3; found \(callOrDefCount). \
            Per-point severity colouring on glucose was replaced by uniform tint + statusBad background bands per R2 §D.
            """
        )
    }

    /// **T2-3 (2026-05-16) update.** The C-3 spec moved per-point red onto
    /// solid `RectangleMark` background bands (hypo `< 70`, hyper `> 180`,
    /// target `70..140`). Theme-2.0 Tonal-Mono drops all solid fills — the
    /// two hard clinical boundaries now render as dashed `RuleMark`s using
    /// `HLChartTints.thresholdLow` / `.thresholdHigh`. The 70..140 target
    /// band + the 140..180 borderline band are no longer painted (absence
    /// of any rule conveys "in safe range").
    @Test("Glucose chart paints hypo + hyper as dashed threshold rules")
    func glucoseHasHypoAndHyperThresholdRules() throws {
        let source = try String(contentsOf: Self.sourceURL(), encoding: .utf8)

        // Hypoglycemia boundary at 70 mg/dL: dashed green ThresholdRule.
        #expect(
            source.contains("value: 70,") &&
                source.contains("HLChartTints.thresholdLow"),
            "Expected a hypoglycemia `ThresholdRule` at value 70 using `HLChartTints.thresholdLow`."
        )
        // Hyperglycemia boundary at 180 mg/dL: dashed red ThresholdRule.
        #expect(
            source.contains("value: 180,") &&
                source.contains("HLChartTints.thresholdHigh"),
            "Expected a hyperglycemia `ThresholdRule` at value 180 using `HLChartTints.thresholdHigh`."
        )
        // No solid RectangleMark bands survive the T2-3 sweep.
        let rectangleCallSites = source.components(separatedBy: "RectangleMark(").count - 1
        #expect(
            rectangleCallSites == 0,
            """
            Expected zero `RectangleMark(` call-sites in MetricChartContent.swift after T2-3; \
            found \(rectangleCallSites). All clinical bands now render as dashed `ThresholdRule`s.
            """
        )
    }
}

/// T2-3 (2026-05-16) Theme-2.0 Tonal-Mono structural lock for the
/// chart-color-resolution layer.
///
/// Like the C-2 / C-3 suites we lean on source-text invariants because
/// Swift Charts' opaque `some ChartContent` returns hide the per-metric
/// helper bodies from runtime reflection. A future regression that
/// resurrects per-metric colour routing or solid fills will be caught here
/// before it ships.
///
/// Three invariants are locked:
///
/// 1. **Single-accent collapse.** Every primary `LineMark` default in the
///    `MetricChartContent.marks(...)` switch resolves to
///    `HLChartTints.series`. No `HLColor.metric*` defaults survive.
/// 2. **Zero per-metric hue defaults.** Neither the dropped pink body-temp
///    default, the SpO2 cyan default, the steps green default nor the
///    body-fat orange default appear in the production source.
/// 3. **Per-metric threshold-rule contract.** Each clinical metric carries
///    the exact `ThresholdRule(value:...)` call-sites the design system
///    locks (BP 140/60, pulse 100/60, glucose 70/180, body-temp 37.5,
///    SpO2 95).
@Suite("MetricChartContent Theme-2.0 single-accent collapse (T2-3)")
struct MetricChartContentSingleAccentTests {
    private static func sourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // .../HealthLogTests/Screens/
            .deletingLastPathComponent() // .../HealthLogTests/
            .deletingLastPathComponent() // .../<repo-root>/
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("Charts")
            .appendingPathComponent("MetricChartContent.swift")
    }

    /// Every `marks(for:points:emphasisTint:)` switch-case defaults its
    /// primary tint to `HLChartTints.series`. Pre-T2-3 each case routed
    /// `HLColor.metric*` (or in the bodyFat/bodyTemperature/spo2/etc.
    /// branches, raw `HLColor.orange / .pink / .cyan / .green / .purpleDeep`)
    /// per the C-3 contract. Theme-2.0 collapses every one onto the single
    /// accent.
    @Test("Every MetricKind branch defaults to `HLChartTints.series`")
    func everyKindDefaultsToSingleAccent() throws {
        let source = try String(contentsOf: Self.sourceURL(), encoding: .utf8)

        // The closed switch carries 11 cases (one per `MetricKind`). Each
        // case ends with `emphasisTint ?? HLChartTints.series)` — we count
        // occurrences as a single invariant: ≥ 11 (the diastolic line in
        // `BloodPressureMarks` uses `seriesMid` directly, not via the
        // emphasis-tint nil-coalesce, so the count is the per-kind count).
        let defaultRouteSites = source.components(separatedBy: "emphasisTint ?? HLChartTints.series").count - 1
        #expect(
            defaultRouteSites >= 11,
            """
            Expected ≥ 11 `emphasisTint ?? HLChartTints.series` defaults (one per MetricKind case); \
            found \(defaultRouteSites). T2-3 collapses every primary line onto the single accent.
            """
        )
    }

    /// No per-metric `HLColor.metric*` default survives. T2-1 redefined
    /// these tokens to all resolve to Dracula-Purple (compat shim) but T2-3
    /// must stop *consuming* them at call-sites in chart code.
    @Test("No `HLColor.metric*` defaults remain in MetricChartContent")
    func noPerMetricTokenDefaultsRemain() throws {
        let source = try String(contentsOf: Self.sourceURL(), encoding: .utf8)

        for tokenName in [
            "HLColor.metricBP",
            "HLColor.metricWeight",
            "HLColor.metricPulse",
            "HLColor.metricGlucose",
            "HLColor.metricMood",
            "HLColor.metricMeds",
            "HLColor.metricSleep",
            "HLColor.metricSteps"
        ] {
            #expect(
                !source.contains(tokenName),
                "Expected zero `\(tokenName)` references in MetricChartContent.swift after T2-3; the per-metric routing is gone."
            )
        }
    }

    /// Neither the C-3 body-temperature pink default nor the SpO2 cyan
    /// default nor any other raw-Dracula-hue default survives as a primary
    /// tint. The only legitimate raw-hue use post-T2-3 is inside the
    /// `ThresholdRule` calls (where the tokens `HLChartTints.thresholdHigh`
    /// + `.thresholdLow` route the red/green dashed rules).
    @Test("No raw-Dracula-hue primary tint defaults remain")
    func noRawDraculaHuePrimaryTintsRemain() throws {
        let source = try String(contentsOf: Self.sourceURL(), encoding: .utf8)

        // `emphasisTint ?? HLColor.<hue>` was the C-3-era pattern for the
        // bodyFat / bodyTemperature / spo2 / sleep / bodyWater / boneMass /
        // steps branches. T2-3 replaces all with `HLChartTints.series`.
        for hue in ["HLColor.pink", "HLColor.cyan", "HLColor.orange", "HLColor.green", "HLColor.purpleDeep"] {
            #expect(
                !source.contains("emphasisTint ?? \(hue)"),
                "Expected zero `emphasisTint ?? \(hue)` defaults in MetricChartContent.swift after T2-3."
            )
        }
    }

    /// Lock the exact clinical threshold values per metric. A regression
    /// that quietly shifts the BP systolic threshold from 140 to 130
    /// (or drops the SpO2 95 floor) will be caught here.
    @Test("Each metric's threshold-rule values are clinically locked")
    func thresholdRuleValuesAreLocked() throws {
        let source = try String(contentsOf: Self.sourceURL(), encoding: .utf8)

        // BP: systolic high 140 + diastolic low 60.
        #expect(source.contains("value: 140,"), "BP systolic-high `ThresholdRule` at 140 mmHg missing.")
        // Pulse: tachycardia 100 + bradycardia 60.
        #expect(source.contains("value: 100,"), "Pulse tachycardia `ThresholdRule` at 100 bpm missing.")
        // (60 covers both BP diastolic-low + pulse bradycardia floors.)
        #expect(source.contains("value: 60,"), "Lower-bound `ThresholdRule` at 60 (BP dia + pulse) missing.")
        // Glucose: hypo 70 + hyper 180.
        #expect(source.contains("value: 70,"), "Glucose hypoglycemia `ThresholdRule` at 70 mg/dL missing.")
        #expect(source.contains("value: 180,"), "Glucose hyperglycemia `ThresholdRule` at 180 mg/dL missing.")
        // Body-temp: fever 37.5.
        #expect(source.contains("value: 37.5,"), "Body-temp fever `ThresholdRule` at 37.5°C missing.")
        // SpO2: hypoxemia 95.
        #expect(source.contains("value: 95,"), "SpO2 hypoxemia `ThresholdRule` at 95% missing.")
    }

    /// Every `ThresholdRule` routes its stroke through `HLChartGrid`'s
    /// dash pattern + width so future tweaks propagate to every dashed rule.
    @Test("ThresholdRule stroke style routes through HLChartGrid")
    func thresholdRuleStrokeRoutesThroughGridTokens() throws {
        let source = try String(contentsOf: Self.sourceURL(), encoding: .utf8)
        #expect(
            source.contains("HLChartGrid.thresholdWidth") &&
                source.contains("HLChartGrid.thresholdDash"),
            "Expected `ThresholdRule` to route stroke width + dash pattern through `HLChartGrid`."
        )
    }
}
