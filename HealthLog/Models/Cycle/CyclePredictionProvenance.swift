import Foundation

/// **CU-25 (#72) — where the cycle prediction on screen came from.**
///
/// The project's standing rule is that the server computes the canonical value
/// and the client consumes the resolved DTO. The cycle surface keeps a second,
/// on-device engine (``CyclePredictionEngine``) so an offline / degraded start
/// still has numbers to paint — but a number derived on the device is NOT the
/// number the record holds, and the screen must say so rather than let the two
/// silently diverge.
///
/// Two guarantees hang off this type:
/// 1. **Visible provenance** — ``CycleScreen`` paints a caption whenever the
///    prediction is ``onDevice``, so the user is never shown a device-computed
///    statement about her body dressed as the server's.
/// 2. **A pin test** — `CyclePredictionPinTests` holds the on-device engine
///    against a fixture recorded from the server's own TypeScript engine on the
///    same input. A divergence breaks a test instead of quietly showing a
///    different number.
///
/// **Z1 (#72) — scope.** This applies to the FORECAST only. The cycle VERDICT
/// (`state` / `phase` / `overdueDays`) has no on-device origin to label, because
/// it has no on-device path: see ``CycleVerdictDTO`` and `CycleStore+Verdict`.
public enum CyclePredictionProvenance: String, Sendable, Equatable, CaseIterable {
    /// Resolved `CyclePredictionDTO` from `GET /api/cycle/calendar` — canonical.
    case server
    /// Computed on this device by ``CyclePredictionEngine`` because the server
    /// was unreachable or returned no prediction. Always labelled in the UI.
    case onDevice
}

// MARK: - Goal → fertile-window policy (mirrors the server, single table)

/// The goal gate for fertile-window / predicted-ovulation output. Mirrors the
/// server `goalAllowsFertileWindow` (`src/lib/cycle/dto.ts:293`) 1:1: shown for
/// `TRYING_TO_CONCEIVE` and `AVOID_PREGNANCY`, hidden for `GENERAL_HEALTH` /
/// `PERIMENOPAUSE` / `OFF`.
///
/// The client only ever applies this when it has to materialise a DTO itself
/// (the offline fallback below) — on the server path the suppression already
/// happened server-side and iOS just consumes the nulls.
public enum CycleGoalPolicy {
    public static func allowsFertileWindow(_ goal: CycleGoal?) -> Bool {
        switch goal {
        case .tryingToConceive, .avoidPregnancy: true
        case .generalHealth, .perimenopause, .off, nil: false
        }
    }
}

// MARK: - Engine → wire DTO bridge

public extension CyclePredictionEngine.Prediction {
    /// Materialise this on-device result into the SAME wire shape the server
    /// sends, so every downstream surface reads one type and one set of field
    /// semantics — there is no second rendering path for the offline case.
    ///
    /// Mirrors the server's `toCyclePredictionDTO` (`src/lib/cycle/dto.ts:201`)
    /// exactly, including its structural suppression: the fertile window and the
    /// predicted ovulation are nulled both when the goal forbids them AND while
    /// still learning (< 3 observed cycles), and `ovulationConfirmed` is
    /// goal-gated. Without this the offline fallback would paint a fertility
    /// claim the server refuses to make.
    ///
    /// `disclaimer` stays empty: the server resolves that string from its own
    /// i18n catalogue and the client has no business inventing one. The
    /// prediction card already falls back to `cycle.prediction.disclaimer.local`
    /// on a blank value.
    func asPredictionDTO(goalAllowsFertile: Bool) -> CyclePredictionDTO {
        let fertileAllowed = goalAllowsFertile && !stillLearning
        return CyclePredictionDTO(
            method: method.rawValue,
            nextPeriodStart: nextPeriodStart,
            nextPeriodStartLow: nextPeriodStartLow,
            nextPeriodStartHigh: nextPeriodStartHigh,
            fertileWindowStart: fertileAllowed ? fertileWindowStart : nil,
            fertileWindowEnd: fertileAllowed ? fertileWindowEnd : nil,
            predictedOvulation: fertileAllowed ? predictedOvulation : nil,
            ovulationConfirmed: goalAllowsFertile ? ovulationConfirmed : false,
            confidence: confidence,
            cyclesObserved: cyclesObserved,
            stillLearning: stillLearning,
            disclaimer: ""
        )
    }
}
