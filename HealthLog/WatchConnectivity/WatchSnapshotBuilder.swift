import Foundation

// MARK: - Phone-side WatchSnapshot builder

//
// **v0.12 P2 — watchOS companion.** Pure map from the app's medication
// universe + already-derived today's-intakes (the same
// `MedicationsStore.derivedTodayIntakes` the widgets read) onto the
// thin `WatchSnapshot` the phone pushes to the watch. References the app
// `Models` types, so it lives in the app target only — `WatchPayload.swift`
// (shared with the watch) stays Models-free.
//
// Deterministic given its inputs, so it's unit-testable without a store or
// network (mirrors `WidgetSnapshotMapping`).

extension WatchSnapshot {
    /// Build the watch snapshot from the medication list + today's derived
    /// intakes + the latest mood + sign-in state.
    ///
    /// - `doses` carries today's intakes mapped to their medication's name
    ///   / dose text, soonest-first, each tagged taken / actionable /
    ///   injection. The `id` is the derived intake id (real or
    ///   `synth:`-prefixed) so the watch echoes it back into
    ///   `WatchAction.markIntake` and the phone routes through
    ///   `MedicationsStore.markIntakeQuick` (the clamped quick-mark path).
    /// - `recentMoodScore` is non-nil only when the latest mood was logged
    ///   *today* (the watch's mood page shows "logged" vs. its prompt).
    static func make(
        medications: [Medication],
        derivedIntakes: [MedicationIntake],
        latestMood: MoodEntry?,
        moodCountToday: Int = 0,
        signedIn: Bool,
        healthScore: WatchSnapshot.HealthScoreGlance? = nil,
        latestMeasurement: WatchSnapshot.LatestMeasurement? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> WatchSnapshot {
        let medsByID = Dictionary(
            medications.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let doses: [Dose] = derivedIntakes
            .sorted { $0.scheduledAt < $1.scheduledAt }
            .map { intake in
                let med = medsByID[intake.medicationId]
                return Dose(
                    id: intake.id,
                    medicationName: med?.name ?? "",
                    doseText: med?.dose ?? "",
                    scheduledAt: intake.scheduledAt,
                    isTaken: intake.status == .taken,
                    // Actionable = anything not yet resolved as taken/skipped
                    // (pending, overdue, snoozed) — the rows the watch acts on.
                    isActionable: intake.status != .taken && intake.status != .skipped,
                    isInjection: med?.trackInjectionSites == true
                )
            }

        let scheduled = derivedIntakes.count
        let taken = derivedIntakes.filter { $0.status == .taken }.count

        let recentMoodScore: Int? = {
            guard let latestMood,
                  calendar.isDate(latestMood.recordedAt, inSameDayAs: now) else { return nil }
            return latestMood.score
        }()

        return WatchSnapshot(
            doses: doses,
            scheduledCount: scheduled,
            takenCount: taken,
            recentMoodScore: recentMoodScore,
            moodCountToday: max(0, moodCountToday),
            signedIn: signedIn,
            healthScore: healthScore,
            latestMeasurement: latestMeasurement,
            generatedAt: now
        )
    }
}

// MARK: - v0.15.2 W-WATCH-COMPLICATIONS — glance builders (app-only; reference Models)

extension WatchSnapshot.HealthScoreGlance {
    /// Build the watch score glance from the server `HealthScore`. Mirrors the
    /// value + the server-authoritative `displayBand` verbatim — never recomputes
    /// the number (server-first). `nil` in → `nil` glance.
    static func make(from score: HealthScore?) -> WatchSnapshot.HealthScoreGlance? {
        guard let score else { return nil }
        return WatchSnapshot.HealthScoreGlance(
            score: score.score,
            band: score.displayBand.rawValue
        )
    }
}

extension WatchSnapshot.LatestMeasurement {
    /// Build the watch latest-measurement glance from a domain `Measurement`,
    /// formatting `value` EXACTLY like the iOS widget's
    /// `WidgetSnapshot.LatestMeasurement` (which mirrors the dashboard tile) so
    /// the watch shows the SAME string. Reuses the iOS glance builder and copies
    /// its fields across — one formatting path, no drift. `nil` in → `nil` glance.
    static func make(
        from measurement: Measurement?,
        units: UnitPreferences = .standard
    ) -> WatchSnapshot.LatestMeasurement? {
        guard let widgetGlance = WidgetSnapshot.LatestMeasurement.make(from: measurement, units: units) else {
            return nil
        }
        return WatchSnapshot.LatestMeasurement(
            kindRaw: widgetGlance.kindRaw,
            title: widgetGlance.title,
            formattedValue: widgetGlance.formattedValue,
            unit: widgetGlance.unit,
            symbol: widgetGlance.symbol,
            recordedAt: widgetGlance.recordedAt
        )
    }
}

extension WatchIntakeStatus {
    /// Bridge to the app's `IntakeStatus` (rawValues are bit-identical).
    var intakeStatus: IntakeStatus {
        IntakeStatus(rawValue: rawValue) ?? .taken
    }
}

extension WatchMeasurementKind {
    /// Bridge to the app's `MetricKind` (rawValues are bit-identical for the
    /// four quick-capture kinds).
    var metricKind: MetricKind {
        MetricKind(rawValue: rawValue) ?? .weight
    }

    /// Build the canonical `MeasurementValue` for this kind from the wrist's
    /// primary scalar + optional BP diastolic. Blood pressure folds the pair
    /// into the `.bloodPressure` case; every other kind is a `.scalar`.
    func measurementValue(value: Double, secondary: Double?) -> MeasurementValue {
        switch self {
        case .bloodPressure:
            .bloodPressure(systolic: value, diastolic: secondary ?? 0)
        case .weight, .glucose, .pulse:
            .scalar(value)
        }
    }
}

extension MedicationsStore.WriteOutcome {
    /// WW/F2 — map the store's tri-state write outcome onto the thin
    /// ``WatchAckOutcome`` the phone sends back to the watch:
    /// `.success` → `saved` (landed), `.queued` → `queued` (durably in the
    /// Outbox, will sync), `.failed` → `failed` (nothing landed).
    var watchAckOutcome: WatchAckOutcome {
        switch self {
        case .success: .saved
        case .queued: .queued
        case .failed: .failed
        }
    }
}
