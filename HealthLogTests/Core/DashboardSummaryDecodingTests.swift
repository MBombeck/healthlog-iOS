import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks: `latestValue`, `secondaryValue`, `updatedAt` (auf MetricCard) sowie
/// das top-level `lastUpdated` sind alle nullable im Server-Schema. Der erste
/// neue User ohne irgendeine Messung darf den ganzen Dashboard-Decode nicht
/// brechen (W2a-A2 Audit §2.3 + §9.5).
@Suite("DashboardSummary nullable fields")
struct DashboardSummaryDecodingTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractional
        return d
    }()

    @Test("Metric with null latestValue + null updatedAt decodes")
    func metricWithNullLatest() throws {
        let json = Data(#"""
        {
            "id": "m-weight",
            "kind": "weight",
            "title": "Gewicht",
            "latestValue": null,
            "secondaryValue": null,
            "unit": "kg",
            "trend": "unknown",
            "sparkline": [],
            "updatedAt": null
        }
        """#.utf8)
        let metric = try decoder.decode(DashboardMetric.self, from: json)
        #expect(metric.latestValue == nil)
        #expect(metric.updatedAt == nil)
        #expect(metric.displayValue == "—")
    }

    @Test("Metric with present latestValue still decodes + formats")
    func metricWithLatest() throws {
        let json = Data(#"""
        {
            "id": "m-weight",
            "kind": "weight",
            "title": "Gewicht",
            "latestValue": 78.2,
            "secondaryValue": null,
            "unit": "kg",
            "trend": "down",
            "sparkline": [80, 79, 78],
            "updatedAt": "2026-05-14T08:00:00.000Z"
        }
        """#.utf8)
        let metric = try decoder.decode(DashboardMetric.self, from: json)
        #expect(metric.latestValue == 78.2)
        #expect(metric.updatedAt != nil)
        // displayValue uses the system locale's number format; we just lock that
        // a non-nil value isn't the placeholder Em-Dash.
        #expect(metric.displayValue != "—")
        #expect(metric.displayValue.contains("78"))
    }

    @Test("DashboardSummary decodes when all metric fields are null + lastUpdated null")
    func summaryWithNulls() throws {
        let json = Data(#"""
        {
            "greeting": { "salutation": "Hi", "date": "2026-05-14T08:00:00.000Z" },
            "streak": { "currentDays": 0, "longest": 0, "label": "" },
            "compliance": { "scheduledToday": 0, "takenToday": 0 },
            "highlightInsight": null,
            "metrics": [{
                "id": "m1", "kind": "weight", "title": "Gewicht",
                "latestValue": null, "secondaryValue": null,
                "unit": "kg", "trend": "unknown", "sparkline": [],
                "updatedAt": null
            }],
            "lastUpdated": null
        }
        """#.utf8)
        let summary = try decoder.decode(DashboardSummary.self, from: json)
        #expect(summary.metrics.count == 1)
        #expect(summary.lastUpdated == nil)
        #expect(summary.metrics[0].latestValue == nil)
    }

    @Test("Build 7.3 (#51) — summary with mood/bmi tile kinds now DECODES + RENDERS them")
    func summaryRendersMoodAndBmiTiles() throws {
        // The v1.31.0 summary route emits `kind:"mood"` / `kind:"bmi"` tiles.
        // Pre-7.3 the closed `MetricKind` enum modelled neither the `mood` case
        // NOR the short `"bmi"` token (its raw value is `"bodyMassIndex"`), so the
        // tolerant per-element decode DROPPED both tiles. Build 7.3 adds
        // `case mood` and bridges the `"bmi"` alias in `DashboardMetric.init`, so
        // all three tiles now survive the decode + render — order preserved.
        let json = Data(#"""
        {
            "greeting": { "salutation": "Hi", "date": "2026-05-14T08:00:00.000Z" },
            "compliance": { "scheduledToday": 0, "takenToday": 0 },
            "highlightInsight": null,
            "metrics": [
                { "id": "mood1", "kind": "mood", "title": "Stimmung", "latestValue": 4.2, "unit": "", "trend": "up", "sparkline": [3, 4, 4.2] },
                { "id": "w1", "kind": "weight", "title": "Gewicht", "latestValue": 78, "unit": "kg", "trend": "unknown", "sparkline": [] },
                { "id": "bmi1", "kind": "bmi", "title": "BMI", "latestValue": 24.5, "unit": "kg/m²", "trend": "flat", "sparkline": [24, 24.5] }
            ],
            "lastUpdated": null
        }
        """#.utf8)
        let summary = try decoder.decode(DashboardSummary.self, from: json)
        #expect(summary.metrics.count == 3)
        #expect(summary.metrics.map(\.kind) == [.mood, .weight, .bmi])
        // The `"bmi"` short token bridged onto the `.bmi` domain kind whose raw
        // value is `"bodyMassIndex"`.
        #expect(summary.metrics[2].kind.rawValue == "bodyMassIndex")
        #expect(summary.metrics[0].latestValue == 4.2)
    }

    @Test("Build 7.3 — a genuinely unknown tile kind is still dropped, not thrown")
    func summaryStillDropsTrulyUnknownKind() throws {
        // The tolerant `SkipUnknown` wrapper must still drop a kind neither the
        // enum nor the `bmi` alias recognises, WITHOUT rejecting the whole array.
        let json = Data(#"""
        {
            "greeting": { "salutation": "Hi", "date": "2026-05-14T08:00:00.000Z" },
            "compliance": { "scheduledToday": 0, "takenToday": 0 },
            "highlightInsight": null,
            "metrics": [
                { "id": "x1", "kind": "someFutureKind2099", "title": "X", "unit": "", "trend": "unknown", "sparkline": [] },
                { "id": "w1", "kind": "weight", "title": "Gewicht", "unit": "kg", "trend": "unknown", "sparkline": [] }
            ],
            "lastUpdated": null
        }
        """#.utf8)
        let summary = try decoder.decode(DashboardSummary.self, from: json)
        #expect(summary.metrics.count == 1)
        #expect(summary.metrics.first?.kind == .weight)
    }

    @Test("DashboardSummary decodes when streak is missing (R1 removal forward-compat)")
    func summaryWithoutStreak() throws {
        // master-prompt v0.5.0+ R1 — iOS never rendered the 366-day streak; v0.12
        // W4-5 removed the dead `streak` field from the DTO entirely. A payload
        // that omits `streak` must still decode cleanly.
        let json = Data(#"""
        {
            "greeting": { "salutation": "Hi", "date": "2026-05-14T08:00:00.000Z" },
            "compliance": { "scheduledToday": 2, "takenToday": 1 },
            "highlightInsight": null,
            "metrics": [],
            "lastUpdated": null
        }
        """#.utf8)
        let summary = try decoder.decode(DashboardSummary.self, from: json)
        #expect(summary.compliance.scheduledToday == 2)
    }

    @Test("v0.12 W4-5 — server-emitted `streak` is IGNORED, not a decode break")
    func summaryWithStreakIsIgnored() throws {
        // The server still sends a `streak` object for the web client. After the
        // W4-5 removal the iOS DTO has no `streak` field; the synthesized Codable
        // simply skips the unknown key. This must remain a clean decode — the
        // graceful-decode contract the W4-5 brief requires.
        let json = Data(#"""
        {
            "greeting": { "salutation": "Hi", "date": "2026-05-14T08:00:00.000Z" },
            "streak": { "currentDays": 42, "longest": 99, "label": "🔥 42 days" },
            "compliance": { "scheduledToday": 3, "takenToday": 3 },
            "highlightInsight": null,
            "metrics": [],
            "lastUpdated": null
        }
        """#.utf8)
        let summary = try decoder.decode(DashboardSummary.self, from: json)
        #expect(summary.compliance.takenToday == 3)
        #expect(summary.compliance.scheduledToday == 3)
    }

    // MARK: - W-SERVER-SYNC — tolerant titleKey/unitKey decode

    @Test("Metric decodes server v1.5.5 titleKey/unitKey (resolves via catalogue)")
    func metricWithTitleKey() throws {
        // Server v1.5.5 sends i18n keys instead of literals. The decoder reads
        // `titleKey`/`unitKey` and routes them through `String(localized:)`
        // against the bundled `Localizable.xcstrings` — so the resolved value
        // equals the catalogue entry for the active locale, never the raw key.
        let json = Data(#"""
        {
            "id": "m-weight",
            "kind": "weight",
            "titleKey": "dashboard.metric.title.weight",
            "latestValue": 78.2,
            "secondaryValue": null,
            "unitKey": "dashboard.metric.unit.weight",
            "trend": "down",
            "sparkline": [80, 79, 78],
            "updatedAt": null
        }
        """#.utf8)
        let metric = try decoder.decode(DashboardMetric.self, from: json)
        // The key resolved against the catalogue (not passed through verbatim).
        #expect(metric.title == String(localized: "dashboard.metric.title.weight"))
        #expect(metric.title != "dashboard.metric.title.weight")
        #expect(!metric.title.isEmpty)
        #expect(metric.unit == String(localized: "dashboard.metric.unit.weight"))
        #expect(metric.latestValue == 78.2)
    }

    @Test("Metric falls back to legacy title/unit when keys are absent")
    func metricLegacyTitleFallback() throws {
        // Pre-v1.5.5 server shape — no keys, only translated literals. The
        // tolerant decoder must still surface them so a slow server rollout
        // never blanks the dashboard tiles.
        let json = Data(#"""
        {
            "id": "m-weight",
            "kind": "weight",
            "title": "Gewicht",
            "latestValue": 78.2,
            "secondaryValue": null,
            "unit": "kg",
            "trend": "down",
            "sparkline": [],
            "updatedAt": null
        }
        """#.utf8)
        let metric = try decoder.decode(DashboardMetric.self, from: json)
        #expect(metric.title == "Gewicht")
        #expect(metric.unit == "kg")
    }

    @Test("titleKey wins over a stray legacy title when both are present")
    func titleKeyPreferredOverLegacy() throws {
        let json = Data(#"""
        {
            "id": "m-weight",
            "kind": "weight",
            "titleKey": "dashboard.metric.title.weight",
            "title": "Gewicht",
            "latestValue": null,
            "secondaryValue": null,
            "unitKey": "dashboard.metric.unit.weight",
            "unit": "kg",
            "trend": "unknown",
            "sparkline": [],
            "updatedAt": null
        }
        """#.utf8)
        let metric = try decoder.decode(DashboardMetric.self, from: json)
        // titleKey wins: the resolved value is the catalogue entry, NOT the
        // stray legacy "Gewicht" literal (unless the catalogue happens to
        // localize to it). Either way it must equal the key-resolution, not be
        // the raw key.
        #expect(metric.title == String(localized: "dashboard.metric.title.weight"))
        #expect(metric.title != "dashboard.metric.title.weight")
        #expect(metric.unit == String(localized: "dashboard.metric.unit.weight"))
    }

    @Test("resolve() prefers key, falls back to legacy, then empty")
    func resolveContract() {
        // key present → routed through String(localized:) against the catalogue
        // (resolves to a real string, never the raw key, never the legacy arg).
        let resolved = DashboardMetric.resolve(key: "dashboard.metric.title.weight", legacy: "ignored-legacy")
        #expect(resolved == String(localized: "dashboard.metric.title.weight"))
        #expect(resolved != "dashboard.metric.title.weight")
        #expect(resolved != "ignored-legacy")
        // no key → legacy literal.
        #expect(DashboardMetric.resolve(key: nil, legacy: "Gewicht") == "Gewicht")
        #expect(DashboardMetric.resolve(key: "", legacy: "Gewicht") == "Gewicht")
        // neither → empty, never a crash.
        #expect(DashboardMetric.resolve(key: nil, legacy: nil).isEmpty)
    }

    // MARK: - v0.14 / v1.11.5 — sleep dashboard reads the per-night total in HOURS (no ÷60)

    @Test("Sleep dashboard value is read verbatim in hours (server sends per-night total, unit h)")
    func sleepHoursReadVerbatim() throws {
        // v1.11.5 contract: the dashboard summary route emits the per-NIGHT
        // TIME-ASLEEP total ALREADY IN HOURS (float) with an explicit
        // `unit: "h"` (`src/app/api/dashboard/summary/route.ts` —
        // `latestValue: toHours(night.asleepMinutes)`). A real night ≈ 7.2 h.
        // The earlier ÷60 (Task #105) is gone — applying it would have shrunk
        // 7.2 h to 0.12 h ("an empty night"). We read the hours verbatim.
        let json = Data(#"""
        {
            "id": "m-sleep",
            "kind": "sleep",
            "title": "Schlaf",
            "latestValue": 7.2,
            "secondaryValue": null,
            "unit": "h",
            "trend": "up",
            "sparkline": [7.0, 6.5, 5.2],
            "updatedAt": null
        }
        """#.utf8)
        let metric = try decoder.decode(DashboardMetric.self, from: json)
        // Passthrough — NOT 7.2/60 ≈ 0.12.
        #expect(metric.latestValue == 7.2)
        #expect(metric.sparkline == [7.0, 6.5, 5.2])
        // The tile renders via `formattedPrimary()` → `.durationHM`: 7.2 h →
        // "7h 12m". Never "0h 7m" (a stray ÷60) nor "432h" (a stray ×60).
        let rendered = metric.formattedPrimary()
        #expect(rendered.contains("7h"))
        #expect(rendered.contains("12m"))
    }

    @Test("A clean 7.2h sleep night agrees with the list-path night total")
    func sleepNightAgreesWithList() throws {
        // The same night that the `/api/measurements` LIST returns as 432 min
        // (→ 7.2 h via `MeasurementDTO.sleepHours`) the summary returns as 7.2 h
        // directly — so tile, list, series and Insights all show the SAME value.
        let json = Data(#"""
        {
            "id": "m-sleep",
            "kind": "sleep",
            "title": "Schlaf",
            "latestValue": 7.2,
            "secondaryValue": null,
            "unit": "h",
            "trend": "up",
            "sparkline": [],
            "updatedAt": null
        }
        """#.utf8)
        let metric = try decoder.decode(DashboardMetric.self, from: json)
        #expect(metric.latestValue == 7.2)
        let rendered = metric.formattedPrimary()
        #expect(rendered.contains("7h"))
        #expect(rendered.contains("12m"))
    }

    @Test("Non-sleep metrics decode verbatim (regression guard)")
    func nonSleepUntouched() throws {
        let json = Data(#"""
        {
            "id": "m-pulse",
            "kind": "pulse",
            "title": "Puls",
            "latestValue": 62,
            "secondaryValue": null,
            "unit": "bpm",
            "trend": "flat",
            "sparkline": [60, 61, 62],
            "updatedAt": null
        }
        """#.utf8)
        let metric = try decoder.decode(DashboardMetric.self, from: json)
        #expect(metric.latestValue == 62)
        #expect(metric.sparkline == [60, 61, 62])
    }

    @Test("Sleep with null latestValue stays nil")
    func sleepNullLatestValue() throws {
        let json = Data(#"""
        {
            "id": "m-sleep",
            "kind": "sleep",
            "title": "Schlaf",
            "latestValue": null,
            "secondaryValue": null,
            "unit": "h",
            "trend": "unknown",
            "sparkline": [],
            "updatedAt": null
        }
        """#.utf8)
        let metric = try decoder.decode(DashboardMetric.self, from: json)
        #expect(metric.latestValue == nil)
        #expect(metric.formattedPrimary() == "—")
    }

    @Test("Sleep encode→decode round-trip is the identity (SWR cache stability)")
    func sleepRoundTripStable() throws {
        // The SWR cache re-encodes the decoded `DashboardMetric` and decodes it
        // again on the next read. With sleep now a plain passthrough, encode is
        // a straight inverse — the round-trip must preserve the hours value
        // exactly (pre-fix the ×60 re-encode hack only existed to compensate the
        // ÷60; both are gone).
        let json = Data(#"""
        {
            "id": "m-sleep",
            "kind": "sleep",
            "title": "Schlaf",
            "latestValue": 7.2,
            "secondaryValue": null,
            "unit": "h",
            "trend": "flat",
            "sparkline": [7.0, 5.2],
            "updatedAt": null
        }
        """#.utf8)
        let first = try decoder.decode(DashboardMetric.self, from: json)
        #expect(first.latestValue == 7.2)
        let reEncoded = try JSONEncoder().encode(first)
        let second = try decoder.decode(DashboardMetric.self, from: reEncoded)
        #expect(second.latestValue == first.latestValue)
        #expect(second.latestValue == 7.2)
        #expect(second.sparkline == first.sparkline)
    }

    @Test("BP metric formats sys/dia even when both present")
    func bpFormatting() {
        let metric = DashboardMetric(
            id: "m-bp",
            kind: .bloodPressure,
            title: "Blutdruck",
            latestValue: 124,
            secondaryValue: 80,
            unit: "mmHg",
            trend: .flat,
            sparkline: [],
            updatedAt: nil
        )
        #expect(metric.displayValue == "124/80")
    }
}

/// **H1 / SWEEP (AUDIT-bugs b198)** — `latestValue`/`secondaryValue` decode
/// straight from the server without sanitization (`1e400` → `+inf`, a
/// server-side divide → NaN). The BP-compound formatters did `Int(<double>)`,
/// which TRAPS at runtime on a non-finite Double → dashboard crash. These tests
/// assert the formatters render the em-dash placeholder (never trap) for
/// non-finite operands. A trap here would crash the whole test run, so a clean
/// pass IS the guard.
@Suite("DashboardMetric non-finite render guards (H1/sweep)")
struct DashboardMetricNonFiniteGuardTests {
    private func bp(latest: Double, secondary: Double?) -> DashboardMetric {
        DashboardMetric(
            id: "m-bp",
            kind: .bloodPressure,
            title: "Blutdruck",
            latestValue: latest,
            secondaryValue: secondary,
            unit: "mmHg",
            trend: .flat,
            sparkline: [],
            updatedAt: nil
        )
    }

    @Test("displayValue: +inf systolic renders placeholder, no trap")
    func displayValueInfinitePrimary() {
        #expect(bp(latest: .infinity, secondary: 80).displayValue == "—")
    }

    @Test("displayValue: +inf diastolic renders placeholder, no trap")
    func displayValueInfiniteSecondary() {
        #expect(bp(latest: 124, secondary: .infinity).displayValue == "—")
    }

    @Test("displayValue: NaN systolic renders placeholder, no trap")
    func displayValueNaNPrimary() {
        #expect(bp(latest: .nan, secondary: 80).displayValue == "—")
    }

    @Test("formattedPrimary(): +inf BP renders placeholder, no trap")
    func formattedPrimaryInfiniteBP() {
        #expect(bp(latest: .infinity, secondary: .infinity).formattedPrimary() == "—")
    }

    @Test("formattedPrimary(): NaN BP renders placeholder, no trap")
    func formattedPrimaryNaNBP() {
        #expect(bp(latest: .nan, secondary: 80).formattedPrimary() == "—")
    }

    @Test("formattedPrimary(units:): +inf BP renders placeholder, no trap")
    func formattedPrimaryUnitsInfiniteBP() {
        #expect(bp(latest: .infinity, secondary: 80).formattedPrimary(units: .standard) == "—")
    }

    @Test("formattedPrimary(units:): NaN secondary BP renders single value, no trap")
    func formattedPrimaryUnitsNaNSecondary() {
        // latest is finite, secondary is NaN → BP compound's `sec.isFinite`
        // guard drops to the single-value path; must not trap on `Int(...)`.
        let rendered = bp(latest: 124, secondary: .nan).formattedPrimary(units: .standard)
        #expect(rendered == "124")
    }

    @Test("Overflow literal 1e400 is rejected at decode (safety boundary), never reaches render")
    func decodedOverflowIsRejected() {
        // Apple's `JSONDecoder` REJECTS an out-of-Double-range literal with a
        // `DecodingError` ("not representable in Swift") rather than decoding it
        // to `+inf` — so the realistic non-finite source is post-decode
        // arithmetic / a cache round-trip, which the direct-construction tests
        // above cover. This documents the decode boundary: no value, no trap.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractional
        let json = Data(#"""
        {
            "id": "m-bp",
            "kind": "bloodPressure",
            "title": "Blutdruck",
            "latestValue": 1e400,
            "secondaryValue": 80,
            "unit": "mmHg",
            "trend": "flat",
            "sparkline": [],
            "updatedAt": null
        }
        """#.utf8)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(DashboardMetric.self, from: json)
        }
    }
}
