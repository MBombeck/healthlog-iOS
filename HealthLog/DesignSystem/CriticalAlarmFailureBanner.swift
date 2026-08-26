import SwiftUI

/// **audit-release 05 C-1 — persistent, honest warning that a critical
/// (life-safety) medication alarm failed to arm.**
///
/// A critical-med AlarmKit `schedule` failure (auth revoked mid-session, per-app
/// alarm limit exceeded, config rejected) used to be logged + swallowed with no
/// user signal, leaving the med presented as alarm-owned while no alarm was set.
/// This banner names the affected meds and offers a re-arm retry (a forced
/// medications reload re-runs the reconcile).
///
/// It intentionally mirrors `ErrorBanner`'s serious `statusBad` treatment but is
/// a *persistent* inline warning rather than the transient, auto-hiding
/// `store.error` overlay — it must stay visible until the alarm actually arms.
/// Lives in `DesignSystem/` alongside `ErrorBanner` so the banner chrome is one
/// primitive (and the Theme-2.0 white-chip treatment matches without tripping
/// the screen-code color rule).
public struct CriticalAlarmFailureBanner: View {
    public let medicationNames: [String]
    public let onRetry: () -> Void

    public init(medicationNames: [String], onRetry: @escaping () -> Void) {
        self.medicationNames = medicationNames
        self.onRetry = onRetry
    }

    private var bodyText: String {
        let joined = medicationNames.formatted(.list(type: .and))
        return String(format: String(localized: "med.criticalAlarm.failed.body"), joined)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text(LocalizedStringKey("med.criticalAlarm.failed.title"))
                    .font(.hlCaption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(bodyText)
                    .font(.hlCaption)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: onRetry) {
                Text("Try again")
                    .font(.hlCaption.weight(.semibold))
                    .padding(.horizontal, HLSpace.sm)
                    .padding(.vertical, HLSpace.xs)
                    .background(Color.white.opacity(0.18))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Try again"))
            .accessibilityHint(Text(LocalizedStringKey("med.criticalAlarm.failed.retry.hint")))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, HLSpace.md)
        .padding(.vertical, HLSpace.sm)
        .background(
            RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                .fill(HLColor.statusBad)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringKey("med.criticalAlarm.failed.title")))
        .accessibilityValue(Text(bodyText))
        .accessibilityIdentifier("medications.criticalAlarmFailureBanner")
    }
}

#if DEBUG
    #Preview("Critical alarm not set") {
        ZStack(alignment: .top) {
            HLColor.background.ignoresSafeArea()
            CriticalAlarmFailureBanner(
                medicationNames: ["Insulin", "Warfarin"],
                onRetry: {}
            )
            .padding()
        }
    }
#endif
