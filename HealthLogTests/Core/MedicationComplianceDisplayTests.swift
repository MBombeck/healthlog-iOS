import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **v0.14.1 #127 — cadence-scaled `complianceDisplay` card rows.**
///
/// Locks the server 2026-06-01 contract: the med card's two compliance rows come
/// from `complianceDisplay.short`/`.long` whose windows scale with cadence (daily
/// med → 7/30, weekly med like Trulicity → 30/90). The card reads the server rate
/// verbatim (no client recompute) and uses `shortDays`/`longDays` as the labels.
@Suite("Medication complianceDisplay (cadence-scaled card rows)")
struct MedicationComplianceDisplayTests {
    @Test("complianceDisplay (weekly med) decodes → 30/90 display rows")
    func complianceDisplayWeeklyCadence() throws {
        let json = Data(#"""
        {
            "compliance7": { "totalExpected": 1, "taken": 1, "skipped": 0, "missed": 0, "rate": 100, "streak": 1 },
            "compliance30": { "totalExpected": 4, "taken": 4, "skipped": 0, "missed": 0, "rate": 100, "streak": 4 },
            "dailyCompliance": {},
            "complianceDisplay": {
                "shortDays": 30, "longDays": 90,
                "short": { "rate": 100, "taken": 4, "expected": 4.3 },
                "long":  { "rate": 92,  "taken": 12, "expected": 13.0 }
            }
        }
        """#.utf8)
        let payload = try JSONDecoder().decode(MedicationCompliancePayload.self, from: json)
        let display = try #require(payload.complianceDisplay)
        #expect(display.shortDays == 30)
        #expect(display.longDays == 90)
        #expect(display.short.rate == 100)
        #expect(display.long.rate == 92)
        #expect(display.short.expected == 4.3)

        let snapshot = MedicationsStore.ComplianceCardSnapshot(
            rate7: payload.compliance7.rate,
            rate30: payload.compliance30.rate,
            displayShortDays: display.shortDays,
            displayShortRate: display.short.rate,
            displayLongDays: display.longDays,
            displayLongRate: display.long.rate
        )
        // Card renders the server cadence-scaled windows, not the fixed 7/30.
        #expect(snapshot.displayRows.map(\.days) == [30, 90])
        #expect(snapshot.displayRows.map(\.rate) == [100, 92])
    }

    @Test("complianceDisplay absent → card falls back to fixed 7/30 rows")
    func complianceDisplayAbsentFallback() throws {
        let json = Data(#"""
        {
            "compliance7": { "totalExpected": 7, "taken": 6, "skipped": 0, "missed": 1, "rate": 86, "streak": 0 },
            "compliance30": { "totalExpected": 30, "taken": 28, "skipped": 0, "missed": 2, "rate": 93, "streak": 0 },
            "dailyCompliance": {}
        }
        """#.utf8)
        let payload = try JSONDecoder().decode(MedicationCompliancePayload.self, from: json)
        #expect(payload.complianceDisplay == nil)
        let snapshot = MedicationsStore.ComplianceCardSnapshot(
            rate7: payload.compliance7.rate,
            rate30: payload.compliance30.rate,
            displayShortDays: payload.complianceDisplay?.shortDays,
            displayShortRate: payload.complianceDisplay?.short.rate,
            displayLongDays: payload.complianceDisplay?.longDays,
            displayLongRate: payload.complianceDisplay?.long.rate
        )
        #expect(snapshot.displayRows.map(\.days) == [7, 30])
        #expect(snapshot.displayRows.map(\.rate) == [86, 93])
    }

    @Test("PRN med (no windows) → no display rows")
    func complianceDisplayPRNNoRows() {
        let snapshot = MedicationsStore.ComplianceCardSnapshot(rate7: nil, rate30: nil)
        #expect(snapshot.displayRows.isEmpty)
    }

    /// **v0.14.2 M5 — short-window streak decode.** The server emits
    /// `{rate, streak}` on `complianceDisplay.short`; the field was previously
    /// decoded-away. It must now survive the round-trip (and stay `nil` on the
    /// long window, which carries only `rate`).
    @Test("complianceDisplay.short.streak decodes; long.streak stays nil")
    func shortStreakDecodes() throws {
        let json = Data(#"""
        {
            "compliance7": { "totalExpected": 1, "taken": 1, "skipped": 0, "missed": 0, "rate": 100, "streak": 1 },
            "compliance30": { "totalExpected": 4, "taken": 4, "skipped": 0, "missed": 0, "rate": 100, "streak": 4 },
            "dailyCompliance": {},
            "complianceDisplay": {
                "shortDays": 30, "longDays": 90,
                "short": { "rate": 100, "streak": 9 },
                "long":  { "rate": 92 }
            }
        }
        """#.utf8)
        let payload = try JSONDecoder().decode(MedicationCompliancePayload.self, from: json)
        let display = try #require(payload.complianceDisplay)
        #expect(display.short.streak == 9)
        #expect(display.long.streak == nil)
    }
}
