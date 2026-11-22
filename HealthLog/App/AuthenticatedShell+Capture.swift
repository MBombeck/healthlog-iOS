import SwiftUI

// MARK: - Capture hand-off + re-tap-to-root

/// The central-Erfassen capture-action hand-off + the re-tap-to-root
/// binding, lifted verbatim out of `AuthenticatedShell` into this same-module
/// extension to keep the screen body under the 600-line `file_length` swiftlint
/// budget. Pure move, no behaviour change. The `@State` flags these read are
/// `internal` on the screen for exactly this reason.
extension AuthenticatedShell {
    /// Applies a staged `CaptureAction` once the picker has
    /// finished dismissing. v0.5.3-EQ-1 + EQ-2 moved both downstream
    /// `.medication` + `.mood` arms onto dedicated sheets so all three
    /// picker actions hand off via the same dismiss-then-present
    /// pattern (no more navigation jumps inline with a sheet dismiss).
    ///
    /// The previous implementation fired three blanket `Task.sleep(350ms)`
    /// chains: one per case, regardless of whether the destination was a
    /// sheet (where iOS strictly does need the parent sheet torn down
    /// first) or a tab-switch (where it doesn't). On real ProMotion
    /// hardware this produced a sticky 350 ms blank between picker tap
    /// and visible content — fatal for the "snappy" felt-budget.
    ///
    /// The new flow lives entirely in sheet hand-offs:
    ///
    /// 1. Picker row tap → store action in `pendingCaptureAction`,
    ///    set `showCapturePicker = false` (kicks off the iOS dismiss
    ///    animation which runs ~250-300 ms).
    /// 2. `.onChange(of: showCapturePicker)` observes the `true → false`
    ///    edge and calls this method on the next runloop pass.
    /// 3. Each case requests its destination sheet through the shell's
    ///    `ShellSheetGate`, which parks it until the picker's
    ///    `onDismiss` reports the dismissal finished, then flips the flag.
    func applyPendingCaptureAction() {
        guard let action = pendingCaptureAction else { return }
        pendingCaptureAction = nil
        switch action {
        case .measurement:
            requestSheet(.measure)
        case .medication:
            // v0.5.3-EQ-1 — direct intake-confirm surface. Previously
            // flipped the tab to `.meds` and dumped the operator on
            // `MedicationsScreen` to find their pending row + tap the
            // leading ✓. Operator feedback: "Ich kann es auch nicht mehr
            // bearbeiten, wenn ich es da aus versehen drauf gedrückt
            // habe oder so" — no confirm step, no obvious back-out path.
            // The new sheet hosts a confirm screen with explicit
            // commit + cancel before the optimistic mark fires.
            requestSheet(.medicationQuickIntake)
        case .mood:
            // Present the redesigned Y10 `MoodScreen`
            // (5-icon Wie-geht's-dir hero) as a sheet. Pre-Y10.2 this
            // routed to the legacy `MoodQuickEntrySheet` with the
            // Unicode-emoji selector even though the Y10 redesign had
            // already shipped on the Mehr-tab MoodScreen. Operator wants
            // the redesigned surface to be the single mood-entry home.
            requestSheet(.mood)
        case .symptom:
            // #191 QoL — the symptom quick entry is a pushed page on Today
            // (no presenter of its own), so the router lands there.
            router.requestSymptomQuickEntry()
        case .cycle:
            // Gated cycle day-log capture. The picker only ever
            // staged this when the CycleGate row was visible, so by the time we
            // present, eligibility already held.
            requestSheet(.cycle)
        }
    }

    // MARK: - Sheet gate

    /// The only way a shell sheet flag turns on. The gate decides
    /// present / park / drop (see `ShellSheetGate`); the AI consent sheet counts
    /// as an occupied stage so nothing preempts it either.
    func requestSheet(_ sheet: ShellSheetGate.Sheet) {
        if sheet == .capturePicker { recoverStaleSheetGate() }
        guard case let .present(next) = sheetGate.request(sheet, blocked: pendingConsentProvider != nil) else { return }
        show(next)
    }

    /// A shell sheet finished dismissing: release the stage and present the
    /// parked request, if any.
    func sheetDidDismiss(_ slot: ShellSheetGate.Slot) {
        guard let next = sheetGate.didDismiss(slot, blocked: pendingConsentProvider != nil) else { return }
        show(next)
    }

    /// The `onDismiss` handler for the sheet in `slot` (a function value, so the
    /// `.sheet` call sites keep their trailing content closure).
    func releaseSheet(_ slot: ShellSheetGate.Slot) -> () -> Void {
        { sheetDidDismiss(slot) }
    }

    /// The consent sheet left the stage — hand it to a parked request.
    func resumeParkedSheet() {
        guard let next = sheetGate.resume() else { return }
        show(next)
    }

    /// Flips the flag for `sheet`, but only once the window's root controller is
    /// not mid-transition. A foreign presentation still on screen (the Insights
    /// zoom chart cover, a context menu) is preempted by SwiftUI; presenting
    /// without animation then makes that preemption non-animated, which keeps
    /// UIKit's zoom morph — the 286 crash site — out of the path.
    func show(_ sheet: ShellSheetGate.Sheet, attempt: Int = 0) {
        let plan = ShellPresentationStage.current().plan
        if plan == .wait, attempt < Self.stageWaitAttempts {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                show(sheet, attempt: attempt + 1)
            }
            return
        }
        guard plan == .presentAnimated else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { flipSheetFlag(sheet) }
            return
        }
        flipSheetFlag(sheet)
    }

    /// ~1 s of 50 ms polls for a foreign transition to settle before we present
    /// anyway (without animation).
    static let stageWaitAttempts = 20

    private func flipSheetFlag(_ sheet: ShellSheetGate.Sheet) {
        switch sheet {
        case .capturePicker:
            // The form is fixed for as long as the picker is up; a change of
            // width closes it instead of moving it between sheet and popover.
            let form = CapturePickerPopover.form(for: sizeClass)
            capturePickerForm = form
            // The popover hangs on the "+" of the tab root on screen; without
            // one (a section, More, a pushed page) at the top of the window.
            captureAnchor.presentingTab = ShellCaptureAnchor.presentingTab(
                form: form,
                visibleTab: captureAnchor.visibleTab,
                selectedTab: router.selectedTab
            )
            showCapturePicker = true
        case .measure: showMeasureSheet = true
        case let .measurePrefill(kind): measurePrefillKind = PrefilledMeasureKind(kind: kind)
        case .mood: showMoodQuickEntrySheet = true
        case .medicationQuickIntake: showMedicationQuickIntakeSheet = true
        case .cycle: showCycleCaptureSheet = true
        }
    }

    /// Safety valve: if the gate still holds a sheet although none of the shell
    /// flags is on and nothing is presented, an `onDismiss` was lost. Release the
    /// gate rather than leave "+" dead for the rest of the session.
    private func recoverStaleSheetGate() {
        guard !sheetGate.isIdle,
              !showCapturePicker, !showMeasureSheet, measurePrefillKind == nil,
              !showMoodQuickEntrySheet, !showMedicationQuickIntakeSheet, !showCycleCaptureSheet,
              ShellPresentationStage.current() == .clear else { return }
        sheetGate = ShellSheetGate()
    }

    /// v0.5.3-EQ-1 — surfaces the queued-toast banner above the TabView
    /// when a medication-quick-intake mark landed in the outbox (retriable
    /// network error). Mirrors the 3-second auto-dismiss behaviour
    /// `MedicationsScreen.handleQuickMark` uses for its in-screen banner.
    func surfaceQuickIntakeQueuedBanner() {
        quickIntakeQueuedAt = .now
        quickIntakeQueuedTask?.cancel()
        quickIntakeQueuedTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                quickIntakeQueuedAt = nil
            }
        }
    }

    /// Re-tap-to-root detection. A SwiftUI `TabView`'s selection binding's
    /// `set` IS invoked when the user taps the already-selected tab (the value
    /// equals the current one), but `onChange(of:)` does NOT fire because the
    /// stored value is unchanged. So we interpose a proxy binding: on a `set`
    /// where the new value equals the current selection, the operator re-tapped
    /// the active tab → return that tab to its root, mirroring Settings/Mehr.
    ///
    /// The getter goes through `AppRouter.resolve` for `layout`, so the
    /// `TabView` never sees a sidebar tab it does not build.
    func tabSelectionBinding(router: AppRouter, layout: ShellLayout) -> Binding<TabIdentifier> {
        Binding(
            get: { router.displayedTab(in: layout) },
            set: { newValue in
                if newValue == router.displayedTab(in: layout) {
                    // Re-tap on the active tab → pop to root.
                    switch newValue {
                    case .insights:
                        // Pager-driven surface: reset to Übersicht (index 0) +
                        // pop the shared Insights stack via the router counter.
                        router.requestInsightsRoot()
                    case .home:
                        router.homePath = .init()
                    case .meds:
                        router.medsPath = .init()
                    case .more:
                        router.morePath = .init()
                    case let .section(destination):
                        router.setSectionPath(.init(), for: destination)
                    case .measure:
                        // Action slot — never a real destination; nothing to pop.
                        break
                    }
                }
                router.selectedTab = newValue
            }
        )
    }
}

/// Wraps a `MetricKind` so it can drive a
/// `.sheet(item:)` for the type-prefilled measure sheet. The `id` re-uses the
/// kind's `rawValue` so re-requesting the same kind re-presents (the router's
/// counter is the freshness signal; the item identity gates SwiftUI's diffing).
struct PrefilledMeasureKind: Identifiable, Hashable {
    let kind: MetricKind
    var id: String {
        kind.rawValue
    }
}

// MARK: - Quick intake presentation

/// The quick-intake sheet in a regular window. Its scaffold asks for a form
/// sheet as tall as its content, but the content is a scrolling page, which
/// has no height of its own: the sheet stood as its bar alone. A regular
/// window gives it a fixed height, bar included, that holds the "nothing
/// due" card, the slots still to come and the manual log; more scrolls.
enum QuickIntakeSheetPresentation {
    static let regularFormHeight: CGFloat = 560

    /// The sheet's form height: set in a regular window, none in a compact
    /// one, where the bottom sheet's detents decide.
    static func formHeight(sizeClass: UserInterfaceSizeClass?) -> CGFloat? {
        sizeClass == .regular ? regularFormHeight : nil
    }
}

// MARK: - Capture picker presentation

/// The width of the capture picker as a popover: a phone's width, so the
/// rows read as in the sheet.
enum CapturePickerPopover {
    static let minimumWidth: CGFloat = 320
    static let idealWidth: CGFloat = 375

    /// Whether the picker is a popover: in a regular window only.
    static func isPopover(sizeClass: UserInterfaceSizeClass?) -> Bool {
        sizeClass == .regular
    }

    /// The form the picker takes when it opens in a window of `sizeClass`.
    static func form(for sizeClass: UserInterfaceSizeClass?) -> UserInterfaceSizeClass {
        isPopover(sizeClass: sizeClass) ? .regular : .compact
    }

    /// Which presentation shows the picker: only the one fixed when it
    /// opened, never both, so a change of width cannot hand it from one to
    /// the other while the gate believes it is closed.
    static func shows(_ form: UserInterfaceSizeClass, isOpen: Bool, fixedForm: UserInterfaceSizeClass?) -> Bool {
        isOpen && fixedForm == form
    }

    /// Whether a change of width closes the open picker: when the window
    /// would now want the other form. The gate is released only when the
    /// closing has finished (the presentation's own dismiss callback).
    static func closesOnResize(isOpen: Bool, fixedForm: UserInterfaceSizeClass?, newSizeClass: UserInterfaceSizeClass?) -> Bool {
        guard isOpen, let fixedForm else { return false }
        return form(for: newSizeClass) != fixedForm
    }
}

extension AuthenticatedShell {
    /// The picker's flag, seen by the one presentation that fits the window.
    func capturePickerBinding(_ form: UserInterfaceSizeClass) -> Binding<Bool> {
        Binding(
            get: {
                CapturePickerPopover.shows(form, isOpen: showCapturePicker, fixedForm: capturePickerForm)
                    && (form == .compact || captureAnchor.presentingTab == nil)
            },
            set: { showCapturePicker = $0 }
        )
    }

    /// The window changed its width while the picker is up: close it rather
    /// than let it jump between sheet and popover. The gate stays taken until
    /// the dismiss callback of the form that was showing.
    func closeCapturePickerOnResize(to newSizeClass: UserInterfaceSizeClass?) {
        guard CapturePickerPopover.closesOnResize(
            isOpen: showCapturePicker,
            fixedForm: capturePickerForm,
            newSizeClass: newSizeClass
        ) else { return }
        pendingCaptureAction = nil
        showCapturePicker = false
    }

    /// The picker left the screen: release the gate and the fixed form.
    func capturePickerDidDismiss() {
        capturePickerForm = nil
        captureAnchor.presentingTab = nil
        sheetDidDismiss(.capturePicker)
    }

    /// The Log action: the haptic beat first, then the picker through the
    /// gate, so a re-tap while a capture surface is up or still animating
    /// is dropped instead of preempting it.
    func openCapturePicker() {
        captureTapPulse &+= 1
        requestSheet(.capturePicker)
    }

    /// What a tab root's "+" needs: open the picker, its popover flag for
    /// that root, the picker and its dismissal.
    var captureEntry: ShellCaptureEntry {
        ShellCaptureEntry(
            anchor: captureAnchor,
            open: { router.requestCapture() },
            isPresented: { tab in
                Binding(
                    get: {
                        CapturePickerPopover.shows(.regular, isOpen: showCapturePicker, fixedForm: capturePickerForm)
                            && captureAnchor.presentingTab == tab
                    },
                    set: { showCapturePicker = $0 }
                )
            },
            picker: { AnyView(capturePicker) },
            didDismiss: { capturePickerDidDismiss() }
        )
    }

    /// The picker itself, the same in sheet and popover.
    var capturePicker: some View {
        CapturePickerSheet(
            pulseTrigger: captureTapPulse,
            // Offer the gated cycle row only when the CycleGate deems the user
            // eligible (women-only resolution + explicit opt-in).
            showsCycleRow: container?.cycleGate.isCycleTrackingAvailable ?? false,
            // Offered where Today offers "Symptom erfassen".
            showsSymptomRow: SymptomQuickEntryState.isOffered(
                illnessEnabled: container?.moduleGate.isEnabled(.illness) ?? false,
                serverVersion: UserDefaults.standard.string(forKey: KnownServerVersion.defaultsKey)
            ),
            onSelect: { action in
                pendingCaptureAction = action
                showCapturePicker = false
            },
            onCancel: {
                pendingCaptureAction = nil
                showCapturePicker = false
            }
        )
    }
}
