import SwiftUI

/// Top-level Shell, sobald der User authentifiziert ist.
///
/// Nutzt das native iOS-18-`TabView` mit der typed-`Tab`-API. Der "Erfassen"-
/// Slot ist kein echtes Navigationsziel: Tap löst die Sheet-Modal-Erfassung
/// aus, die Selection schnappt zurück auf den vorherigen echten Tab.
struct AuthenticatedShell: View {
    enum TabIdentifier: String, Hashable, CaseIterable {
        case home
        case measure
        case meds
        case insights
        case more
    }

    /// Stabile Konfiguration der Tab-Bar — zugleich Snapshot-Kontrakt für Tests.
    /// Reihenfolge entspricht 1:1 der Render-Reihenfolge im `TabView`.
    struct TabDescriptor: Hashable {
        let id: TabIdentifier
        let titleKey: String
        let systemImage: String
        let isAction: Bool
    }

    /// v0.5.2-A8 (2026-05-17): Erfassen sits at the **middle** slot (index 2
    /// of 5). Operator override after A4 left it at index 1: "Erfassen-Knopf
    /// MUSS in der MITTE der TabBar stehen, nicht an zweiter Stelle". The
    /// central action slot reads as the most reachable tap-target on a
    /// thumb-only iPhone hold, matching the canonical position Apple uses
    /// for compose-style centre actions across native apps.
    static let tabDescriptors: [TabDescriptor] = [
        .init(id: .home, titleKey: "Home", systemImage: "house.fill", isAction: false),
        .init(id: .meds, titleKey: "Meds", systemImage: "pills.fill", isAction: false),
        .init(id: .measure, titleKey: "Log", systemImage: "plus.circle.fill", isAction: true),
        .init(id: .insights, titleKey: "Insights", systemImage: "sparkles", isAction: false),
        .init(id: .more, titleKey: "More", systemImage: "ellipsis", isAction: false)
    ]

    @Environment(AppRouter.self) private var router
    // Non-private: read by the same-module shell extensions (+Capture / +AIConsent).
    @Environment(\.appContainer) var container
    @Environment(FeatureFlagsStore.self) var featureFlags
    @State private var lastDestinationTab: TabIdentifier = .home
    /// W-FILELEN — `internal` (not `private`) so the `+Capture` /`+AIConsent`
    /// same-module extensions can read/flip these `@State` flags. Pure
    /// visibility relax; no behaviour change.
    @State var showMeasureSheet: Bool = false
    /// v0.5.1-F3 — drives `CapturePickerSheet`. When the user taps the
    /// central "Erfassen" tab slot we present this picker first. The
    /// picker resolves to a typed `CaptureAction`; on selection we
    /// dismiss it and present the chosen downstream surface (Measure
    /// sheet, Meds tab, or Mood screen).
    @State private var showCapturePicker: Bool = false
    /// v0.6.1.17 Y10.2 — drives the redesigned `MoodScreen` (Y10 5-icon
    /// hero layout) as the canonical mood-entry surface. Pre-Y10.2 the
    /// Erfassen → Stimmung row pushed `MoodQuickEntrySheet` (an emoji-
    /// based legacy quick-capture); Y10 rebuilt `MoodScreen` around the
    /// operator-approved icon pack but the central CTA was still routed
    /// to the retired sheet. Operator brief 2026-05-24: "Erfassen von
    /// Stimmungen soll über Erfassen funktionieren" — same surface,
    /// presented as a sheet from the central CTA + notification handler.
    /// W-FILELEN — internal so the +Capture extension can present the mood sheet.
    @State var showMoodQuickEntrySheet: Bool = false
    /// v0.5.3-EQ-1 — drives `MedicationQuickIntakeSheet`. The picker
    /// row used to route to the Meds *list* (`router.selectedTab = .meds`)
    /// which left the operator scrolling for their pending intake; the
    /// new sheet shows the actionable doses inline with a confirm step
    /// so the operator can back out before committing.
    @State var showMedicationQuickIntakeSheet: Bool = false
    /// v0.14.8 C4 — drives `CycleCaptureSheet`, the gated cycle day-log
    /// surface reachable from the central "Erfassen" picker's `.cycle` row.
    /// Only ever presentable when `CycleGate.isCycleTrackingAvailable` is true
    /// (the row itself is never built otherwise).
    @State var showCycleCaptureSheet: Bool = false
    /// v0.5.3-EQ-1 — surfaces the queued-banner for medication
    /// quick-intake commits that landed in the outbox (retriable
    /// network error). Mirrors `MedicationsScreen.quickMarkQueuedBannerShownAt`.
    @State var quickIntakeQueuedAt: Date?
    @State var quickIntakeQueuedTask: Task<Void, Never>?
    /// v0.5.2-A4 — staged downstream action picked inside the picker.
    /// We deliberately do NOT fire it inline with the picker-dismiss; the
    /// previous "Task { sleep 350 ms }" chain blocked perceived snappiness
    /// for ~350 ms even on a ProMotion device. Instead the picker sets
    /// this slot, dismisses itself, and `.onChange(of: showCapturePicker)`
    /// fires the staged action as soon as the dismissal commits (the
    /// follow-up sheet / tab-switch then animates straight into the
    /// vacated slot). Sub-200 ms tap-to-content on iPhone 17 Pro p95.
    @State var pendingCaptureAction: CapturePickerSheet.CaptureAction?
    /// v0.5.2-A4 — Pow `changeEffect` trigger for the Erfassen tap
    /// reaction. Each `.measure` selection increments the counter so a
    /// medium haptic + subtle scale-jump fire on the picker-row group
    /// even on rapid double-taps.
    @State private var captureTapPulse: Int = 0
    /// v0.5.0+ F5/PA9 RC2 — the AI consent sheet (S7) was added in v0.4.2
    /// but never presented. This `@State` drives its presentation: nil
    /// means no sheet, a wrapped provider means "consent gate is closed
    /// for this provider and the sheet must be shown". Apple Guideline
    /// 5.1.2(i) requires explicit informed consent BEFORE the first
    /// off-device LLM call, so we evaluate the gate on view appearance
    /// and on provider switches.
    /// W-FILELEN — internal so the `+AIConsent` extension can drive the gate.
    @State var pendingConsentProvider: AIConsentRequest?
    /// v0.15 W-FRONTDOORS — drives the type-prefilled `MeasureSheetView` opened
    /// by the Home Vorsorge tile's "jetzt messen" action. A non-nil kind both
    /// presents the sheet (`.sheet(item:)`) and seeds its picker. Reuses the
    /// SAME `MeasureSheetView` the central Erfassen path presents — no second
    /// capture UI — just with `initialKind` set.
    @State private var measurePrefillKind: PrefilledMeasureKind?
    /// W-INVITE-DEEPLINK (#16) — drives the non-destructive "invite can't be
    /// applied to a signed-in account" alert. Flipped on by the router's
    /// `inviteWhileSignedInNoticeCount` edge (an invite link tapped while already
    /// signed in). No token is held — this is a fact-of-tap acknowledgement only.
    @State private var showInviteWhileSignedInNotice: Bool = false

    var body: some View {
        // SwiftUI braucht einen Bindable-View des @Observable Routers, damit
        // wir `$router.selectedTab` als Binding an TabView geben können.
        @Bindable var router = router

        // ZStack puts the offline banner above the TabView without reflowing
        // tab content (the banner sits inside the safe area). A2-Audit §7.
        ZStack(alignment: .top) {
            tabView(router: router)
            if let container {
                ReachabilityBanner(reachability: container.reachability)
                    .zIndex(10)
            }
            if quickIntakeQueuedAt != nil {
                QuickMarkQueuedBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
            }
            // v0.5.5.1 — undo-toast slot. Bottom-anchored pill that surfaces
            // after a destructive store path optimistically removed a row
            // (measurement / mood delete, medication archive). Sits above
            // the TabView but below modal sheets — sheets cover the toast
            // intentionally so the user knows the latest sheet wins focus.
            if let container, let action = container.undoCoordinator.current {
                VStack {
                    Spacer()
                    HLUndoToast(
                        message: action.message,
                        ttlSeconds: Int(action.ttl.rounded()),
                        onUndo: {
                            Task { await container.undoCoordinator.performUndo() }
                        },
                        onDismiss: {
                            container.undoCoordinator.dismiss(reason: .userDismissed)
                        }
                    )
                    // Keep the pill within screen bounds on compact widths
                    // while letting it size to its content (centered pill,
                    // not full-width).
                    .padding(.horizontal, HLSpace.lg)
                    // W30 — sit just above the tab bar / home indicator,
                    // consistently across every host (med card, mood,
                    // measurement-delete, med-history TableView). The old
                    // 40pt lift made it float too high over the med Verlauf.
                    .padding(.bottom, HLSpace.md)
                }
                // Horizontally center the pill in the host.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(true)
                .zIndex(30)
            }
            // v0152 W-COACH-CLEANUP (C1/C2) — the app-wide floating coach disc
            // (which read as a top-trailing "coach symbol on every screen") was
            // removed: the operator never wanted a coach affordance floating over
            // every tab, and it routed to the on-device arm against his External-AI
            // pick. The manual coach entry returns as an inline button on the
            // Insights metric pages (next wave); proactive surfacing stays via the
            // server nudge signal. No overlay, no shell-hosted AskCoachSheet here.
        }
        // v0.14.8 W2-SYNCUX (AUDIT-QOL-UX §4) — first-login sync banner,
        // pinned above the bottom safe area until the first handshake/summary
        // lands. Lifecycle + suppression doc on `FirstLoginSyncBanner`.
        .safeAreaInset(edge: .bottom, spacing: 0) { FirstLoginSyncBanner() }
        // W-INVITE-DEEPLINK (#16) — an invite link tapped while already signed in
        // can't be applied to the current account (an invite creates a NEW
        // account). The router bumps a counter rather than silently dropping the
        // tap; we surface a calm, non-destructive alert. Counter edge (not `Bool`)
        // so back-to-back taps re-present even before the previous edge is handled.
        .onChange(of: router.inviteWhileSignedInNoticeCount) { oldValue, newValue in
            guard newValue > oldValue else { return }
            showInviteWhileSignedInNotice = true
        }
        .alert(
            Text("invite.signedIn.notice.title"),
            isPresented: $showInviteWhileSignedInNotice
        ) {
            Button(role: .cancel) {} label: { Text("invite.signedIn.notice.dismiss") }
        } message: {
            Text("invite.signedIn.notice.body")
        }
        .animation(HLMotion.spring, value: container?.undoCoordinator.current?.id)
        .animation(.default, value: quickIntakeQueuedAt)
        .task {
            // Bug 2 (v0.14.8) — load the provider config app-wide BEFORE the gate
            // evaluates. It was only fetched by AIProviderScreen/SettingsScreen
            // before, so the shell gate (fires on first paint from any tab) saw
            // `config == nil` → `.unconfigured` and either never offered consent or
            // captured a phantom whose accept no-ops. The `.onChange` below
            // re-evaluates once the real provider lands. Guarded so we never
            // clobber an in-flight provider edit.
            if container?.aiProviderStore.config == nil {
                await container?.aiProviderStore.load()
            }
            evaluateConsentGate()
            // v0.14.10 — reconcile the server consent receipt (see doc there).
            await container?.syncServerAIConsentReceipt()
        }
        .onChange(of: container?.aiProviderStore.config) { _, _ in
            evaluateConsentGate()
        }
        .onChange(of: router.selectedTab) { _, _ in
            // Re-evaluate on tab change so a user navigating to Insights
            // (the only off-device-LLM consumer) sees the gate before any
            // network call kicks off via the screen's .task modifier.
            evaluateConsentGate()
        }
        // PB1 H3 — Settings KI-toggle and AI-feature CTAs trigger an
        // explicit prompt via `AIConsentStore.requestExplicitPrompt()`,
        // which bumps `explicitPromptToken`. Bypasses the wasDeclined()
        // auto-suppression so a user who actively asks for the dialog
        // actually sees it. The shell owns the sheet — surfaces don't.
        .onChange(of: container?.aiConsentStore.explicitPromptToken) { _, _ in
            requestExplicitConsentPrompt()
        }
        .sheet(item: $pendingConsentProvider) { request in
            AIConsentSheet(
                provider: request.provider,
                onAccept: {
                    // W-B186 COACH-1 (#24) — server-managed grant has no concrete
                    // provider; grant the server-managed scope so `aiMode` flips
                    // to `.online` and every Coach surface appears. The receipt
                    // mint below still runs (the #24 thread: mint `ai_full` for
                    // `managedBy: "server"`) — consent is NOT bypassed.
                    if request.serverManaged {
                        container?.aiConsentStore.grantServerManaged()
                        pendingConsentProvider = nil
                        Task {
                            await container?.syncServerAIConsentReceipt()
                            await container?.insightsStore.load()
                            await container?.dailyBriefingStore.load()
                        }
                        return
                    }
                    // Bug 2 (v0.14.8) — guard the accept path against a stray
                    // `.unconfigured`, like the Coach path. `grant(.unconfigured)`
                    // no-ops, so accepting would dismiss to a false "consent
                    // missing" — the trust break the operator hit. Re-resolve live
                    // (config may have arrived since the sheet opened); only grant
                    // a real provider, else keep the gate closed.
                    let resolved = container?.aiProviderStore.config?.resolvedProvider ?? .unconfigured
                    let grantProvider = resolved == .unconfigured ? request.provider : resolved
                    guard grantProvider != .unconfigured else { return }
                    container?.aiConsentStore.grant(for: grantProvider)
                    pendingConsentProvider = nil
                    // Kick off the gated stores so the user sees content
                    // immediately after granting (otherwise they'd have
                    // to manually pull-to-refresh).
                    Task {
                        // v0.14.10 — mint the server consent receipt FIRST,
                        // else the loads below warm no-key fallbacks.
                        await container?.syncServerAIConsentReceipt()
                        await container?.insightsStore.load()
                        await container?.dailyBriefingStore.load()
                    }
                },
                onDecline: {
                    // PB1 H3 — persist the decline so the next tab-switch
                    // does NOT re-present the sheet. Re-presentation now
                    // requires an explicit user action (Settings toggle on,
                    // AI-feature CTA tap), routed via `.hlRequestAIConsentPrompt`.
                    if request.serverManaged {
                        container?.aiConsentStore.declineServerManaged()
                    } else {
                        container?.aiConsentStore.decline(for: request.provider)
                    }
                    pendingConsentProvider = nil
                }
            )
        }
        // A360-5 C-1 — inject the user's display-unit prefs app-wide so EVERY
        // tab's drill-down (Measurements list, Insights / chart detail) renders
        // values in the chosen unit, matching the dashboard tile. Previously
        // only `DashboardScreen` injected it, so the detail/list/chart surfaces
        // fell back to `.standard` (canonical) and disagreed with the tile.
        .environment(\.unitPreferences, container?.settingsStore.unitPreferences ?? .standard)
    }

    // `evaluateConsentGate()`, `requestExplicitConsentPrompt()` and
    // `presentExplicitConsentIfNeeded()` live in
    // `AuthenticatedShell+AIConsent.swift`; `applyPendingCaptureAction()`,
    // `surfaceQuickIntakeQueuedBanner()` and `tabSelectionBinding(router:)` live
    // in `AuthenticatedShell+Capture.swift` — both to keep this file under the
    // 600-line `file_length` swiftlint budget.

    @ViewBuilder
    private func tabView(router: AppRouter) -> some View {
        @Bindable var router = router
        TabView(selection: tabSelectionBinding(router: router)) {
            // CU-06 — the `.accessibilityIdentifier("shell.tab.<id>")` that used
            // to sit on every `Tab` here is GONE, because it never did what its
            // comment claimed. A `TabContent` forwards an accessibility *label*
            // to the tab-bar button (the Log tab below still relies on that and
            // it demonstrably works), but it drops an accessibility
            // *identifier*: the runtime hierarchy shows every bar button as
            // `Button, …, label: 'Mehr'` with no `identifier:` at all. So
            // `tabBars.buttons["shell.tab.more"]` matched nothing, and the two
            // auth-journey UITests that keyed off those landmarks failed — which
            // was then twice misread as "headless-simulator tab-bar flakiness"
            // and quarantined, on the strength of the identifiers still being
            // present in THIS source file. Source presence is not tree presence.
            //
            // The landmark UITests actually get is the SF Symbol on the bar
            // button's image, which IS in the tree (`identifier: 'ellipsis'`)
            // and is just as locale-independent as an identifier would have
            // been — see `AuthJourneyUITest.tabBarButton(_:symbol:)`. Do not
            // re-add a `Tab`-level identifier without first checking it against
            // a real `app.debugDescription` dump.
            Tab("Home", systemImage: "house.fill", value: TabIdentifier.home) {
                DashboardScreen()
            }

            Tab("Meds", systemImage: "pills.fill", value: TabIdentifier.meds) {
                MedicationsScreen()
            }

            // Action-Slot at the MIDDLE position (index 2 of 5). Opens
            // CapturePickerSheet on selection rather than navigating; the
            // selection snaps back to the previous real tab. v0.5.2-A8
            // operator override: centre slot is sacred for the primary CTA.
            Tab("Log", systemImage: "plus.circle.fill", value: TabIdentifier.measure) {
                // v0.12 W3-7 — the Action-slot body is rendered for exactly one
                // layout pass before `.onChange(of: router.selectedTab)` snaps
                // the selection back to the prior real tab. `Color.clear` left
                // that single frame transparent, so whatever sat *behind* the
                // TabView (window backing / transition artefact) flashed
                // through on the primary CTA. Painting the opaque app
                // background instead means that one transient frame matches the
                // canvas the snap-back lands on — no perceptible blink — while
                // keeping the snap-back logic byte-for-byte unchanged (lowest-
                // risk fix; no prior-tab re-host, no double store binding).
                //
                // ⚠️ NEEDS DEVICE FRAME-CAPTURE CONFIRMATION (W3-7): the flash
                // is a sub-frame artefact the simulator may not surface; the
                // operator should confirm on-device that the opaque fill fully
                // removes the blink. If a residual blink remains, the fallback
                // is to host the prior-tab content under the sheet.
                HLColor.background
                    .ignoresSafeArea()
            }
            .accessibilityLabel(Text("Add measurement"))

            Tab("Insights", systemImage: "sparkles", value: TabIdentifier.insights) {
                // v0.11 W22-W1 — the Insights tab now opens on the web-mirror
                // container (tab strip + Übersicht/metric switch). `Übersicht`
                // renders the existing `InsightsScreen` body verbatim; metric
                // pills open `ChartDetailScreen` (interim destination, W2 swaps).
                InsightsContainerScreen()
            }

            Tab("More", systemImage: "ellipsis", value: TabIdentifier.more) {
                MoreScreen()
            }
        }
        // v0.5.x C-9 — iOS 26+ collapses the Tab-Bar on scroll-down so
        // reading-surfaces recover the bottom safe-area for content; the
        // bar re-emerges as Liquid Glass on scroll-up. iOS 18-25: no-op.
        .hlTabBarMinimizeOnScroll()
        .sensoryFeedback(.selection, trigger: router.selectedTab)
        .sheet(isPresented: $showMeasureSheet) {
            // A6 §5 / user-report #4 — present at .large only. The earlier
            // [.medium, .large] combo caused a "half-open → pause → full"
            // animation because focus on the first TextField pushed the
            // keyboard up, which auto-promoted the .medium detent to .large.
            // Capture forms are not contextual-peek surfaces; .large mirrors
            // Apple's own Health "Add Data" sheet behavior.
            MeasureSheetView()
                .hlSheetPresentation(.form)
        }
        // v0.15 W-FRONTDOORS — the type-prefilled measure sheet for the Home
        // Vorsorge tile's "jetzt messen". Same `MeasureSheetView` as the central
        // Erfassen path, seeded to the due reminder's kind. `.sheet(item:)` so
        // the bound kind both presents the sheet and feeds `initialKind`.
        .sheet(item: $measurePrefillKind) { prefill in
            MeasureSheetView(initialKind: prefill.kind)
                .hlSheetPresentation(.form)
        }
        // v0.5.1-F3 — central "Erfassen" picker. Sits at .medium so the
        // user can dismiss without leaving the underlying tab; the row
        // selection cascades to the appropriate downstream surface.
        //
        // v0.5.2-A4 perf: the row callback only stages the action in
        // `pendingCaptureAction` and triggers dismissal — the actual
        // hand-off (Measure sheet / tab switch) runs in the
        // `.onChange(of: showCapturePicker) false`-edge below, removing
        // the ~350 ms Task.sleep that previously blocked first-paint.
        // v0.6.1 Y2 — Home-Compliance sheet pattern: dismiss happens via
        // the drag-indicator only (no "Abbrechen" toolbar button). The
        // existing `.onChange(of: showCapturePicker)` observer below
        // already handles the false-edge to fire any staged
        // `pendingCaptureAction`; an interactive-drag-down dismiss leaves
        // `pendingCaptureAction == nil` and the observer no-ops, which is
        // exactly the cancel semantics we want.
        .sheet(isPresented: $showCapturePicker) {
            CapturePickerSheet(
                pulseTrigger: captureTapPulse,
                // v0.14.8 C4 — offer the gated cycle row only when the
                // CycleGate deems the user eligible (women-only resolution +
                // explicit opt-in, hard-gated behind FeatureFlag.cycleTracking).
                showsCycleRow: container?.cycleGate.isCycleTrackingAvailable ?? false,
                onSelect: { action in
                    pendingCaptureAction = action
                    showCapturePicker = false
                },
                onCancel: {
                    pendingCaptureAction = nil
                    showCapturePicker = false
                }
            )
            // v0.14.1 W-CAPTURE-GAP — the picker now owns its own presentation
            // (a content-fitted `.height` detent + drag indicator) instead of
            // the fixed `.medium` that `hlSheetPresentation(.compact)` applied.
            // `.medium` reserved ~half the screen no matter how few rows were
            // offered, leaving a large dead gap below the last row — the
            // "empty space below the items" the operator flagged. Self-sizing
            // makes the sheet collapse to exactly the available capture rows.
            // v0.8.3 W-A2 — capture sheet presents as a standard bottom
            // sheet (slides up from the bottom). The v0.8.2 W3b B1
            // zoom-morph (`matchedTransitionSource` on the measure `Tab` +
            // `.navigationTransition(.zoom)`) was anchored to the centre
            // tab content, so on-device it read as a centre/top "pop"
            // rather than a bottom sheet — operator: "fühlt sich kaputt an".
            // Removed the morph; the glass background below stays. The
            // chart-detail → fullscreen zoom-morph (C1) is unaffected.
            // v0.6.1 Y2 — Home-Compliance background. Operator brief
            // 2026-05-22: "Erfassen-Sheet sieht oben hellgrau/dunkelgrau
            // aus — anders als das Compliance-Sheet". The compliance
            // sheet uses `HLColor.surface` (opaque card-surface); the
            // capture picker matches so both feel like the same panel
            // class.
            .presentationBackground(HLColor.surface)
        }
        // v0.6.1.17 Y10.2 — central mood-entry surface. The redesigned
        // `MoodScreen` (Y10 5-icon Wie-geht's-dir hero + history + chart)
        // hosts every mood-entry path: central CTA, notification body-tap,
        // and the deep-link `mood.log.now` action. The legacy
        // `MoodQuickEntrySheet` (Unicode emoji selector) was retired —
        // the Y10 surface carries the icon pack the operator approved.
        .sheet(isPresented: $showMoodQuickEntrySheet) {
            // v0.14.8: MoodScreen now OWNS its host-sheet detent (it grows from a
            // compact `.medium` over the hero/faces to a tall detent the moment a
            // mood is logged, so the inline annotate panel — sliders + tags + note
            // + Fertig — fits WITHOUT internal scrolling). We therefore no longer
            // pin the detent from the call-site; the screen's own
            // `presentationDetents(selection:)` drives it. Earlier Y10.6 note: the
            // pre-log surface is still compact (~`.medium`), so the "zu hoch / black
            // void" the operator flagged on the bare hero stays fixed.
            MoodScreen()
        }
        // v0.5.3-EQ-1 — medication quick-intake confirm flow. Replaces
        // the previous tab-flip to `.meds`.
        .sheet(isPresented: $showMedicationQuickIntakeSheet) {
            MedicationQuickIntakeSheet(
                onDismiss: { showMedicationQuickIntakeSheet = false },
                onQueued: { surfaceQuickIntakeQueuedBanner() }
            )
            .hlSheetPresentation(.form)
        }
        // v0.14.8 C4 — gated cycle day-log capture. Reachable only via the
        // CapturePicker `.cycle` row, which the CycleGate hides for ineligible /
        // opted-out users — so this sheet is unreachable for them by construction.
        .sheet(isPresented: $showCycleCaptureSheet) {
            if let container {
                CycleCaptureSheet(
                    store: container.cycleStore,
                    healthKit: container.healthKit,
                    onDismiss: { showCycleCaptureSheet = false }
                )
                .hlSheetPresentation(.form)
            }
        }
        .onChange(of: showCapturePicker) { oldValue, newValue in
            // v0.5.2-A4 — the picker has finished dismissing. Apply the
            // staged action on the next main-actor pass so SwiftUI has
            // committed the dismissal animation tear-down before we
            // present any follow-up sheet.
            guard oldValue, !newValue else { return }
            applyPendingCaptureAction()
        }
        // v0.5.4.3 HP5 — surface MoodQuickEntrySheet when a mood-reminder
        // action handler (or a tap on a MOOD_REMINDER push body) signals
        // intent via `router.requestMoodQuickEntry()`. The router bumps a
        // counter so identical re-requests still flip the sheet open even
        // if the previous edge hasn't dismissed yet — matches the
        // `captureTapPulse` pattern just above.
        .onChange(of: router.moodQuickEntryRequestCount) { oldValue, newValue in
            guard newValue > oldValue else { return }
            showMoodQuickEntrySheet = true
        }
        // v0.14.x Q — surface the medication quick-intake confirm sheet when a
        // Home-Screen Quick Action ("Log an intake") signals intent via
        // `router.requestMedicationQuickIntake()`. The router bumps a counter so
        // identical re-requests still flip the sheet open even if the previous
        // edge hasn't dismissed — same pattern as the mood quick-entry observer
        // above. Reuses the SAME sheet the central CapturePicker's `.medication`
        // row presents, so there is one quick-intake surface, not two.
        .onChange(of: router.medicationQuickIntakeRequestCount) { oldValue, newValue in
            guard newValue > oldValue else { return }
            showMedicationQuickIntakeSheet = true
        }
        // v0.15 W-FRONTDOORS — surface the type-prefilled measure sheet when the
        // Home Vorsorge tile signals "jetzt messen" via
        // `router.requestMeasure(prefill:)`. The router bumps a counter so
        // identical re-requests re-present even if the previous edge hasn't
        // dismissed — same pattern as the mood / medication observers above.
        .onChange(of: router.measurePrefillRequestCount) { oldValue, newValue in
            guard newValue > oldValue,
                  let kind = router.consumeMeasurePrefillKind() else { return }
            measurePrefillKind = PrefilledMeasureKind(kind: kind)
        }
        .onChange(of: router.selectedTab) { oldValue, newValue in
            if newValue == .measure {
                // v0.5.2-A4 — bump the Pow trigger BEFORE we present the
                // sheet so the medium-impact haptic + scale-jump fire on
                // the tap, not on the sheet's settle frame. Same trigger
                // value flows into CapturePickerSheet as `pulseTrigger`
                // so the row group inherits the same beat.
                captureTapPulse &+= 1
                showCapturePicker = true
                // Snap zurück auf den vorherigen echten Tab — der Action-Slot
                // soll sich wie ein Button anfühlen, nicht wie ein Ziel.
                router.selectedTab = oldValue == .measure ? lastDestinationTab : oldValue
            } else {
                lastDestinationTab = newValue
            }
        }
    }
}

// `PrefilledMeasureKind` lives in `AuthenticatedShell+Capture.swift`;
// `AIConsentRequest` lives in `AuthenticatedShell+AIConsent.swift` — both to
// keep this file under the 600-line `file_length` swiftlint budget.
