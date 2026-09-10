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
    /// - `recentMoodScore` is non-nil only when the day carries a mood the
    ///   build can name (the watch's mood page shows "logged" vs. its prompt).
    ///   `recentMoods` is the loaded mood window, not one pre-picked entry:
    ///   picking is this builder's job, and it is the one-slot rule the Home
    ///   widget applies (``MoodEntry/latestNameable(_:)``).
    static func make(
        medications: [Medication],
        derivedIntakes: [MedicationIntake],
        recentMoods: [MoodEntry],
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

        // Audit B-4 (fix round 1) — the same one-slot rule as the widget, which
        // the old comment claimed and the old code did not obey: the latest
        // entry OF TODAY whose level this build can name. Reading only the
        // newest row let a single unnameable entry blank a complication whose
        // real reading was an hour older and still on the mood screen. `nil`
        // stays the honest "no mood logged today" — the rule reaches past the
        // sentinel, it never reaches past midnight and never invents a middle.
        let recentMoodScore: Int? = MoodEntry.latestNameable(
            recentMoods.filter { calendar.isDate($0.recordedAt, inSameDayAs: now) }
        )?.score

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
    /// Bridge to the app's `IntakeStatus`. Exhaustive on purpose (Audit B-5):
    /// the former `IntakeStatus(rawValue:) ?? .taken` could not fire while the
    /// two enums agreed, but the day a Watch status is added that the phone's
    /// enum lacks, a coalesce to `.taken` would count a dose nobody took. The
    /// compiler now asks for the arm instead.
    var intakeStatus: IntakeStatus {
        switch self {
        case .taken: .taken
        case .skipped: .skipped
        case .snoozed: .snoozed
        }
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
