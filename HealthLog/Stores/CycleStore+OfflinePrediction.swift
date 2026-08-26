import Foundation

/// **The offline / degraded prediction path of ``CycleStore``.**
///
/// Split out of `CycleStore.swift` under the repo's file-length discipline
/// (CU-25 / #72). Pure movement plus the ``CycleStore/publishOfflinePrediction``
/// seam, which exists so this extension can hand its result back without
/// relaxing `private(set)` on the store's properties.
///
/// **Role.** The server DTO is canonical. This path runs ONLY when the server is
/// unreachable or returned no prediction, and everything it produces is labelled
/// ``CyclePredictionProvenance/onDevice`` so the screen can say where the number
/// came from. `CyclePredictionPinTests` holds the engine against a fixture
/// recorded from the server's own engine, so the two cannot drift apart quietly.
///
/// **Z1 (#72) — this path FORECASTS, it does not JUDGE.** Dates, bands and the
/// expected next start are fair game on the device. `state`, `phase` and
/// `overdueDays` are not, and never reach this file: they come from the server
/// or from the last thing the server said (`CycleStore+Verdict.swift`). The
/// server resolves "today" from the profile timezone, which an offline device
/// does not necessarily hold — off by a day in a forecast is a rounding error,
/// off by a day in "overdue" is a false statement about a person's body.
extension CycleStore {
    /// Compute the on-device prediction from the cached cycle history. Pure +
    /// deterministic — the 1:1 offline mirror of the server engine.
    ///
    /// CU-25 (#72): the result is now bridged into ``CycleStore/prediction`` and
    /// labelled. Before that this method wrote only `offlinePrediction`, which
    /// no surface read — the documented offline fallback existed in name only
    /// and the screen silently fell back to "still learning".
    public func computeOfflinePrediction(today: String = CycleCalendarWindow.todayKey()) async {
        let inputs = cycles
            .filter { !$0.isPredicted }
            .map { CyclePredictionEngine.CycleInput(
                startDate: $0.startDate,
                endDate: $0.endDate,
                periodEndDate: $0.periodEndDate,
                ovulationDate: $0.ovulationDate,
                ovulationConfirmed: $0.ovulationConfirmed
            ) }
        guard !inputs.isEmpty else {
            publishOfflinePrediction(nil, dto: prediction, provenance: predictionProvenance)
            return
        }
        let profileInput = CyclePredictionEngine.CycleProfileInput(
            goal: profile?.goalValue ?? .generalHealth,
            typicalCycleLength: profile?.typicalCycleLength,
            typicalPeriodLength: profile?.typicalPeriodLength,
            lutealPhaseLength: profile?.lutealPhaseLength,
            predictionEnabled: profile?.predictionEnabled ?? true,
            rawChartMode: profile?.rawChartMode ?? false
        )
        let computed = CyclePredictionEngine.predictCycle(
            cycles: inputs,
            dayLogs: dayLogsFromCalendar(),
            profile: profileInput,
            today: today
        )
        // Materialise into the SAME wire shape the server sends, applying the
        // server's own goal / still-learning fertility suppression, and label it.
        publishOfflinePrediction(
            computed,
            dto: computed.asPredictionDTO(
                goalAllowsFertile: CycleGoalPolicy.allowsFertileWindow(profileInput.goal)
            ),
            provenance: .onDevice
        )
    }

    /// Re-derive `DayLogInput`s from the cached calendar so the offline engine's
    /// symptothermal detectors have BBT / ovulation-test / mucus signals.
    private func dayLogsFromCalendar() -> [CyclePredictionEngine.DayLogInput] {
        (calendar?.days ?? []).map { day in
            CyclePredictionEngine.DayLogInput(
                date: day.date,
                flow: day.flow.flatMap(CyclePredictionEngine.FlowLevel.init),
                basalBodyTempC: day.basalBodyTempC,
                ovulationTest: day.ovulationTest.flatMap(CyclePredictionEngine.OvulationTest.init),
                cervicalMucus: day.cervicalMucus.flatMap(CyclePredictionEngine.CervicalMucus.init)
            )
        }
    }
}
