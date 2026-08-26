import Foundation

/// Compliance-Stats für Heatmap.
public struct ComplianceDay: Codable, Sendable, Identifiable {
    public var id: Date {
        date
    }

    public let date: Date
    public let scheduled: Int
    public let taken: Int

    /// **v0.14.x M4 — a no-dose day is NOT 100 % compliant.** Per-day adherence
    /// ratio (0…1). A day with zero scheduled doses returns `0`, not `1`: a
    /// genuine 0/0 day has no adherence to report, and the old `1` inflated
    /// every rolling mean / heatmap aggregate and painted a false 100 % spike
    /// in the compliance sparkline. The fills/status words key off
    /// `scheduled`/`taken` (not `rate`), so 0/0 still renders as the inert
    /// `.none` baseline — only the numeric value changes. Consumers that want a
    /// rolling MEAN must use `scheduledRate` (nil for 0/0) so unscheduled days
    /// are excluded from the denominator, not folded in as zeros.
    public var rate: Double {
        scheduled == 0 ? 0 : Double(taken) / Double(scheduled)
    }

    /// Adherence ratio (0…1) **only when a dose was scheduled**; `nil` for a
    /// 0-scheduled day. Use this — not `rate` — when averaging adherence across
    /// days so unscheduled days are excluded from the rolling mean rather than
    /// dragging it toward 0 (or, pre-M4, inflating it toward 1).
    public var scheduledRate: Double? {
        scheduled == 0 ? nil : Double(taken) / Double(scheduled)
    }
}

/// **v0.6.1.4 Y4.2 — server compliance payload.**
///
/// Mirrors `src/app/api/medications/[id]/compliance/route.ts` 1:1.
/// The server bundles three things into one round-trip:
/// `compliance7`, `compliance30` (both `ComplianceResult`-shaped with
/// totalExpected / taken / skipped / missed / rate / streak) plus the
/// 90-day `dailyCompliance` map keyed by `YYYY-MM-DD`.
///
/// The iOS MedicationCard consumes the headline `rate` integer on
/// each window so the bar percentage agrees with what the web shows.
/// The dailyCompliance map is decoded for forward compatibility but
/// not consumed by the card today; future surfaces (per-day Verlauf
/// strip, in-app analytics) can reach for it without a second
/// request.
public struct MedicationCompliancePayload: Codable, Sendable {
    public let compliance7: ComplianceWindowResult
    public let compliance30: ComplianceWindowResult
    public let dailyCompliance: [String: DailyComplianceBucket]

    /// **v0.14.1 #127 — cadence-scaled two-row card display (server 2026-06-01).**
    ///
    /// The med card's two compliance rows now come from the server's
    /// `complianceDisplay` block whose windows SCALE with cadence: a daily med
    /// reports `shortDays:7 / longDays:30`; a weekly med (Trulicity) steps UP the
    /// window ladder to `shortDays:30 / longDays:90` because a 7-day window holds
    /// <~4 expected weekly doses. That is the "~100-day frame" the operator saw —
    /// intentional, just never relayed. The card renders the two rows from
    /// `short`/`long` using the server-supplied `shortDays`/`longDays` as the
    /// LABELS and reads the server `rate` verbatim (no client recompute — extends
    /// the v0.13 "trust server compliance" directive to the card).
    ///
    /// Optional: nil against a pre-2026-06-01 server / older fixtures, in which
    /// case the card falls back to the fixed 7/30 `compliance7`/`compliance30`.
    public let complianceDisplay: ComplianceDisplay?

    public init(
        compliance7: ComplianceWindowResult,
        compliance30: ComplianceWindowResult,
        dailyCompliance: [String: DailyComplianceBucket] = [:],
        complianceDisplay: ComplianceDisplay? = nil
    ) {
        self.compliance7 = compliance7
        self.compliance30 = compliance30
        self.dailyCompliance = dailyCompliance
        self.complianceDisplay = complianceDisplay
    }

    /// **v0.10 W-Meds-A2 (v1.7.0 SB-SCHED-2) — capability detection by field
    /// presence.** `true` when the server emitted the additive per-day
    /// `due`/`expectedCount` signal on at least one bucket — the marker that
    /// the server's `calculateCompliance` is now cadence-canonical. When this
    /// is `true` the iOS side drops its local `min(scheduleExpected,
    /// serverExpected)` denominator cap + `.noSchedule` short-circuit and
    /// trusts the server's canonical numbers. Against the CURRENT server (no
    /// new fields) this stays `false` and the old behaviour is preserved.
    public var isV170Capable: Bool {
        dailyCompliance.values.contains { $0.due != nil || $0.expectedCount != nil }
    }
}

/// **Build 6.3 — batched card-compliance summary entry.**
///
/// One row of `GET /api/medications/compliance` (server
/// `src/app/api/medications/compliance/route.ts`): the same per-card
/// `compliance7` / `compliance30` / `complianceDisplay` block the per-id route
/// returns, minus the heavy `dailyCompliance` heatmap (the cards render rates /
/// streak / display only). One round trip warms every card instead of the
/// N-request fan-out over `GET /api/medications/{id}/compliance`. The per-medication
/// payload builds and caches through the SAME server cells, so this read and the
/// detail page's per-id read warm each other.
public struct MedicationComplianceSummaryEntry: Codable, Sendable, Equatable, Identifiable {
    public let medicationId: String
    public let compliance7: ComplianceWindowResult
    public let compliance30: ComplianceWindowResult
    public let complianceDisplay: ComplianceDisplay?

    public var id: String {
        medicationId
    }

    public init(
        medicationId: String,
        compliance7: ComplianceWindowResult,
        compliance30: ComplianceWindowResult,
        complianceDisplay: ComplianceDisplay? = nil
    ) {
        self.medicationId = medicationId
        self.compliance7 = compliance7
        self.compliance30 = compliance30
        self.complianceDisplay = complianceDisplay
    }
}

/// **v0.14.1 #127 — server cadence-scaled card display block.**
/// Mirror of the server `complianceDisplay` object: two windows whose spans
/// (`shortDays`/`longDays`) scale with the medication's cadence. The card uses
/// `shortDays`/`longDays` verbatim as the row labels and `short.rate`/`long.rate`
/// as the bar percentages.
public struct ComplianceDisplay: Codable, Sendable, Equatable {
    public let shortDays: Int
    public let longDays: Int
    public let short: ComplianceDisplayWindow
    public let long: ComplianceDisplayWindow

    public init(shortDays: Int, longDays: Int, short: ComplianceDisplayWindow, long: ComplianceDisplayWindow) {
        self.shortDays = shortDays
        self.longDays = longDays
        self.short = short
        self.long = long
    }
}

/// One window of `complianceDisplay`. `rate` is the server's rounded 0-100
/// integer (same scale as `ComplianceWindowResult.rate`). `taken`/`expected`
/// decoded for completeness; `expected` is `Double` because a weekly med's
/// expected-dose count over the window can be fractional.
///
/// **v0.14.2 M5 — `streak`.** The server emits `{rate, streak}` on the SHORT
/// window (`docs/api/openapi.yaml`, server `buildComplianceDisplay` — `short:
/// { rate, streak }`); the long window carries only `rate`. Decoding it here
/// (optional, so the long window + older servers stay valid) lets the card
/// surface the server-computed short-window day-streak the web shows. `rate`
/// still drives the bar; `streak` is additive.
public struct ComplianceDisplayWindow: Codable, Sendable, Equatable {
    public let rate: Int
    public let taken: Int?
    public let expected: Double?
    /// Server-computed consecutive-day streak (short window only; `nil` on the
    /// long window + against pre-streak servers). Previously decoded-away.
    public let streak: Int?

    public init(rate: Int, taken: Int? = nil, expected: Double? = nil, streak: Int? = nil) {
        self.rate = rate
        self.taken = taken
        self.expected = expected
        self.streak = streak
    }
}

/// Mirror of the server's `ComplianceResult` interface
/// (`src/lib/analytics/compliance.ts:23-30`). `rate` is the
/// `Math.round(taken / totalExpected × 100)` integer (0-100) the card
/// renders next to each compliance bar.
public struct ComplianceWindowResult: Codable, Sendable, Equatable {
    public let totalExpected: Int
    public let taken: Int
    public let skipped: Int
    public let missed: Int
    public let rate: Int
    public let streak: Int

    public init(totalExpected: Int, taken: Int, skipped: Int, missed: Int, rate: Int, streak: Int) {
        self.totalExpected = totalExpected
        self.taken = taken
        self.skipped = skipped
        self.missed = missed
        self.rate = rate
        self.streak = streak
    }
}

/// Mirror of the server's `DailyComplianceEntry` interface
/// (`src/lib/analytics/compliance.ts:39-47`). `early` is optional
/// because the server only started emitting it in v1.4.34; older
/// rows omit the field.
public struct DailyComplianceBucket: Codable, Sendable, Equatable {
    public let expected: Int
    public let taken: Int
    public let skipped: Int
    public let onTime: Int
    public let late: Int
    public let veryLate: Int
    public let early: Int?

    // MARK: - v1.7.0 SB-SCHED-2 additive per-day signal (W-Meds-A2)

    /// **`due` (LOCKED).** Whether a dose was actually due on this day per the
    /// server's canonical recurrence engine. iOS reads `due == false` to
    /// suppress empty history marks on non-due days. Optional / nil against the
    /// current server (the capability gate keys off its presence).
    public let due: Bool?
    /// **`expectedCount` (LOCKED).** Per-day expected dose count from the
    /// server's canonical engine. Same suppression signal as `due`
    /// (`expectedCount == 0` ⇒ non-due day). Optional / nil against the current
    /// server.
    public let expectedCount: Int?

    public init(
        expected: Int,
        taken: Int,
        skipped: Int,
        onTime: Int,
        late: Int,
        veryLate: Int,
        early: Int? = nil,
        due: Bool? = nil,
        expectedCount: Int? = nil
    ) {
        self.expected = expected
        self.taken = taken
        self.skipped = skipped
        self.onTime = onTime
        self.late = late
        self.veryLate = veryLate
        self.early = early
        self.due = due
        self.expectedCount = expectedCount
    }

    /// **v0.10 W-Meds-A2 — canonical "was a dose due this day?" predicate.**
    /// Prefers the v1.7.0 `due`/`expectedCount` signal; falls back to the
    /// legacy `expected > 0` when the server hasn't shipped the field yet.
    public var wasDue: Bool {
        if let due { return due }
        if let expectedCount { return expectedCount > 0 }
        return expected > 0
    }
}
