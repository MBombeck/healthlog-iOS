import ActivityKit
import SwiftUI
import WidgetKit

/// **#190 — the Live Activity the push relay starts.**
///
/// Same look as ``MedicationLiveActivityWidget``: the title, the due clock in
/// the corner, the state as a short caption. The title is the name the app
/// resolved from its own server for the started dose
/// (``RelayLiveActivityLabel``); the push and the attributes carry none, so
/// until the app has it the title stays neutral. A stale Activity asks to
/// check the status.
struct RelayDoseLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HealthLogDoseAttributes.self) { context in
            RelayDoseLockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(LAColor.surface)
                .activitySystemActionForegroundColor(LAColor.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "pills.fill")
                        .foregroundStyle(LAColor.accent)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RelayDoseClock(state: context.state)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(context.state.isOverdue ? LAColor.danger : LAColor.text)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RelayDoseCopy.title(for: context.state))
                            .font(.headline)
                            .foregroundStyle(LAColor.text)
                        Text(RelayDoseCopy.caption(context.state, isStale: context.isStale))
                            .font(.caption)
                            .foregroundStyle(LAColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "pills.fill")
                    .foregroundStyle(LAColor.accent)
                    .accessibilityHidden(true)
            } compactTrailing: {
                RelayDoseClock(state: context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
                    .foregroundStyle(context.state.isOverdue ? LAColor.danger : LAColor.text)
            } minimal: {
                Image(systemName: context.state.confirmed || context.state.status == .taken ? "checkmark" : "pills.fill")
                    .foregroundStyle(LAColor.accent)
                    .accessibilityHidden(true)
            }
            .keylineTint(LAColor.accent)
        }
    }
}

private struct RelayDoseLockScreenView: View {
    let state: HealthLogDoseContentState
    let isStale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "pills.fill")
                .font(.title2)
                .foregroundStyle(LAColor.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(RelayDoseCopy.title(for: state))
                    .font(.headline)
                    .foregroundStyle(LAColor.text)
                    .lineLimit(2)
                Text(RelayDoseCopy.caption(state, isStale: isStale))
                    .font(.subheadline)
                    .foregroundStyle(state.isOverdue && !isStale ? LAColor.danger : LAColor.textSecondary)
            }
            Spacer(minLength: 0)
            if state.isOpen, !isStale {
                RelayDoseClock(state: state)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(state.isOverdue ? LAColor.danger : LAColor.text)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 72, alignment: .trailing)
            }
        }
        .padding(16)
    }
}

/// Counts down to the due time, then up since it.
private struct RelayDoseClock: View {
    let state: HealthLogDoseContentState

    var body: some View {
        if let target = state.countdownDate, state.isOpen {
            if target > .now {
                Text(timerInterval: Date.now ... target, countsDown: true)
            } else {
                Text(target, style: .relative)
            }
        }
    }
}

enum RelayDoseCopy {
    /// The title for this content state: the stored name only when it names
    /// this dose and names may show on the lock screen (R1 (3), (12)).
    static func title(for state: HealthLogDoseContentState) -> LocalizedStringKey {
        title(RelayLiveActivityLabel.shown(
            RelayLiveActivityLabel.read(),
            for: state,
            hideNames: LockScreenPrivacy.hideMedicationName()
        ))
    }

    /// The resolved name, else neutral.
    static func title(_ label: RelayLiveActivityLabel?) -> LocalizedStringKey {
        guard let label, !label.title.isEmpty else { return "la.relay.title.neutral" }
        return "\(label.title)"
    }

    static func caption(_ state: HealthLogDoseContentState, isStale: Bool) -> LocalizedStringKey {
        if isStale { return LAStrings.checkStatus }
        if state.confirmed { return LAStrings.takenConfirmation }
        switch state.status {
        case .taken: return LAStrings.takenConfirmation
        case .skipped: return "la.relay.status.skipped"
        case .snoozed: return LAStrings.snoozed
        case .overdue: return LAStrings.overdueShort
        case .due: return "la.relay.status.due"
        case .pending: return LAStrings.remainingShort
        case .unknown: return LAStrings.checkStatus
        }
    }
}
