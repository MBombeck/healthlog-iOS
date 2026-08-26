import SwiftUI

// v0.5.5.1 (W-AUDIT-CODEBASE-SPECS): the View body references only our
// own `HealthKitServiceProtocol` / `HealthKitBackfillWindow` /
// `HealthKitPermissionGroup` types — none of Apple's `HK*` symbols are
// touched at this level. The conditional `import HealthKit` was a
// leftover from an earlier draft and is no longer needed.

struct HealthKitPermissionStep: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 16-03 (E2) — read for one question only: is there an authenticated
    /// server for an ECG to be uploaded to? See ``FirstSheetSyncAdoption``.
    @Environment(BackendAvailability.self) private var backend
    /// 08-10 — the request's own state, replacing a bare `isRequesting` flag.
    /// The flag could say "busy"; it could not say what the last answer was, so
    /// the only thing the step could do with an answer was leave.
    @State private var permission = OnboardingPermissionRequest()
    /// v0.12 W7 — staged entrance flag, matching `ModeSelectionStep` /
    /// `AISourceStep` / `WelcomeStep` so the onboarding rhythm is consistent
    /// step-to-step. Reduce-motion flips it instantly (see `.onAppear`).
    @State private var appeared = false
    /// Default = `.allTime` (siehe `HealthKitBackfillWindow.default`, v0.10.0
    /// operator-decided). User-Wahl wird beim Tap auf "Verbinden" persistiert;
    /// ein Skip uebernimmt nichts.
    @State private var backfillWindow: HealthKitBackfillWindow = .default
    /// CAT-1 (`v1.4.30.1`): vom Server gelieferte Kategorisierung. Wenn
    /// geladen, ordnet das Picker-UI seine Rows nach den Server-Buckets;
    /// solange `nil`, rendert es die hartcodierte UX-Reihenfolge aus
    /// `HealthKitPermissionGroup.onboardingDefaults`.
    @State private var categoryMap: CategoryAssignmentMap?

    private var orderedGroups: [HealthKitPermissionGroup] {
        if let categoryMap {
            HealthKitPermissionGroup.ordered(by: categoryMap)
        } else {
            HealthKitPermissionGroup.onboardingDefaults
        }
    }

    var body: some View {
        // v0.10.0 (W-Onboarding, Issue 4b) — the permission list (6+ rows) +
        // backfill picker overflowed the viewport. The step was a fixed
        // (non-scrolling) `VStack`, so the overflow collapsed the `Spacer()`s
        // and pushed the "Connect" CTA off-screen with no way to scroll to it
        // ("page feels broken"). Now: title + list + picker scroll inside a
        // `ScrollView`; the two CTAs are pinned in a bottom `safeAreaInset` so
        // they are always visible + tappable regardless of Dynamic Type.
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    // Canonical onboarding hero glyph (36pt / .semibold,
                    // monochrome) — same spec as the Notifications + AI-source
                    // steps so the header rhythm is identical step-to-step
                    // (v0.14.8 onboarding-polish). The earlier 40pt/.bold + `.tint`
                    // hero was the lone accent + heaviest weight in the flow,
                    // which read inconsistently against the mono siblings.
                    Image(systemName: "heart.fill")
                        .font(.hlIcon(HLIconSize.display))
                        .foregroundStyle(HLText.primary)
                    Text("Connect to Apple Health")
                        .font(.hlTitle1)
                        .foregroundStyle(HLText.primary)
                    Text("HealthLog reads values from Apple Health and writes your entries back. You stay in control per data type.")
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                }
                .padding(.horizontal, HLSpace.xl)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : entranceOffset)
                .animation(entranceAnimation(index: 0), value: appeared)

                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        ForEach(orderedGroups) { group in
                            PermissionItem(
                                symbol: group.symbolName,
                                title: group.title,
                                direction: group.directionLabel
                            )
                        }
                    }
                    // v0.5.5.1 — CAT-1 server-side categorization lands async
                    // via `.task` below; without this animation the rows snap
                    // to their new order when `categoryMap` arrives, which
                    // feels like a layout glitch. `hlAnimation` swaps the
                    // spring out under Reduce-Motion so VoiceOver users land
                    // on the final order instantly.
                    .hlAnimation(.spring(response: 0.3, dampingFraction: 0.85), value: orderedGroups)
                }
                .padding(.horizontal, HLSpace.lg)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : entranceOffset)
                .animation(entranceAnimation(index: 1), value: appeared)
                .task {
                    // CAT-1: Server-Map einmalig holen. Erfolgt der Fetch
                    // langsamer als das Erscheinen des Screens, sieht der User
                    // kurz die Default-Reihenfolge; sobald die Map da ist,
                    // sortiert SwiftUI über `orderedGroups` neu.
                    guard let repo = container?.measurementCategoriesRepo else { return }
                    categoryMap = await repo.categoryMap()
                }

                BackfillWindowPicker(selection: $backfillWindow)
                    .padding(.horizontal, HLSpace.lg)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : entranceOffset)
                    .animation(entranceAnimation(index: 2), value: appeared)
            }
            .padding(.top, HLSpace.lg)
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
        // 08-10 — the step is leaving, so nothing that was asked from it may
        // publish onto whatever replaced it (a resolved route, another account).
        .onDisappear { permission.invalidate() }
        .safeAreaInset(edge: .bottom) {
            // Pinned-CTA bar — canonical primitive (hairline + .thinMaterial),
            // matching WelcomeStep / MiniCoachOnboardingSheet.
            VStack(spacing: 0) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(HLColor.separator)
                VStack(spacing: HLSpace.sm) {
                    // 08-10 — a request that did not succeed is stated here and
                    // the step stays put. It used to call `onNext()` from its
                    // own `catch`, so a failed authorization and a granted one
                    // produced the same screen.
                    OnboardingPermissionNotice(
                        outcome: permission.outcome,
                        identifier: "onboarding.healthKit.denied",
                        declined: "onboarding.permission.healthKit.failed",
                        failed: "onboarding.permission.healthKit.failed"
                    )
                    if permission.needsAnAnswer {
                        HLButton(
                            "Try again",
                            icon: "arrow.clockwise",
                            variant: .primary,
                            size: .large,
                            isLoading: permission.isRequesting
                        ) {
                            Task { await request() }
                        }
                        .accessibilityIdentifier("onboarding.healthKit.retry")
                    } else {
                        HLButton(
                            "Connect to Apple Health",
                            icon: "heart.fill",
                            variant: .primary,
                            size: .large,
                            isLoading: permission.isRequesting
                        ) {
                            Task { await request() }
                        }
                        .accessibilityIdentifier("onboarding.healthKit.connect")
                    }
                    HLButton("Later", variant: .ghost, action: onSkip)
                        .accessibilityIdentifier("onboarding.healthKit.skip")
                }
                .padding(.horizontal, HLSpace.xl)
                .padding(.top, HLSpace.md)
                .padding(.bottom, HLSpace.sm)
            }
            // Same shelf, same rule as `WelcomeStep`: the preference is decided
            // before the material, so the permission CTA stays legible for the
            // user who turned translucency off.
            .background(HLMaterialBackground(.thinMaterial))
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
    ///
    /// The token is what keeps a superseded request from landing: a second tap
    /// cannot start a second `Task` (``OnboardingPermissionRequest/begin()``
    /// refuses), and a request whose step was left behind cannot write over the
    /// state of the one that replaced it.
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
        #if canImport(HealthKit)
            guard let writer = container?.healthKit as? any HealthKitServiceProtocol else {
                // Nothing composed can be asked. That is an operational failure,
                // not a grant — advancing here is exactly the claim this plan
                // exists to stop the step from making.
                settle(.failed, token: token)
                return
            }
            do {
                try await writer.requestAuthorization(
                    read: writer.defaultReadTypes(),
                    write: writer.defaultWriteTypes()
                )
                // Initial-Backfill-Window persistieren BEVOR der erste Wakeup
                // den AnchoredObjectQuery startet — sonst koennte HK schon
                // einen Stream gegen `.distantPast` aufbauen.
                if let container {
                    await container.setHealthKitBackfillWindow(backfillWindow)
                }
                // Direkt nach erteilter Berechtigung Background-Deliveries scharf schalten —
                // HKObserverQuery + enableBackgroundDelivery + BGProcessingTask.submit().
                // Davor würde HealthKit `notAuthorized` werfen.
                if let container {
                    // **Phase 07 / plan 07-09** — this is the `postAuthentication`
                    // trigger, named. It plans every capability, and it runs
                    // detached inside `activateHealthKitBackground` so the
                    // onboarding step never waits on a first history import.
                    await container.activateHealthKitBackground(for: .postAuthentication)
                    // v0.4.1 (F7) — Readiness markieren: ohne diesen Flag würde
                    // der HK-Connect-Banner auch nach erfolgreicher Onboarding-
                    // Berechtigung noch `.notRequested` melden und die User
                    // direkt nach Setup wieder anlügen. Migration für ältere
                    // User läuft separat im `refresh()`-Self-Heal.
                    container.hkReadinessStore.markAuthorizationRequested()
                    await container.hkReadinessStore.refresh()
                    // 16-03 / E2 — the sheet the user just answered included the
                    // ECG and State-of-Mind types, so the two device-local syncs
                    // that carry them start now instead of waiting to be found
                    // under Einstellungen → Apple Health → Weitere
                    // Synchronisierungen. No second authorization call: see
                    // `adoptFirstSheetGrant()` on both stores.
                    await adoptFirstSheetSyncs(in: container)
                }
                // The request completed. That is all this can honestly claim —
                // HealthKit does not report which read types were granted, so
                // neither the state nor the copy says "all reads granted".
                settle(.healthKit(requestError: nil), token: token)
            } catch {
                HLLog.healthKit.error("HK-Auth fehlgeschlagen: \(error.localizedDescription, privacy: .private)")
                settle(.healthKit(requestError: error), token: token)
            }
        #else
            settle(.failed, token: token)
        #endif
    }

    /// **16-03 / decision E2 — J1's other half.**
    ///
    /// Putting the two types in the first sheet only fixes what the user is
    /// ASKED. Without this the answer would land nowhere: both syncs would still
    /// be off, still only reachable through a settings drawer, and J1 would ship
    /// half-fixed — the app holding two permissions it does not use.
    ///
    /// It runs off the existing permission-outcome path rather than a new side
    /// channel: the same `if let container` block that already marks readiness
    /// and arms background delivery, one step further.
    private func adoptFirstSheetSyncs(in container: AppContainer) async {
        let plan = FirstSheetSyncAdoption.plan(hasAuthenticatedServer: backend.isAuthenticated)
        if plan.mood { await container.moodHealthSyncStore.adoptFirstSheetGrant() }
        if plan.ecg { await container.ecgHealthSyncStore.adoptFirstSheetGrant() }
    }
}

/// Picker fuer das Initial-Backfill-Window. SwiftUI's `Picker(selection:)` mit
/// `.menu`-Style ist die HIG-Empfehlung fuer 5 Optionen mit Default in der Mitte
/// (siehe HIG-Skill: `vabole-hig` § Pickers — `.segmented` ist nur fuer 2-4
/// gleichberechtigte Optionen geeignet, hier hat 30d Default-Bias).
private struct BackfillWindowPicker: View {
    @Binding var selection: HealthKitBackfillWindow

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // T2-4: icon-ring demoted to mono — purple-on-purple chip
                // alongside ≥4 PermissionItem chips below stacked accent
                // too high (Theme-2.0 <5% pixel coverage).
                HStack(spacing: HLSpace.md) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.hlIcon(HLIconSize.rowAction))
                        .foregroundStyle(HLText.secondary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: HLSpace.xxs) {
                        Text(String(localized: "How far back should we sync?"))
                            .font(.hlHeadline).foregroundStyle(HLText.primary)
                        Text("Limits the initial sync. New values are always imported live afterwards.")
                            .font(.hlCaption).foregroundStyle(HLText.secondary)
                    }
                    Spacer()
                }
                Picker("Sync from", selection: $selection) {
                    ForEach(HealthKitBackfillWindow.pickerOrder, id: \.self) { window in
                        Text(label(for: window)).tag(window)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("backfillWindowPicker")
            }
        }
    }

    private func label(for window: HealthKitBackfillWindow) -> String {
        switch window {
        case .sevenDays: String(localized: "Last 7 days")
        case .thirtyDays: String(localized: "Last 30 days")
        case .ninetyDays: String(localized: "Last 90 days")
        case .oneYear: String(localized: "Last year")
        case .allTime: String(localized: "Everything")
        }
    }
}

private struct PermissionItem: View {
    let symbol: String
    let title: String
    let direction: String

    var body: some View {
        // T2-4: per-permission icon-ring demoted to mono — the 4+ purple
        // chips were the dominant clicky-bunt signal on this screen
        // (Theme-2.0 accent-restraint).
        HStack(spacing: HLSpace.md) {
            Image(systemName: symbol)
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.secondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(title).font(.hlHeadline).foregroundStyle(HLText.primary)
                Text(direction).font(.hlCaption).foregroundStyle(HLText.secondary)
            }
            Spacer()
        }
    }
}
