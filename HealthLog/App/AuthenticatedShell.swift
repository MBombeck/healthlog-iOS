import SwiftUI

/// Top-level Shell, sobald der User authentifiziert ist.
///
/// Nutzt das native iOS-18-`TabView` mit der typed-`Tab`-API. Der "Erfassen"-
/// Slot ist kein echtes Navigationsziel: Tap löst die Sheet-Modal-Erfassung
/// aus, die Selection schnappt zurück auf den vorherigen echten Tab.
struct AuthenticatedShell: View {
    enum TabIdentifier: Hashable, Sendable {
        case home
        case measure
        case meds
        case insights
        case more
        /// A sidebar tab. Exists only on a regular-width window with the
        /// destination's gate open; `AppRouter.resolve` keeps the selection
        /// off it otherwise.
        case section(SidebarDestination)

        /// Stable name for the tab contract dump and logs.
        var rawValue: String {
            switch self {
            case .home: "home"
            case .measure: "measure"
            case .meds: "meds"
            case .insights: "insights"
            case .more: "more"
            case let .section(destination): "section.\(destination.rawValue)"
            }
        }
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
    /// Symbols are the base names: the system picks the variant per
    /// placement (filled in the iPhone tab bar, outlined in the sidebar), so
    /// the bar tabs and the sidebar tabs read as one set.
    static let tabDescriptors: [TabDescriptor] = [
        .init(id: .home, titleKey: "Home", systemImage: "house", isAction: false),
        .init(id: .meds, titleKey: "Meds", systemImage: "pills", isAction: false),
        .init(id: .measure, titleKey: "Log", systemImage: "plus.circle", isAction: true),
        .init(id: .insights, titleKey: "Insights", systemImage: "sparkles", isAction: false),
        .init(id: .more, titleKey: "More", systemImage: "ellipsis", isAction: false)
    ]

    @Environment(AppRouter.self) var router
    /// Decides whether the sidebar sections exist. The shell is the one place
    /// that reads it; screens measure their own width.
    @Environment(\.horizontalSizeClass) var windowSizeClass
    /// Read with the width: a phone held across is wide but short.
    @Environment(\.verticalSizeClass) var windowVerticalSizeClass
    /// The class the shell builds for (``AuthenticatedShell/shellSizeClass(horizontal:vertical:)``):
    /// regular only for a window that is wide and not short, so an iPhone
    /// Pro Max or Air turned across under a full screen keeps its tab bar.
    var sizeClass: UserInterfaceSizeClass? {
        Self.shellSizeClass(horizontal: windowSizeClass, vertical: windowVerticalSizeClass)
    }

    // Non-private: read by the same-module shell extensions (+Capture / +AIConsent).
    @Environment(\.appContainer) var container
    @State private var lastDestinationTab: TabIdentifier = .home
    /// The server version the last probe recorded: the timeline needs 1.42.
    @AppStorage(KnownServerVersion.defaultsKey) private var serverVersion: String?
    /// `internal` (not `private`) so the `+Capture` /`+AIConsent`
    /// same-module extensions can read/flip these `@State` flags. Pure
    /// visibility relax; no behaviour change.
    @State var showMeasureSheet: Bool = false
    /// Drives `CapturePickerSheet`. When the user taps the
    /// central "Erfassen" tab slot we present this picker first. The
    /// picker resolves to a typed `CaptureAction`; on selection we
    /// dismiss it and present the chosen downstream surface (Measure
    /// sheet, Meds tab, or Mood screen).
    /// Internal so the +Capture extension's sheet gate can flip it.
    @State var showCapturePicker: Bool = false
    /// Drives the redesigned `MoodScreen` (Y10 5-icon
    /// hero layout) as the canonical mood-entry surface. Pre-Y10.2 the
    /// Erfassen → Stimmung row pushed `MoodQuickEntrySheet` (an emoji-
    /// based legacy quick-capture); Y10 rebuilt `MoodScreen` around the
    /// operator-approved icon pack but the central CTA was still routed
    /// to the retired sheet. Operator brief 2026-05-24: "Erfassen von
    /// Stimmungen soll über Erfassen funktionieren" — same surface,
    /// presented as a sheet from the central CTA + notification handler.
    /// Internal so the +Capture extension can present the mood sheet.
    @State var showMoodQuickEntrySheet: Bool = false
    /// v0.5.3-EQ-1 — drives `MedicationQuickIntakeSheet`. The picker
    /// row used to route to the Meds *list* (`router.selectedTab = .meds`)
    /// which left the operator scrolling for their pending intake; the
    /// new sheet shows the actionable doses inline with a confirm step
    /// so the operator can back out before committing.
    @State var showMedicationQuickIntakeSheet: Bool = false
    /// Drives `CycleCaptureSheet`, the gated cycle day-log
    /// surface reachable from the central "Erfassen" picker's `.cycle` row.
    /// Only ever presentable when `CycleGate.isCycleTrackingAvailable` is true
    /// (the row itself is never built otherwise).
    @State var showCycleCaptureSheet: Bool = false
    /// v0.5.3-EQ-1 — surfaces the queued-banner for medication
    /// quick-intake commits that landed in the outbox (retriable
    /// network error). Mirrors `MedicationsScreen.quickMarkQueuedBannerShownAt`.
    @State var quickIntakeQueuedAt: Date?
    @State var quickIntakeQueuedTask: Task<Void, Never>?
    /// Staged downstream action picked inside the picker.
    /// We deliberately do NOT fire it inline with the picker-dismiss; the
    /// previous "Task { sleep 350 ms }" chain blocked perceived snappiness
    /// for ~350 ms even on a ProMotion device. Instead the picker sets
    /// this slot, dismisses itself, and `.onChange(of: showCapturePicker)`
    /// fires the staged action as soon as the dismissal commits (the
    /// follow-up sheet / tab-switch then animates straight into the
    /// vacated slot). Sub-200 ms tap-to-content on iPhone 17 Pro p95.
    @State var pendingCaptureAction: CapturePickerSheet.CaptureAction?
    /// Pow `changeEffect` trigger for the Erfassen tap
    /// reaction. Each `.measure` selection increments the counter so a
    /// medium haptic + subtle scale-jump fire on the picker-row group
    /// even on rapid double-taps.
    @State var captureTapPulse: Int = 0
    /// The form the capture picker opened in (sheet or popover), fixed while
    /// it is up.
    @State var capturePickerForm: UserInterfaceSizeClass?
    /// Which tab root's "+" is on screen and which one the open picker hangs on.
    @State var captureAnchor = ShellCaptureAnchor()
    /// v0.5.0+ F5/PA9 RC2 — the AI consent sheet was added in v0.4.2
    /// but never presented. This `@State` drives its presentation: nil
    /// means no sheet, a wrapped provider means "consent gate is closed
    /// for this provider and the sheet must be shown". Apple Guideline
    /// 5.1.2(i) requires explicit informed consent BEFORE the first
    /// off-device LLM call, so we evaluate the gate on view appearance
    /// and on provider switches.
    /// Internal so the `+AIConsent` extension can drive the gate.
    @State var pendingConsentProvider: AIConsentRequest?
    /// Drives the type-prefilled `MeasureSheetView` opened
    /// by the Home Vorsorge tile's "jetzt messen" action. A non-nil kind both
    /// presents the sheet (`.sheet(item:)`) and seeds its picker. Reuses the
    /// SAME `MeasureSheetView` the central Erfassen path presents — no second
    /// capture UI — just with `initialKind` set.
    /// Internal so the +Capture extension's sheet gate can flip it.
    @State var measurePrefillKind: PrefilledMeasureKind?
    /// Drives the non-destructive "invite can't be
    /// applied to a signed-in account" alert. Flipped on by the router's
    /// `inviteWhileSignedInNoticeCount` edge (an invite link tapped while already
    /// signed in). No token is held — this is a fact-of-tap acknowledgement only.
    @State private var showInviteWhileSignedInNotice: Bool = false
    /// The one owner of "which shell sheet is up". Every flag
    /// above is flipped through `requestSheet(_:)` and released by that sheet's
    /// `onDismiss`, so no request can preempt a sheet that is still on screen or
    /// still animating (the 286 `SheetBridge` preemption crash). See
    /// `ShellSheetGate`.
    @State var sheetGate = ShellSheetGate()

    var body: some View {
        // SwiftUI braucht einen Bindable-View des @Observable Routers, damit
        // wir `$router.selectedTab` als Binding an TabView geben können.
        @Bindable var router = router

        // ZStack puts the offline banner above the TabView without reflowing
        // tab content (the banner sits inside the safe area). A2-Audit §7.
        ZStack(alignment: .top) {
            tabView(router: router)
                // The view keeps the shortcuts wherever no menu bar carries
                // them; the menu bar (`ShellCommands`) lists the same ones.
                .background { ShellKeyCommands(router: router) }
                .focusedSceneValue(\.hlShellRouter, router)
                // Regular: Log is the "+" of the tab roots, not a tab.
                .environment(\.hlShellCapture, sizeClass == .regular ? captureEntry : nil)
            if let container {
                ReachabilityBanner(reachability: container.reachability)
                    .zIndex(10)
            }
            if quickIntakeQueuedAt != nil {
                QuickMarkQueuedBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
            }
            // Undo-toast slot. Bottom-anchored pill that surfaces
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
                    // Sit just above the tab bar / home indicator,
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
            // The app-wide floating coach disc
            // (which read as a top-trailing "coach symbol on every screen") was
            // removed: the operator never wanted a coach affordance floating over
            // every tab, and it routed to the on-device arm against his External-AI
            // pick. The manual coach entry returns as an inline button on the
            // Insights metric pages (next wave); proactive surfacing stays via the
            // server nudge signal. No overlay, no shell-hosted AskCoachSheet here.
        }
        // First-login sync banner,
        // pinned above the bottom safe area until the first handshake/summary
        // lands. Lifecycle + suppression doc on `FirstLoginSyncBanner`.
        .safeAreaInset(edge: .bottom, spacing: 0) { FirstLoginSyncBanner() }
        // An invite link tapped while already signed in
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
            // Bug 2 — load the provider config app-wide BEFORE the gate
            // evaluates. It was only fetched by AIProviderScreen/SettingsScreen
            // before, so the shell gate (fires on first paint from any tab) saw
            // `config == nil` → `.unconfigured` and either never offered consent or
            // captured a phantom whose accept no-ops. The `.onChange` below
            // re-evaluates once the real provider lands. Guarded so we never
            // clobber an in-flight provider edit.
            if container?.aiProviderStore.config == nil {
                await container?.aiProviderStore.load()
            }
            // Read-only: local consent follows `ai.consent`; never mints.
            reconcileConsentWithServer()
        }
        .onChange(of: container?.aiProviderStore.config) { _, _ in
            evaluateConsentGate()
        }
        .onChange(of: container?.aiCapabilityGate.standingConsent) { _, _ in reconcileConsentWithServer() }
        .onChange(of: router.selectedTab) { _, _ in
            // Re-evaluate on tab change so a user navigating to Insights
            // (the only off-device-LLM consumer) sees the gate before any
            // network call kicks off via the screen's .task modifier.
            evaluateConsentGate()
        }
        // Settings KI-toggle and AI-feature CTAs trigger an
        // explicit prompt via `AIConsentStore.requestExplicitPrompt()`,
        // which bumps `explicitPromptToken`. Bypasses the wasDeclined()
        // auto-suppression so a user who actively asks for the dialog
        // actually sees it. The shell owns the sheet — surfaces don't.
        .onChange(of: container?.aiConsentStore.explicitPromptToken) { _, _ in
            requestExplicitConsentPrompt()
        }
        // A shell sheet parked behind the consent sheet resumes once it is gone.
        .sheet(item: $pendingConsentProvider, onDismiss: resumeParkedSheet) { request in
            AIConsentSheet(
                provider: request.provider,
                recipients: request.recipients,
                onAccept: {
                    // Server-managed grant has no concrete
                    // provider; grant the server-managed scope so `aiMode` flips
                    // to `.online` and every Coach surface appears. The receipt
                    // below is this tap's own consent act (#143, `confirm: true`).
                    //
                    // Bug 2 + J1 — the grant itself (server-managed
                    // scope or the live-resolved provider, never a stray
                    // `.unconfigured`) is `AppContainer.acceptAIConsent(_:)`.
                    // A request that resolves to no provider grants nothing
                    // and leaves the sheet up, exactly as before.
                    guard let container,
                          container.acceptAIConsent(request) != .noProvider else { return }
                    pendingConsentProvider = nil
                    // Kick off the gated stores so the user sees content
                    // immediately after granting (otherwise they'd have
                    // to manually pull-to-refresh).
                    Task {
                        // Record this tap's receipt FIRST (#143, `confirm:
                        // true`), else the loads below warm no-key fallbacks.
                        await container.recordAcceptedAIConsent()
                        await container.insightsStore.load()
                        await container.dailyBriefingStore.load()
                    }
                },
                onDecline: {
                    // Persist the decline so the next tab-switch
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
        // Inject the user's display-unit prefs app-wide so EVERY
        // tab's drill-down (Measurements list, Insights / chart detail) renders
        // values in the chosen unit, matching the dashboard tile. Previously
        // only `DashboardScreen` injected it, so the detail/list/chart surfaces
        // fell back to `.standard` (canonical) and disagreed with the tile.
        .environment(\.unitPreferences, container?.settingsStore.unitPreferences ?? .standard)
        // Whether a page that needs the width opens across: a phone in
        // compact width on iOS 27. Read here, where the size class belongs.
        .environment(\.hlOpensAcross, opensAcross)
        .reviewPromptHost(queuedBannerAt: $quickIntakeQueuedAt)
    }

    // `evaluateConsentGate()`, `requestExplicitConsentPrompt()` and
    // `presentExplicitConsentIfNeeded()` live in
    // `AuthenticatedShell+AIConsent.swift`; `applyPendingCaptureAction()`,
    // `surfaceQuickIntakeQueuedBanner()` and `tabSelectionBinding(router:)` live
    // in `AuthenticatedShell+Capture.swift` — both to keep this file under the
    // 600-line `file_length` swiftlint budget.

    private var opensAcross: Bool {
        guard #available(iOS 27.0, *) else { return false }
        return OrientationPolicy.opensAcross(isPad: OrientationPolicy.deviceIsPad, isCompactWidth: sizeClass == .compact)
    }

    /// What the shell can show now: the size class and the open gates, read
    /// from the same gates the More rows use.
    var shellLayout: ShellLayout {
        ShellLayout(
            sizeClass: sizeClass,
            enabledSections: SidebarDestination.enabled(
                isModuleEnabled: { container?.moduleGate.isEnabled($0) != false },
                isCycleTrackingAvailable: container?.cycleGate.isCycleTrackingAvailable == true,
                isTimelineAvailable: TimelineRepository.isTimelineAvailable(serverVersion: serverVersion),
                isSeizuresAvailable: SeizuresModule.isAvailable(modules: container?.moduleGate.modules)
            )
        )
    }

    /// The compact shell: the five-tab bar of the phone, the folded Duo and
    /// a narrow window. A regular window is the sidebar and its detail
    /// (`+SplitView`).
    func compactTabView(router: AppRouter, layout: ShellLayout) -> some View {
        TabView(selection: tabSelectionBinding(router: router, layout: layout)) {
            // The `.accessibilityIdentifier("shell.tab.<id>")` that used
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
            Tab("Home", systemImage: "house", value: TabIdentifier.home) {
                DashboardScreen()
            }

            Tab("Meds", systemImage: "pills", value: TabIdentifier.meds) {
                MedicationsScreen()
            }

            // The Log action slot at the centre, compact only (`+Capture`).
            logTab(sizeClass: sizeClass)

            Tab("Insights", systemImage: "sparkles", value: TabIdentifier.insights) {
                // The Insights tab now opens on the web-mirror
                // container (tab strip + Übersicht/metric switch). `Übersicht`
                // renders the existing `InsightsScreen` body verbatim; metric
                // pills open `ChartDetailScreen` (interim destination, W2 swaps).
                InsightsContainerScreen()
            }

            Tab("More", systemImage: "ellipsis", value: TabIdentifier.more) {
                MoreScreen()
            }
        }
        // The style the bar always had; compact, it stays a bottom bar.
        .tabViewStyle(.sidebarAdaptable)
    }

    private func tabView(router: AppRouter) -> some View {
        // Compact: the tab bar; regular: the sidebar and its detail.
        navigationContainer(router: router)
            .sheet(isPresented: $showMeasureSheet, onDismiss: releaseSheet(.measure)) {
                // A6 §5 / user-report #4 — present at .large only. The earlier
                // [.medium, .large] combo caused a "half-open → pause → full"
                // animation because focus on the first TextField pushed the
                // keyboard up, which auto-promoted the .medium detent to .large.
                // Capture forms are not contextual-peek surfaces; .large mirrors
                // Apple's own Health "Add Data" sheet behavior. The sheet's
                // scaffold sets the size itself.
                MeasureSheetView()
            }
            // The type-prefilled measure sheet for the Home
            // Vorsorge tile's "jetzt messen". Same `MeasureSheetView` as the central
            // Erfassen path, seeded to the due reminder's kind. `.sheet(item:)` so
            // the bound kind both presents the sheet and feeds `initialKind`.
            .sheet(item: $measurePrefillKind, onDismiss: releaseSheet(.measurePrefill)) { prefill in
                MeasureSheetView(initialKind: prefill.kind)
            }
            // Central "Erfassen" picker, as high as its rows, so the
            // user can dismiss without leaving the underlying tab; the row
            // selection cascades to the appropriate downstream surface.
            //
            // v0.5.2-A4 perf: the row callback only stages the action in
            // `pendingCaptureAction` and triggers dismissal — the actual
            // hand-off (Measure sheet / tab switch) runs in the
            // `.onChange(of: showCapturePicker) false`-edge below, removing
            // the ~350 ms Task.sleep that previously blocked first-paint.
            // Closing through the X or by dragging down leaves
            // `pendingCaptureAction == nil`, so the observer below no-ops, which
            // is exactly the cancel semantics we want.
            // On the phone the picker is a sheet from the bottom, as always. In a
            // regular window it is a popover on the "+" of the page in front
            // (`+CaptureButton`); without a "+" on screen (a diary page, More, a
            // pushed page) ⌘N or a link hangs it here, at the top centre.
            .sheet(isPresented: capturePickerBinding(.compact), onDismiss: capturePickerDidDismiss) {
                capturePicker
            }
            .popover(isPresented: capturePickerBinding(.regular), attachmentAnchor: .point(.top), arrowEdge: .top) {
                capturePicker
                    .frame(minWidth: CapturePickerPopover.minimumWidth, idealWidth: CapturePickerPopover.idealWidth)
                    .presentationCompactAdaptation(.sheet)
                    // A popover has no dismiss callback; its content leaving is the
                    // same moment for the sheet gate.
                    .onDisappear(perform: capturePickerDidDismiss)
            }
            .onChange(of: sizeClass) { _, newSizeClass in
                closeCapturePickerOnResize(to: newSizeClass)
            }
            // Central mood-entry surface. The redesigned
            // `MoodScreen` (Y10 5-icon Wie-geht's-dir hero + history + chart)
            // hosts every mood-entry path: central CTA, notification body-tap,
            // and the deep-link `mood.log.now` action. The legacy
            // `MoodQuickEntrySheet` (Unicode emoji selector) was retired —
            // the Y10 surface carries the icon pack the operator approved.
            .sheet(isPresented: $showMoodQuickEntrySheet, onDismiss: releaseSheet(.mood)) {
                // MoodScreen now OWNS its host-sheet detent (it grows from a
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
            .sheet(isPresented: $showMedicationQuickIntakeSheet, onDismiss: releaseSheet(.medicationQuickIntake)) {
                // A form sheet fitted to a scrolling page has no height to fit
                // to, so a regular window gives the sheet its height.
                MedicationQuickIntakeSheet(
                    onDismiss: { showMedicationQuickIntakeSheet = false }, onQueued: { surfaceQuickIntakeQueuedBanner() },
                    // The sheet's form follows the window, which the system presents in.
                    formHeight: QuickIntakeSheetPresentation.formHeight(sizeClass: windowSizeClass)
                )
            }
            // Gated cycle day-log capture. Reachable only via the
            // CapturePicker `.cycle` row, which the CycleGate hides for ineligible /
            // opted-out users — so this sheet is unreachable for them by construction.
            .sheet(isPresented: $showCycleCaptureSheet, onDismiss: releaseSheet(.cycle)) {
                if let container {
                    CycleCaptureSheet(
                        store: container.cycleStore,
                        healthKit: container.healthKit
                    )
                }
            }
            .onChange(of: showCapturePicker) { oldValue, newValue in
                // The picker has finished dismissing. Apply the
                // staged action on the next main-actor pass so SwiftUI has
                // committed the dismissal animation tear-down before we
                // present any follow-up sheet. The follow-up goes through the
                // sheet gate, which parks it until the picker's `onDismiss`.
                guard oldValue, !newValue else { return }
                applyPendingCaptureAction()
            }
            // Surface MoodQuickEntrySheet when a mood-reminder
            // action handler (or a tap on a MOOD_REMINDER push body) signals
            // intent via `router.requestMoodQuickEntry()`. The router bumps a
            // counter so identical re-requests still flip the sheet open even
            // if the previous edge hasn't dismissed yet — matches the
            // `captureTapPulse` pattern just above.
            .onChange(of: router.moodQuickEntryRequestCount) { oldValue, newValue in
                guard newValue > oldValue else { return }
                requestSheet(.mood)
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
                requestSheet(.medicationQuickIntake)
            }
            // Surface the type-prefilled measure sheet when the
            // Home Vorsorge tile signals "jetzt messen" via
            // `router.requestMeasure(prefill:)`. The router bumps a counter so
            // identical re-requests re-present even if the previous edge hasn't
            // dismissed — same pattern as the mood / medication observers above.
            .onChange(of: router.measurePrefillRequestCount) { oldValue, newValue in
                guard newValue > oldValue,
                      let kind = router.consumeMeasurePrefillKind() else { return }
                requestSheet(.measurePrefill(kind))
            }
            .onChange(of: router.selectedTab) { oldValue, newValue in
                if newValue == .measure {
                    // Bump the Pow trigger BEFORE we present the
                    // sheet so the medium-impact haptic + scale-jump fire on
                    // the tap, not on the sheet's settle frame. Same trigger
                    // value flows into CapturePickerSheet as `pulseTrigger`
                    // so the row group inherits the same beat.
                    openCapturePicker()
                    // Snap zurück auf den vorherigen echten Tab — der Action-Slot
                    // soll sich wie ein Button anfühlen, nicht wie ein Ziel.
                    // The tab to return to may have left the layout meanwhile.
                    router.selectResolved(oldValue == .measure ? lastDestinationTab : oldValue)
                } else {
                    lastDestinationTab = newValue
                }
            }
            .onChange(of: router.captureRequestCount) { openCapturePicker() }
    }
}

// `PrefilledMeasureKind` lives in `AuthenticatedShell+Capture.swift`;
// `AIConsentRequest` lives in `AuthenticatedShell+AIConsent.swift` — both to
// keep this file under the 600-line `file_length` swiftlint budget.
