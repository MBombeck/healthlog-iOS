import SwiftUI

/// Onboarding-Step zur APNs-Permission.
///
/// Apple-HIG-Konformität: wir erklären in einem Satz was Pushes liefern,
/// und bieten einen "Später"-Button. Bei Skip oder Deny fällt die App
/// nicht zurück.
///
/// **Issue #10 — GESCHLOSSEN (v0.6.0.9).** Dieser Step wird auf der
/// Server-Branch jetzt zuverlaessig erreicht: nach erfolgreichem
/// Server-Login landet `AuthStore.phase` auf der Zwischen-Phase
/// `.authenticating(user)` (nicht direkt `.authenticated`), und `RootView`
/// haelt den `OnboardingFlow` gemountet, solange `phase == .authenticating`.
/// `OnboardingFlow.handlePhase` schaltet auf `.healthKit` weiter, der
/// HealthKit-Step fuehrt hierher, und erst `advanceFromNotifications` →
/// `AuthStore.completeOnboarding()` promotet auf `.authenticated(user)`,
/// woraufhin `RootView` die `AuthenticatedShell` einblendet. Der frueheres
/// (v0.6.0.7) Verhalten — Step nie erreicht, System-Prompt nur ueber die
/// Settings-Karte — gilt nicht mehr. Die Settings-seitige Recovery
/// (`NotificationsScreen` / `NotificationDiagnosticsScreen`,
/// `requestAuthorization` + `openSettingsURLString`) bleibt als Re-Entry-
/// Pfad fuer "Spaeter"-Tap bzw. Deny bestehen.
struct NotificationsPermissionStep: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 08-10 — the answer, not just "busy". The step used to write
    /// `_ = await container.notifications.requestAuthorization()` and advance,
    /// which discarded the one value the whole screen exists to obtain.
    @State private var permission = OnboardingPermissionRequest()
    /// v0.12 W7 — staged entrance flag, matching the rest of the onboarding
    /// steps so the rhythm is consistent. Reduce-motion flips it instantly.
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            Spacer()

            VStack(alignment: .leading, spacing: HLSpace.md) {
                // Canonical onboarding hero glyph (36pt / .semibold, monochrome)
                // — same spec as the HealthKit + AI-source steps so the header
                // rhythm is identical step-to-step (v0.14.8 onboarding-polish).
                Image(systemName: "bell.badge.fill")
                    .font(.hlIcon(HLIconSize.display))
                    .foregroundStyle(HLText.primary)
                Text("Enable reminders")
                    .font(.hlTitle1)
                    .foregroundStyle(HLText.primary)
                Text(
                    "HealthLog can remind you of your medications and alert you when a value looks off. You can change this in Settings at any time."
                )
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
            }
            .padding(.horizontal, HLSpace.xl)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : entranceOffset)
            .animation(entranceAnimation(index: 0), value: appeared)

            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    PermissionRow(
                        symbol: "pills.fill",
                        title: String(localized: "onboarding.notifications.medReminder.title"),
                        subtitle: String(localized: "onboarding.notifications.medReminder.subtitle")
                    )
                    PermissionRow(
                        symbol: "exclamationmark.triangle.fill",
                        title: String(localized: "onboarding.notifications.outOfRange.title"),
                        subtitle: String(localized: "onboarding.notifications.outOfRange.subtitle")
                    )
                    PermissionRow(
                        symbol: "trophy.fill",
                        title: String(localized: "onboarding.notifications.records.title"),
                        subtitle: String(localized: "onboarding.notifications.records.subtitle")
                    )
                }
            }
            .padding(.horizontal, HLSpace.lg)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : entranceOffset)
            .animation(entranceAnimation(index: 1), value: appeared)

            Spacer()

            VStack(spacing: HLSpace.sm) {
                OnboardingPermissionNotice(
                    outcome: permission.outcome,
                    identifier: "onboarding.notifications.denied",
                    declined: "onboarding.permission.notifications.declined",
                    failed: "onboarding.permission.notifications.failed"
                )
                answerAffordances
                HLButton("Later", variant: .ghost, action: onSkip)
                    .accessibilityIdentifier("onboarding.notifications.skip")
            }
            .padding(.horizontal, HLSpace.xl)
            .padding(.bottom, HLSpace.xxxl)
        }
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    appeared = true
                }
            }
        }
        // 08-10 — the step is leaving; nothing asked from it may publish onto
        // whatever replaced it.
        .onDisappear { permission.invalidate() }
    }

    /// What the last answer earns.
    ///
    /// A refusal is the user's decision, so it gets the two things a decision
    /// needs: somewhere to change it, and a deliberate way past it. A failure is
    /// the app's problem, so it gets a retry. Neither moves the flow on by
    /// itself — that was the defect.
    @ViewBuilder
    private var answerAffordances: some View {
        switch permission.outcome {
        case .declined:
            HLButton(
                String(localized: "onboarding.permission.openSettings"),
                icon: "gear",
                variant: .secondary,
                size: .large,
                action: openSystemSettings
            )
            .accessibilityIdentifier("onboarding.notifications.openSettings")
            HLButton(String(localized: "Continue"), variant: .primary, size: .large, action: onNext)
                .accessibilityIdentifier("onboarding.notifications.continue")
        case .failed:
            HLButton(
                String(localized: "Try again"),
                icon: "arrow.clockwise",
                variant: .primary,
                size: .large,
                isLoading: permission.isRequesting
            ) {
                Task { await request() }
            }
            .accessibilityIdentifier("onboarding.notifications.retry")
        case .idle, .granted:
            HLButton(
                String(localized: "onboarding.notifications.allow"),
                icon: "bell.fill",
                variant: .primary,
                size: .large,
                isLoading: permission.isRequesting
            ) {
                Task { await request() }
            }
            .accessibilityIdentifier("onboarding.notifications.allow")
        }
    }

    // MARK: - Entrance

    private var entranceOffset: CGFloat {
        reduceMotion ? 0 : 14
    }

    private func entranceAnimation(index: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.3, dampingFraction: 0.85)
            .delay(0.05 * Double(index + 1))
    }

    /// Publishes an answer, and advances only for the one answer that earned it.
    private func settle(_ outcome: OnboardingPermissionOutcome, token: UInt64) {
        guard permission.settle(outcome, for: token) else { return }
        if permission.advancesWithoutTheUser { onNext() }
    }

    private func request() async {
        guard let token = permission.begin() else { return }
        if let forced = OnboardingPermissionOutcome.uiTestOverride {
            settle(forced, token: token)
            return
        }
        guard let container else {
            settle(.failed, token: token)
            return
        }
        #if canImport(UserNotifications) && canImport(UIKit)
            // Apple raises the system prompt only ONCE per install, so a
            // refusal here is durable — which is exactly why it has to be said
            // out loud and offered a route into Settings, rather than being
            // discarded into `_ =` and painted over with the next screen.
            let granted = await container.notifications.requestAuthorization()
            settle(.notifications(granted: granted), token: token)
        #else
            settle(.failed, token: token)
        #endif
    }

    /// The system's notification settings for this app, where a durable refusal
    /// is the only place it can be undone. Guarded, because a URL the platform
    /// declines to open must not leave a button that does nothing.
    private func openSystemSettings() {
        #if canImport(UIKit)
            guard let url = URL(string: UIApplication.openSettingsURLString),
                  UIApplication.shared.canOpenURL(url) else { return }
            UIApplication.shared.open(url)
        #endif
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        // T2-4: row icon-rings demoted to mono — three purple-on-purple
        // chips below the hero stacked accent too high (Theme-2.0
        // <5% pixel coverage). Hero icon at top keeps its accent.
        HStack(spacing: HLSpace.md) {
            Image(systemName: symbol)
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.secondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(title).font(.hlHeadline).foregroundStyle(HLText.primary)
                Text(subtitle).font(.hlCaption).foregroundStyle(HLText.secondary)
            }
            Spacer()
        }
    }
}
