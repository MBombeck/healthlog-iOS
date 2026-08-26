import SwiftUI

/// Resolves a medication's quick-mark-taken affordance on `MedicationsScreen`
/// based on `todayIntakes`. Surfaces three visual states + a target-intake-id
/// (when actionable), which the parent row uses to drive the optimistic mark
/// via `MedicationsStore.markIntakeQuickUndoable(intakeId:status:)` (the
/// WriteOutcome quick-mark path with the `min(scheduledAt, now)` clamp — NOT
/// the bare `mark(intake:status:)`).
///
/// Resolution rules (deterministic, computed at row-render time from
/// `Date.now`):
///
/// 1. **`.takenToday`** — at least one today-intake for the med has
///    `status == .taken`. Button renders filled-check, disabled (the user has
///    already logged a dose today; further taps are a no-op).
/// 2. **`.actionable(intakeId:)`** — earliest today-intake with
///    `status == .pending && scheduledAt <= now`. Button is the primary
///    tap-target — outline-circle ➜ filled-check on optimistic flip.
/// 3. **`.upcoming`** — there *is* a pending intake today but it's still in
///    the future (`scheduledAt > now`). Button renders outline-circle in the
///    tertiary tint, tap is disabled (operator learns "not yet" without
///    needing copy).
/// 4. **`.notScheduledToday`** — no today-intake at all for the med (PRN, or
///    already-actioned skip/snooze entries only). Button is hidden — there's
///    no obvious dose to mark; the operator can open the detail screen to
///    log an ad-hoc intake if needed.
///
/// Pulled into its own file so the resolution rules can be unit-tested in
/// isolation without spinning up a `MedicationsStore`.
public enum MedicationQuickMarkState: Equatable, Sendable {
    case takenToday
    case actionable(intakeId: String)
    case upcoming
    case notScheduledToday

    /// Snapshot-friendly presentation descriptor — captures every
    /// state-derived render output of `MedicationQuickMarkButton` so the
    /// W-UX2 phantom-44pt-collapse contract + the visual differences
    /// between the four states can be locked via a single `assertSnapshot`
    /// per case without depending on SwiftUI body introspection.
    /// Lives on the state enum (not the button view) so the descriptor
    /// stays `Sendable` and the snapshot suite doesn't need a SwiftUI
    /// host or a MainActor jump.
    public struct PresentationDescriptor: Equatable, Sendable {
        public let symbolName: String
        public let isSymbolHidden: Bool
        public let isActionable: Bool
        public let isDisabled: Bool
        public let visualSize: CGFloat
        /// HIG hit-target ≥ 44pt — only widens past `visualSize` when
        /// `isActionable` (W-UX2 phantom-collapse contract). Matches the
        /// `frame(minWidth:minHeight:)` `MedicationQuickMarkButton`
        /// reserves in its body.
        public let hitTarget: CGFloat
        public let accessibilityLabel: String
        public let accessibilityHint: String
    }

    /// Compute the presentation contract the button renders for this
    /// state. Pure — no SwiftUI environment access; safe to call from
    /// any thread. The accessibility strings are pulled from the same
    /// `Localizable.xcstrings` keys the view uses, so a key rename
    /// surfaces in the snapshot diff.
    public func presentationDescriptor() -> PresentationDescriptor {
        PresentationDescriptor(
            symbolName: symbolName,
            isSymbolHidden: self == .notScheduledToday,
            isActionable: isActionableState,
            isDisabled: !isActionableState,
            visualSize: MedicationQuickMarkButton.visualSize,
            hitTarget: isActionableState
                ? MedicationQuickMarkButton.minHitTarget
                : MedicationQuickMarkButton.visualSize,
            accessibilityLabel: descriptorAccessibilityLabel,
            accessibilityHint: descriptorAccessibilityHint
        )
    }

    private var symbolName: String {
        switch self {
        case .takenToday: "checkmark.circle.fill"
        case .actionable: "circle"
        case .upcoming: "circle.dotted"
        case .notScheduledToday: "circle"
        }
    }

    private var isActionableState: Bool {
        if case .actionable = self { return true }
        return false
    }

    private var descriptorAccessibilityLabel: String {
        switch self {
        case .takenToday: String(localized: "medication.quick_mark.already_taken_today")
        case .actionable: String(localized: "medication.quick_mark.taken")
        case .upcoming: String(localized: "medication.quick_mark.upcoming")
        case .notScheduledToday: String(localized: "medication.quick_mark.not_scheduled_today")
        }
    }

    private var descriptorAccessibilityHint: String {
        switch self {
        case .actionable: String(localized: "medication.quick_mark.action_hint")
        case .takenToday, .upcoming, .notScheduledToday: ""
        }
    }

    /// Pure-function predicate over `todayIntakes` for a single medication-id.
    /// `now` is injected so tests can pin a deterministic clock; production
    /// callers can default to `.now`.
    public static func resolve(
        medicationId: String,
        todayIntakes: [MedicationIntake],
        now: Date = .now
    ) -> MedicationQuickMarkState {
        let intakesForMed = todayIntakes.filter { $0.medicationId == medicationId }
        guard !intakesForMed.isEmpty else { return .notScheduledToday }

        // Already-taken takes precedence: even if there are also pending future
        // doses for this med (multi-dose-per-day schedule), surface the
        // "Heute genommen" state on the list — the operator can still mark
        // the second dose via the detail screen or the Today section's
        // swipe-actions. Rationale: the list-row quick-mark is "did you take
        // today's pill?" not "log every dose". Power-users get the full
        // surface in the Today timeline above.
        if intakesForMed.contains(where: { $0.status == .taken }) {
            return .takenToday
        }

        // Earliest past-due pending — the dominant "I forgot to log this
        // morning's pill" path.
        let pastDue = intakesForMed
            .filter { $0.status == .pending && $0.scheduledAt <= now }
            .sorted { $0.scheduledAt < $1.scheduledAt }
        if let next = pastDue.first {
            return .actionable(intakeId: next.id)
        }

        // Future-pending exists (next dose still ahead) — render upcoming.
        let hasFuturePending = intakesForMed.contains {
            $0.status == .pending && $0.scheduledAt > now
        }
        if hasFuturePending {
            return .upcoming
        }

        // Only-skipped / only-snoozed entries — nothing actionable on the
        // quick-mark surface. Hide the button.
        return .notScheduledToday
    }
}

/// Compact `✓`-button rendered at the leading edge of an active-medication
/// row. Owns its own visual state derived from the resolved
/// `MedicationQuickMarkState`; the parent supplies `onTap` only when
/// `.actionable`. The button is sized to fit the 28-point icon-chip column on
/// the row, so it doesn't shift other content.
public struct MedicationQuickMarkButton: View {
    public let state: MedicationQuickMarkState
    public let onTap: () -> Void

    /// Visual chip size — kept at 32 pt so the row layout matches the
    /// adjacent pill-icon column. The hit-target itself is `minHitTarget`
    /// below (UX-H2 reconcile).
    public nonisolated static let visualSize: CGFloat = 32

    /// HIG-mandated minimum tap-target. Applied via `.frame(minWidth:
    /// minHitTarget, minHeight: minHitTarget)` so the chip's hit area
    /// extends past the visual edge into the surrounding row padding.
    public nonisolated static let minHitTarget: CGFloat = 44

    /// v0.14.x Q — reduce-motion gate for the taken-confirmation bounce.
    /// The `.symbolEffect(.bounce)` is pure flourish, so the system
    /// reduce-motion preference disables it (the symbol still swaps to the
    /// filled check, just without the one-shot bounce).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: MedicationQuickMarkState, onTap: @escaping () -> Void) {
        self.state = state
        self.onTap = onTap
    }

    public var body: some View {
        // v0.5.5.1 — body reads from the snapshot-friendly descriptor
        // so the unit-tested presentation contract + the rendered view
        // share a single source of truth. Symbol-name, hit-target,
        // accessibility strings all flow from one place.
        let descriptor = state.presentationDescriptor()
        Button(action: handleTap) {
            Image(systemName: descriptor.symbolName)
                .font(.hlIcon(HLIconSize.lg, weight: .regular))
                .foregroundStyle(tint)
                // v0.14.x Q — bounce the leading dose-checkmark exactly on the
                // discrete `actionable → takenToday` flip (`circle` →
                // `checkmark.circle.fill`). Keyed on `isTakenToday` so it fires
                // once per mark, not on every body pass; reduce-motion gated.
                // `.contentTransition(.symbolEffect(.replace))` makes the glyph
                // swap itself read as a morph rather than a hard cut.
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: reduceMotion ? false : isTakenToday)
                .opacity(descriptor.isSymbolHidden ? 0 : 1)
                // W-UX2 (2026-05-21): the 44 pt HIG hit-target only
                // applies when the button is actually tappable
                // (`.actionable`). For `.takenToday`, `.upcoming`, and
                // `.notScheduledToday` the visual chip stays at 32 pt —
                // same column-width as the pill-icon chip beside it —
                // so non-interactive rows align with the natural icon
                // column instead of reserving a phantom 44 pt slot.
                .frame(width: descriptor.visualSize, height: descriptor.visualSize)
                .frame(minWidth: descriptor.hitTarget, minHeight: descriptor.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(descriptor.isDisabled)
        .accessibilityLabel(Text(descriptor.accessibilityLabel))
        .accessibilityHint(Text(descriptor.accessibilityHint))
        .accessibilityAddTraits(descriptor.isActionable ? [] : .isStaticText)
        .accessibilityIdentifier("meds.quickMark") // audit L3 — UI-test hygiene
    }

    private func handleTap() {
        guard case .actionable = state else { return }
        onTap()
    }

    /// True once a dose for this med is logged today — the discrete state the
    /// `.symbolEffect(.bounce)` keys on so the leading checkmark celebrates the
    /// mark exactly once.
    private var isTakenToday: Bool {
        state == .takenToday
    }

    private var tint: Color {
        switch state {
        case .takenToday: HLColor.statusOK
        case .actionable: HLText.secondary
        case .upcoming: HLText.tertiary
        case .notScheduledToday: HLText.tertiary
        }
    }
}

// W-MEDS-VISUAL-IMPL (Issue #7) extracted the row component into
// `ActiveMedicationRow.swift`. This file now scopes to the quick-mark
// state machine + the button view that renders it, plus the offline
// banner emitted by the surrounding screen.

/// Small offline-queued toast surfaced under the nav-bar when a quick-mark
/// landed in the outbox (retriable network error). Auto-dismisses after 3 s
/// driven by the parent screen's `Task.sleep`. Mirrors the queued-banner
/// style from T-4's `MedicationDetailScreen`.
struct QuickMarkQueuedBanner: View {
    /// v0.14.x Q — reduce-motion gate for the sync-pending pulse.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: HLSpace.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.secondary)
                // v0.14.x Q — pulse the sync glyph while the offline-queued
                // banner is shown so "waiting to sync" reads as a live,
                // in-progress state rather than a static error. The banner is
                // a discrete, short-lived (3 s) surface, so the effect is a
                // routine state-change cue, not ambient noise. Reduce-motion
                // gated (the icon stays static when motion is disabled).
                .symbolEffect(.pulse, isActive: !reduceMotion)
            Text(String(localized: "medication.quick_mark.queued_offline"))
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer()
        }
        .padding(.horizontal, HLSpace.md)
        .padding(.vertical, HLSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                .fill(HLColor.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                        .strokeBorder(HLColor.separator, lineWidth: 1)
                )
        )
        .padding(.horizontal, HLSpace.lg)
        .padding(.top, HLSpace.sm)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Quick-Mark states") {
    VStack(alignment: .leading, spacing: HLSpace.lg) {
        MedicationQuickMarkButton(state: .takenToday, onTap: {})
        MedicationQuickMarkButton(state: .actionable(intakeId: "x"), onTap: {})
        MedicationQuickMarkButton(state: .upcoming, onTap: {})
        MedicationQuickMarkButton(state: .notScheduledToday, onTap: {})
    }
    .padding()
    .background(HLSurface.primary)
}
