import Foundation

/// **v0.8.4 WWIDGET-2 — pure medications/intakes → `WidgetSnapshot` map.**
///
/// Deterministic given `(medications, derivedIntakes, now, calendar)` so
/// the widget snapshot stays unit-testable without a store or network. The
/// app's `WidgetSnapshotWriter` calls this with the live store's
/// `derivedTodayIntakes` (server-emitted unioned with synthesised
/// placeholders); the timeline-mapping tests call it with fixtures.
///
/// Shared by both targets (Foundation-only). The next dose reuses the same
/// ``MedicationLiveActivityPlan/doseToSurface`` decision that drives the
/// Live Activity, so the dose the banner shows and the dose the widget
/// shows agree.
///
/// **Why `derivedIntakes`, not the raw server intakes:** the derive step
/// (`MedicationsStore.deriveTodayIntakes`) lives on the app-only store
/// type and can't compile in the extension. The caller (app) does the
/// derivation once and hands the result here, keeping this mapper
/// dependency-free and shareable.
public extension WidgetSnapshot {
    /// Build a snapshot from the medication universe + the already-derived
    /// today's-intakes the app renders.
    ///
    /// - `nextDose` reuses ``MedicationLiveActivityPlan/doseToSurface`` so
    ///   the widget surfaces exactly the dose the Live Activity would —
    ///   soonest due / currently-overdue, active + notifications-on,
    ///   not yet taken/skipped.
    /// - `compliance` carries TWO things: the today-count (`scheduled`/`taken`
    ///   from the passed `derivedIntakes` — the literal "x/y doses" centre
    ///   label, matching the in-app today rows) PLUS the SERVER ledger
    ///   adherence percentage (`serverCompliancePercent`, the same value the
    ///   in-app card/`LedgerHistorySection` paint), which the ring ARC tracks
    ///   so the widget never recomputes a parallel adherence number. The caller
    ///   (`WidgetSnapshotWriter`/`AppContainer+Widgets`) supplies the server
    ///   percent from the store's `complianceCardSnapshots`; `nil` when that
    ///   value hasn't loaded (cold/offline) → the ring falls back to the
    ///   today-count fraction.
    /// - `timeFormatRaw` is the app's resolved `HLTimeFormat` raw value so the
    ///   widget renders dose times with the SAME clock the app does.
    static func make(
        medications: [Medication],
        derivedIntakes: [MedicationIntake],
        serverCompliancePercent: Int? = nil,
        recentMood: RecentMood? = nil,
        timeFormatRaw: String = "AUTO",
        now: Date = .now,
        calendar: Calendar = .current
    ) -> WidgetSnapshot {
        let scheduled = derivedIntakes.count
        let taken = derivedIntakes.filter { $0.status == .taken }.count

        let dose = MedicationLiveActivityPlan.doseToSurface(
            medications: medications,
            intakes: derivedIntakes,
            now: now,
            calendar: calendar
        )

        return WidgetSnapshot(
            nextDose: dose.map { activity in
                NextDose(
                    medicationId: activity.medicationId,
                    medicationName: activity.medicationName,
                    doseText: activity.doseText,
                    scheduledAt: activity.scheduledFireDate
                )
            },
            compliance: ComplianceSummary(
                scheduled: scheduled,
                taken: taken,
                serverCompliancePercent: serverCompliancePercent
            ),
            recentMood: recentMood,
            timeFormatRaw: timeFormatRaw,
            generatedAt: now
        )
    }
}

// MARK: - v0.15 companion-#3 — latest-measurement glance

public extension WidgetSnapshot.LatestMeasurement {
    /// Build the latest-measurement glance from a domain `Measurement`,
    /// formatting the value EXACTLY like the in-app dashboard tile does (same
    /// `MetricKindDescriptor` format-style routing + the user's unit
    /// preference) so the widget shows the SAME string the app surfaces. The
    /// title + SF Symbol resolve through the shared descriptor catalog (compiled
    /// into the widget target via `HealthLog/Models`). `nil` in → `nil` glance.
    static func make(
        from measurement: Measurement?,
        units: UnitPreferences = .standard
    ) -> WidgetSnapshot.LatestMeasurement? {
        guard let measurement else { return nil }
        let descriptor = measurement.kind.descriptor
        return WidgetSnapshot.LatestMeasurement(
            kindRaw: measurement.kind.rawValue,
            title: String(localized: descriptor.title),
            formattedValue: formattedValue(for: measurement, units: units),
            unit: unitSuffix(for: measurement.kind, units: units),
            symbol: descriptor.sfSymbol,
            recordedAt: measurement.recordedAt
        )
    }

    /// The unit-aware suffix for a kind (mirrors `DashboardMetric.unitSuffix`):
    /// the user-chosen suffix for the three re-unitable families, else the
    /// descriptor's canonical unit label.
    private static func unitSuffix(for kind: MetricKind, units: UnitPreferences) -> String {
        switch kind.unitFamily {
        case .weight: units.weight.unitSuffix
        case .bloodPressure: units.bloodPressure.unitSuffix
        case .glucose: units.glucose.unitSuffix
        case .none: String(localized: kind.descriptor.unitLabel)
        }
    }

    /// Unit-aware primary value string, mirroring `DashboardMetric.formatted
    /// Primary(units:)` for the re-unitable families and the descriptor
    /// `FormatStyle` routing for everything else — so the widget renders the
    /// SAME string the tile does. Non-finite guards mirror the tile's gates.
    private static func formattedValue(for measurement: Measurement, units: UnitPreferences) -> String {
        let kind = measurement.kind
        switch kind.unitFamily {
        case .weight:
            let v = units.convertWeight(measurement.primaryValue)
            guard v.isFinite else { return "—" }
            return v.formatted(.number.precision(.fractionLength(1)))
        case .glucose:
            let v = units.convertGlucose(measurement.primaryValue)
            // W-CRASHGUARD — `safeServerIntString` em-dashes a non-finite / OOR value.
            guard units.glucose != .mgdL else { return v.safeServerIntString() }
            guard v.isFinite else { return "—" }
            return v.formatted(.number.precision(.fractionLength(1)))
        case .bloodPressure:
            guard case let .bloodPressure(sys, dia) = measurement.value, sys.isFinite, dia.isFinite else {
                let v = units.convertBloodPressure(measurement.primaryValue)
                guard units.bloodPressure != .mmHg else { return v.safeServerIntString() }
                guard v.isFinite else { return "—" }
                return v.formatted(.number.precision(.fractionLength(1)))
            }
            let sValue = units.convertBloodPressure(sys)
            let dValue = units.convertBloodPressure(dia)
            guard units.bloodPressure != .mmHg else {
                return Double.safeServerBPString(systolic: sValue, diastolic: dValue)
            }
            return "\(sValue.formatted(.number.precision(.fractionLength(1))))/\(dValue.formatted(.number.precision(.fractionLength(1))))"
        case .none:
            return formattedByStyle(measurement.primaryValue, style: kind.descriptor.formatStyle)
        }
    }

    /// Descriptor-`FormatStyle` routing for non-re-unitable kinds — a verbatim
    /// mirror of `DashboardMetric.formattedPrimary()` for a single scalar.
    private static func formattedByStyle(_ value: Double, style: MetricKindDescriptor.FormatStyle) -> String {
        // W-CRASHGUARD — reject non-finite at the gate; route every integer
        // conversion through `Int(safeServer:)` so a finite-but-out-of-range
        // value em-dashes instead of trapping.
        guard value.isFinite else { return "—" }
        switch style {
        case .integer:
            return value.safeServerIntString()
        case .decimal1:
            return value.formatted(.number.precision(.fractionLength(1)))
        case .decimal2:
            return value.formatted(.number.precision(.fractionLength(0 ... 2)))
        case .bloodPressureCompound:
            return value.safeServerIntString()
        case .durationHM:
            return value.safeServerSleepDurationHM
        case .groupedInteger:
            return value.safeServerGroupedIntString
        case .signedDecimal1:
            return MetricKindDescriptor.formatSignedDecimal1(value)
        }
    }
}

// MARK: - v0.15 companion-#3 — Personal Health Score glance

public extension WidgetSnapshot.HealthScoreGlance {
    /// Build the score glance from the server `HealthScore`. Mirrors the value +
    /// the server-authoritative `displayBand` (the same band the in-app Dashboard
    /// tile + Insights surfaces colour the score by) verbatim — never recomputes
    /// the number. `nil` in → `nil` glance (no score loaded yet).
    static func make(from score: HealthScore?, now: Date = .now) -> WidgetSnapshot.HealthScoreGlance? {
        guard let score else { return nil }
        return WidgetSnapshot.HealthScoreGlance(
            score: score.score,
            band: score.displayBand.rawValue,
            resolvedAt: now,
            // v1.35.0 (GH #83) — mirrored, never derived. A missing flag on the
            // wire means the server did not say, and an untold flag must not
            // travel into the widget as a claim about the account.
            configured: score.runsOnChosenComposition
        )
    }
}
