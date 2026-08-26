import SwiftUI

/// v0.12 W4-1 — the SINGLE source of truth for medication-compliance band
/// classification + colour.
///
/// **Why this exists:** the same adherence percentage was classified — and
/// coloured — three different ways across three med surfaces:
///
///   - `MedicationDetailSections.ComplianceKPISection` used a `Double` ratio
///     with a *green*-topped ramp (≥0.9 `statusOK` / 0.7-0.9 warn / <0.7 bad).
///   - `ActiveMedicationRow.ComplianceBar` used an `Int` percent with a
///     *graphite*-topped ramp (≥70 `HLText.primary` / 40-69 warn / <40 bad).
///   - `InsightsMedicationsPage.InsightsComplianceBar` hand-copied that second
///     ramp verbatim.
///
/// A med at 75 % therefore read graphite on the card + Insights but *warn*
/// (yellow) on its detail; a med at ≥90 % read *green* on detail but graphite
/// elsewhere. That is a monochrome-doctrine violation (STANDARDS §2 / §7: "ONE
/// `ComplianceBand` value type, ONE threshold set, ONE mono mapping").
///
/// **Doctrine chosen (STANDARDS §2 monochrome):** GRAPHITE — a healthy
/// adherence carries no "green" signal (compliance is the expected baseline,
/// not an achievement to celebrate). Colour appears ONLY as a *warning* signal
/// when adherence slips. The single threshold set is the graphite ramp the
/// card already shipped:
///
///   - **≥70 %** → `.good` → `HLText.primary` (graphite, no signal)
///   - **40-69 %** → `.warn` → `HLColor.statusWarn`
///   - **<40 %** → `.bad` → `HLColor.statusBad`
///
/// The value type is pure + `Sendable` (no `SwiftUI.Color`) so the threshold
/// boundaries are unit-testable without a render harness; the view resolves the
/// signal colour via `color`.
public enum ComplianceBand: Sendable, Equatable, CaseIterable {
    /// Healthy adherence (≥70 %). Mono graphite — no colour signal.
    case good
    /// Slipping adherence (40-69 %). Warning signal.
    case warn
    /// Poor adherence (<40 %). Danger signal.
    case bad

    /// Classify an **integer percent** (0…100, clamped) into a band. The
    /// canonical entry point — `Int` percent is what every compliance surface
    /// already carries. `nonisolated static` so the threshold contract is
    /// unit-testable without a SwiftUI render pass.
    public nonisolated static func band(forPercent percent: Int) -> ComplianceBand {
        switch percent {
        case 70...: .good
        case 40 ..< 70: .warn
        default: .bad
        }
    }

    /// Classify a **0…1 ratio** by routing through the same integer-percent
    /// thresholds, so a `Double`-ratio call site (the detail KPI tile) and an
    /// `Int`-percent call site (card / Insights bars) can never disagree at a
    /// boundary. `0.70` → `.good`, `0.699…` → `.warn`, matching `70` / `69`.
    public nonisolated static func band(forRatio ratio: Double) -> ComplianceBand {
        band(forPercent: Int((ratio * 100).rounded(.towardZero)))
    }

    /// The signal colour for this band. Resolved on the view side so the pure
    /// value type stays `Sendable` + isolation-free. `.good` is GRAPHITE
    /// (`HLText.primary`) — monochrome doctrine: a healthy adherence is the
    /// baseline, not a celebrated signal.
    public var color: Color {
        switch self {
        case .good: HLText.primary
        case .warn: HLColor.statusWarn
        case .bad: HLColor.statusBad
        }
    }
}
