#if canImport(ActivityKit)
    import ActivityKit
    import AppIntents
    import SwiftUI
    import WidgetKit

    /// **v0.8.4 WWIDGET-1 / v0.10 W-LiveActivity-POLISH — medication-reminder
    /// Live Activity widget.**
    ///
    /// Renders ``MedicationActivityAttributes`` on the Lock Screen / banner
    /// and across the Dynamic Island regions. The one-tap "Genommen" button
    /// fires ``MarkDoseFromLiveActivityIntent`` via `Button(intent:)`, which —
    /// unlike the old Siri-shaped `MarkMedicationTakenIntent` — updates the
    /// running Activity in place so the green-check confirmation appears on the
    /// Lock Screen WITHOUT the app foregrounding. The tap still runs server-first
    /// inside the extension process using the shared Keychain token.
    ///
    /// **Layout (v0.10 / Walkthrough-2):** the Lock Screen header carries the
    /// name (own line) + dose·due-time secondary line on the left, with the loved
    /// countdown pinned to the TOP-RIGHT corner (LA1). Below it, a primary
    /// full-width ≥44 pt ``TakenButton`` — a med-card-style filled
    /// `RoundedRectangle` (LA3) that is a TWO-STEP tap-confirm (LA2: first tap
    /// arms "Erneut tippen zum Bestätigen", second tap records). On `confirmed`
    /// the action band is replaced by a centered green-check "Genommen um HH:mm".
    ///
    /// **Styling:** the extension cannot resolve the app's asset-catalog colours,
    /// so it uses the shared, asset-catalog-free ``LAColor`` palette
    /// (`LiveActivityTokens.swift`) — monochrome chrome, status colours as
    /// signal-only (green = taken, amber = snoozed, red = overdue). No Dracula.
    struct MedicationLiveActivityWidget: Widget {
        var body: some WidgetConfiguration {
            ActivityConfiguration(for: MedicationActivityAttributes.self) { context in
                MedicationLockScreenView(context: context)
                    .activityBackgroundTint(LAColor.surface)
                    .activitySystemActionForegroundColor(LAColor.text)
            } dynamicIsland: { context in
                DynamicIsland {
                    // Expanded — long-press / tap-and-hold presentation.
                    DynamicIslandExpandedRegion(.leading) {
                        pillGlyph
                            .padding(.leading, 4)
                    }
                    DynamicIslandExpandedRegion(.trailing) {
                        expandedTrailing(for: context)
                            .padding(.trailing, 4)
                    }
                    DynamicIslandExpandedRegion(.center) {
                        // Header stands alone — name · dose on ONE headline line.
                        Text(headerLine(for: context.attributes))
                            .font(.headline)
                            .foregroundStyle(LAColor.text)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        bottomRegion(for: context)
                    }
                } compactLeading: {
                    pillGlyph
                } compactTrailing: {
                    compactCountdown(for: context.state)
                } minimal: {
                    minimalGlyph(for: context.state)
                }
                .keylineTint(LAColor.accent)
            }
            // v0.12 W8-3 — opt into the `.small` supplemental family so the med
            // countdown + one-tap "Genommen" surface in the watchOS Smart Stack.
            // `supplementalActivityFamilies` is iOS 18.0+ (ships to our floor, no
            // #available); the OS only requests `.small` when a paired Watch is
            // present, otherwise the existing Lock-Screen / Dynamic-Island
            // presentations render unchanged. `SmallFamilyGate` routes the
            // `.small` request to the compact render.
            .supplementalActivityFamilies([.small])
        }

        // MARK: - Dynamic Island sub-views

        private var pillGlyph: some View {
            Image(systemName: "pills.fill")
                .foregroundStyle(LAColor.accent)
                .accessibilityHidden(true)
        }

        private func minimalGlyph(
            for state: MedicationActivityAttributes.ContentState
        ) -> some View {
            MinimalGlyph(state: state)
        }

        @ViewBuilder
        private func compactCountdown(
            for state: MedicationActivityAttributes.ContentState
        ) -> some View {
            let confirmed = state.confirmed || state.status == .taken
            switch state.status {
            case _ where confirmed:
                ConfirmedGlyph(confirmed: state.confirmed)
            case .pending:
                Text(timerInterval: countdownRange(to: state.countdownTarget), countsDown: true)
                    .monospacedDigit()
                    .frame(minWidth: 44)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(state.isOverdue ? LAColor.danger : LAColor.text)
                    .accessibilityLabel(LAStrings.countdownAccessibilityLabel(target: state.countdownTarget))
            case .snoozed:
                Image(systemName: "clock.badge.fill")
                    .foregroundStyle(LAColor.warn)
            case .taken:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LAColor.success)
            }
        }

        /// Expanded trailing (LA1): the loved countdown pinned top-right while
        /// pending — timer + a small remaining/overdue caption — mirroring the
        /// Lock-Screen corner placement. A green check once confirmed.
        @ViewBuilder
        private func expandedTrailing(
            for context: ActivityViewContext<MedicationActivityAttributes>
        ) -> some View {
            let state = context.state
            if state.confirmed || state.status == .taken {
                ConfirmedGlyph(confirmed: state.confirmed)
            } else {
                switch state.status {
                case .snoozed:
                    Image(systemName: "clock.badge.fill")
                        .foregroundStyle(LAColor.warn)
                default:
                    expandedCountdown(for: state)
                }
            }
        }

        private func expandedCountdown(
            for state: MedicationActivityAttributes.ContentState
        ) -> some View {
            let target = state.countdownTarget
            // W-B183 — danger styling reads the server-gated flag, NOT
            // `Date.now > target`. The timer text still counts to `target`.
            let isOverdue = state.isOverdue
            return VStack(alignment: .trailing, spacing: 1) {
                Text(timerInterval: countdownRange(to: target), countsDown: true)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isOverdue ? LAColor.danger : LAColor.text)
                    .multilineTextAlignment(.trailing)
                Text(isOverdue ? LAStrings.overdueShort : LAStrings.remainingShort)
                    .font(.caption2)
                    .foregroundStyle(isOverdue ? LAColor.danger : LAColor.textSecondary)
            }
            .frame(minWidth: 52, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LAStrings.countdownAccessibilityLabel(target: target))
        }

        @ViewBuilder
        private func bottomRegion(
            for context: ActivityViewContext<MedicationActivityAttributes>
        ) -> some View {
            let state = context.state
            if state.confirmed || state.status == .taken {
                confirmationLabel(
                    takenAt: context.attributes.intakeScheduledFor,
                    confirmed: state.confirmed,
                    timeFormatRaw: state.timeFormatRaw
                )
                .frame(maxWidth: .infinity)
            } else {
                switch state.status {
                case .snoozed:
                    Label(LAStrings.snoozed, systemImage: "clock.badge.fill")
                        .font(.subheadline)
                        .foregroundStyle(LAColor.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                default:
                    // LA1: countdown now lives in the expanded trailing region;
                    // the bottom is the full-width "Genommen" affordance.
                    TakenButton(
                        attributes: context.attributes,
                        pendingConfirm: state.pendingConfirm
                    )
                }
            }
        }

        /// The single header line — "Name · Dose" — so the name no longer
        /// competes with a stacked sub-line. The dose is omitted when empty
        /// (W-B188 lock-screen-privacy opt-out bakes an empty dose), so the
        /// generic-name render reads "Medication reminder" without a dangling
        /// separator.
        private func headerLine(for attributes: MedicationActivityAttributes) -> String {
            attributes.doseText.isEmpty
                ? attributes.medicationName
                : "\(attributes.medicationName) · \(attributes.doseText)"
        }

        /// Build the in-place ``MarkDoseFromLiveActivityIntent`` from the
        /// Activity's static attributes. Records against `intakeScheduledFor` so
        /// the row de-dupes with the in-app card; updates the Activity in place so
        /// the green check appears without the app foregrounding.
        static func confirmIntent(
            for attributes: MedicationActivityAttributes
        ) -> MarkDoseFromLiveActivityIntent {
            MarkDoseFromLiveActivityIntent(
                medicationId: attributes.medicationId,
                scheduledFor: attributes.intakeScheduledFor
            )
        }

        /// Clamp the countdown range so `Text(timerInterval:)` always has a
        /// valid forward range even if the target slipped into the past.
        private func countdownRange(to target: Date) -> ClosedRange<Date> {
            let now = Date.now
            let lower = min(now, target)
            let upper = max(now, target)
            return lower ... max(upper, lower.addingTimeInterval(1))
        }

        private func confirmationLabel(takenAt: Date, confirmed: Bool, timeFormatRaw: String) -> some View {
            ConfirmationCheck(takenAt: takenAt, confirmed: confirmed, timeFormatRaw: timeFormatRaw)
        }
    }

    // MARK: - "Genommen" action button (LA2 two-step + LA3 med-card style)

    /// The Live-Activity "Genommen" button — shared by the Lock Screen + the
    /// Dynamic-Island expanded bottom region.
    ///
    /// **LA2 (anti-accidental):** when `pendingConfirm` is `false` the button
    /// reads "Genommen"; the FIRST tap fires the intent which flips the
    /// Activity into the armed state, re-rendering this button as "Erneut
    /// tippen zum Bestätigen". Only the SECOND tap (this armed render) records
    /// the intake. One accidental tap therefore never records a dose.
    ///
    /// **LA3 (visibility):** instead of the prior `.borderedProminent` (white
    /// text on a light-gray system fill — barely legible on the dark Lock
    /// Screen), this mirrors the med-card "Genommen" affordance: a filled
    /// `RoundedRectangle` in `LAColor.accent` (the monochrome primary —
    /// near-black in light, near-white in dark) with the label in the inverted
    /// `surface` colour + a hairline border, so it stays legible in the dark
    /// Lock-Screen context. The armed state inverts (accent outline + accent
    /// label on a faint fill) so the two steps read distinctly.
    struct TakenButton: View {
        let attributes: MedicationActivityAttributes
        let pendingConfirm: Bool

        var body: some View {
            Button(intent: MedicationLiveActivityWidget.confirmIntent(for: attributes)) {
                Label(
                    pendingConfirm ? LAStrings.confirmTaken : LAStrings.taken,
                    systemImage: pendingConfirm ? "checkmark.circle" : "checkmark"
                )
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // b146 — shared dark-pill construction (extracted to
                // `LAMedTakenPillStyle`), now the single source of truth this
                // and the NextDose widget both apply.
                .laMedTakenPill(pendingConfirm: pendingConfirm)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pendingConfirm ? LAStrings.confirmTaken : LAStrings.taken)
            .accessibilityHint(
                pendingConfirm ? Text(LAStrings.confirmTakenHint) : Text(LAStrings.takenHint(attributes.medicationName))
            )
        }
    }

    // MARK: - Minimal glyph (Dynamic Island)

    /// Minimal presentation — a single glyph carries the whole signal.
    /// Pending → pill; confirmed/taken → green check that morphs + bounces in
    /// (bounce suppressed under Reduce Motion).
    private struct MinimalGlyph: View {
        let state: MedicationActivityAttributes.ContentState
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let confirmed = state.confirmed || state.status == .taken
            Image(systemName: confirmed ? "checkmark.circle.fill" : "pills.fill")
                .foregroundStyle(confirmed ? LAColor.success : LAColor.accent)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : state.confirmed)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Confirmed glyph (Dynamic Island green check)

    /// The green `checkmark.circle.fill` shown in the Dynamic Island
    /// (compact-trailing / expanded-trailing / minimal) once a dose is
    /// confirmed. Bounces in by default; under Reduce Motion the bounce is
    /// suppressed (the colour + glyph still carry the success signal).
    private struct ConfirmedGlyph: View {
        var confirmed: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LAColor.success)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : confirmed)
                .accessibilityLabel(LAStrings.takenAccessibility)
        }
    }

    // MARK: - Confirmation check (shared green-check moment)

    /// The green-check success swap shown on the Lock Screen + expanded DI once a
    /// dose is confirmed. Bounce + scale-up by default; cross-fade under Reduce
    /// Motion. The colour-change + glyph still communicate success without motion.
    private struct ConfirmationCheck: View {
        let takenAt: Date
        let confirmed: Bool
        /// W-B187 — the user's resolved time-format preference so the
        /// "Genommen um HH:mm" confirmation honours 12h/24h/auto.
        let timeFormatRaw: String
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Label {
                Text(LAStrings.takenAt(takenAt, timeFormatRaw: timeFormatRaw))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(LAColor.success)
            .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : confirmed)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            .accessibilityLabel(LAStrings.takenAccessibility)
        }
    }

    // MARK: - Lock-Screen / banner

    private struct MedicationLockScreenView: View {
        let context: ActivityViewContext<MedicationActivityAttributes>
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var isConfirmed: Bool {
            context.state.confirmed || context.state.status == .taken
        }

        /// W-B183 — danger styling reads the server-gated flag carried in the
        /// ContentState (computed in the app process via the same composition the
        /// in-app card uses), NOT `Date.now > countdownTarget`. The countdown
        /// timer text still counts to `countdownTarget`; only the red/overdue
        /// semantics switch to the server-gated truth. This is the Live-Activity
        /// surface of the Trulicity family of bugs (weekly med, next dose weeks
        /// away, must read neutral — never "stark überfällig").
        private var isOverdue: Bool {
            context.state.isOverdue
        }

        var body: some View {
            // v0.12 W8-3 — when the OS requests the supplemental `.small` family
            // (watchOS Smart Stack), render the compact countdown + one-tap
            // variant via `SmallFamilyGate`; every other presentation
            // (Lock-Screen / banner / `.medium`) keeps the full layout. The
            // `activityFamily` environment is iOS 18.0+, so no #available is
            // needed — devices without a paired Watch only ever see the default
            // family and stay on `lockScreenBody`.
            SmallFamilyGate(context: context, fallback: { AnyView(lockScreenBody) })
        }

        private var lockScreenBody: some View {
            VStack(alignment: .leading, spacing: 12) {
                header

                if isConfirmed {
                    ConfirmationCheck(
                        takenAt: context.attributes.intakeScheduledFor,
                        confirmed: context.state.confirmed,
                        timeFormatRaw: context.state.timeFormatRaw
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                } else {
                    switch context.state.status {
                    case .snoozed:
                        Label(LAStrings.snoozed, systemImage: "clock.badge.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LAColor.warn)
                    default:
                        actionBand
                    }
                }
            }
            .padding(16)
        }

        /// Header band — name stands alone on the left; the loved countdown is
        /// pinned to the TOP-RIGHT corner (LA1) so it no longer sits under the
        /// name and the vertical rhythm tightens.
        private var header: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "pills.fill")
                    .font(.title2)
                    .foregroundStyle(LAColor.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.medicationName)
                        .font(.headline)
                        .foregroundStyle(LAColor.text)
                        .lineLimit(2)
                    Text(metaLine)
                        .font(.subheadline)
                        .foregroundStyle(LAColor.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !isConfirmed, context.state.status != .snoozed {
                    cornerCountdown
                }
            }
        }

        /// LA1 — the countdown in the top-right corner: timer + a small
        /// "verbleibend"/"überfällig" caption beneath, right-aligned.
        private var cornerCountdown: some View {
            VStack(alignment: .trailing, spacing: 1) {
                Text(timerInterval: clampedRange, countsDown: true)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isOverdue ? LAColor.danger : LAColor.text)
                    .multilineTextAlignment(.trailing)
                Text(isOverdue ? LAStrings.overdueShort : LAStrings.remainingShort)
                    .font(.caption2)
                    .foregroundStyle(isOverdue ? LAColor.danger : LAColor.textSecondary)
            }
            .frame(minWidth: 52, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LAStrings.countdownAccessibilityLabel(target: context.state.countdownTarget))
        }

        /// Dose · due-time, or just the dose once taken (the due time is moot).
        /// The dose is omitted when empty (W-B188 lock-screen-privacy opt-out),
        /// so the redacted render shows only the due time without a dangling
        /// separator.
        private var metaLine: String {
            let dose = context.attributes.doseText
            if isConfirmed {
                return dose
            }
            let due = LAStrings.dueAt(context.attributes.scheduledFireDate, timeFormatRaw: context.state.timeFormatRaw)
            return dose.isEmpty ? due : "\(dose) · \(due)"
        }

        private var actionBand: some View {
            TakenButton(
                attributes: context.attributes,
                pendingConfirm: context.state.pendingConfirm
            )
        }

        private var clampedRange: ClosedRange<Date> {
            let now = Date.now
            let target = context.state.countdownTarget
            let lower = min(now, target)
            let upper = max(now, target)
            return lower ... max(upper, lower.addingTimeInterval(1))
        }
    }

    // MARK: - v0.12 W8-3 — small supplemental family (watchOS Smart Stack)

    /// Reads the `activityFamily` environment (iOS 18.0+) and routes the
    /// `.small` family to the compact ``SmallFamilyView`` while every other
    /// family (`.medium`, the default Lock-Screen presentation) falls back to
    /// the supplied closure.
    private struct SmallFamilyGate: View {
        let context: ActivityViewContext<MedicationActivityAttributes>
        let fallback: () -> AnyView
        @Environment(\.activityFamily) private var activityFamily

        var body: some View {
            if activityFamily == .small {
                SmallFamilyView(context: context)
            } else {
                fallback()
            }
        }
    }

    /// Compact `.small`-family render for the watchOS Smart Stack: pill glyph +
    /// med name + countdown, with the same one-tap ``MarkDoseFromLiveActivityIntent``
    /// "Genommen" button the Lock Screen uses. Confirmed state collapses to a
    /// green check so a tap on the watch reflects immediately.
    private struct SmallFamilyView: View {
        let context: ActivityViewContext<MedicationActivityAttributes>

        private var isConfirmed: Bool {
            context.state.confirmed || context.state.status == .taken
        }

        private var clampedRange: ClosedRange<Date> {
            let now = Date.now
            let target = context.state.countdownTarget
            let lower = min(now, target)
            let upper = max(now, target)
            return lower ... max(upper, lower.addingTimeInterval(1))
        }

        var body: some View {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "pills.fill")
                        .foregroundStyle(LAColor.accent)
                        .accessibilityHidden(true)
                    Text(context.attributes.medicationName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LAColor.text)
                        .lineLimit(1)
                }
                if isConfirmed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(LAColor.success)
                        .accessibilityLabel(LAStrings.taken)
                } else {
                    Text(timerInterval: clampedRange, countsDown: true)
                        .font(.caption.monospacedDigit())
                        // W-B183 — server-gated overdue flag, not Date.now > target.
                        .foregroundStyle(
                            context.state.isOverdue ? LAColor.danger : LAColor.text
                        )
                        .multilineTextAlignment(.center)
                    if context.state.status != .snoozed {
                        Button(intent: MarkDoseFromLiveActivityIntent(
                            medicationId: context.attributes.medicationId,
                            scheduledFor: context.attributes.intakeScheduledFor
                        )) {
                            Text(LAStrings.taken)
                                .font(.caption2.weight(.semibold))
                        }
                        .tint(LAColor.accent)
                    }
                }
            }
            .padding(8)
        }
    }
#endif
