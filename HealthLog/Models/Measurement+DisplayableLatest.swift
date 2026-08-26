import Foundation

/// #33 — the single, shared client-side validity rule for the "latest / last
/// measurement" value. A malformed blood-pressure row whose systolic or
/// diastolic component is `0` (a seed/validation gap, or an unmerged
/// `BLOOD_PRESSURE_SYS`/`BLOOD_PRESSURE_DIA` wire pair whose peer decoded to
/// `0`) must never surface as the newest value on any surface — it renders as
/// the nonsensical "0/77 mmHg". Every consumer that selects a single latest BP
/// (the dashboard tile via `MetricDataState.derive`, the chart-detail HeroStrip
/// via `latestRawMeasurement`, the standalone dashboard snapshot, the
/// AI/Spotlight summaries) routes its validity check through here so the rule
/// lives in exactly one place.
///
/// This guards the *latest reading selection only*. Server-provided aggregates
/// (the 30-day average etc.) are already correct server-side and are never
/// recomputed or filtered on the client.
public extension MeasurementValue {
    /// `true` when this value may be shown as a latest blood-pressure reading:
    /// for a BP pair BOTH components must be physiologically real (`> 0`). A
    /// non-BP value is not blood pressure, so the rule doesn't apply and it is
    /// always displayable.
    var isDisplayableBloodPressure: Bool {
        guard case let .bloodPressure(systolic, diastolic) = self else { return true }
        return systolic > 0 && diastolic > 0
    }
}

public extension Measurement {
    /// `true` when this measurement may surface as the single "latest / last
    /// measurement" value. Guards against a malformed 0-systolic / 0-diastolic
    /// blood-pressure row; every non-BP kind is always displayable (the rule
    /// only constrains BP).
    var isDisplayableLatest: Bool {
        value.isDisplayableBloodPressure
    }
}
