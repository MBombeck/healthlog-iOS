import SwiftUI

// MARK: - Capture hand-off + re-tap-to-root

/// W-FILELEN — the central-Erfassen capture-action hand-off + the re-tap-to-root
/// binding, lifted verbatim out of `AuthenticatedShell` into this same-module
/// extension to keep the screen body under the 600-line `file_length` swiftlint
/// budget. Pure move, no behaviour change. The `@State` flags these read are
/// `internal` on the screen for exactly this reason.
extension AuthenticatedShell {
    /// v0.5.2-A4 — applies a staged `CaptureAction` once the picker has
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
    ///    `ShellSheetGate` (T1), which parks it until the picker's
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
            // v0.6.1.17 Y10.2 — present the redesigned Y10 `MoodScreen`
            // (5-icon Wie-geht's-dir hero) as a sheet. Pre-Y10.2 this
            // routed to the legacy `MoodQuickEntrySheet` with the
            // Unicode-emoji selector even though the Y10 redesign had
            // already shipped on the Mehr-tab MoodScreen. Operator wants
            // the redesigned surface to be the single mood-entry home.
            requestSheet(.mood)
        case .cycle:
            // v0.14.8 C4 — gated cycle day-log capture. The picker only ever
            // staged this when the CycleGate row was visible, so by the time we
            // present, eligibility already held.
            requestSheet(.cycle)
        }
    }

    // MARK: - T1 sheet gate

    /// #115 · 1.1 T1 — the only way a shell sheet flag turns on. The gate decides
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
        case .capturePicker: showCapturePicker = true
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

    /// #34 — re-tap-to-root detection. A SwiftUI `TabView`'s selection binding's
    /// `set` IS invoked when the user taps the already-selected tab (the value
    /// equals the current one), but `onChange(of:)` does NOT fire because the
    /// stored value is unchanged. So we interpose a proxy binding: on a `set`
    /// where the new value equals the current selection, the operator re-tapped
    /// the active tab → return that tab to its root, mirroring Settings/Mehr.
    func tabSelectionBinding(router: AppRouter) -> Binding<TabIdentifier> {
        Binding(
            get: { router.selectedTab },
            set: { newValue in
                if newValue == router.selectedTab {
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

/// v0.15 W-FRONTDOORS — wraps a `MetricKind` so it can drive a
/// `.sheet(item:)` for the type-prefilled measure sheet. The `id` re-uses the
/// kind's `rawValue` so re-requesting the same kind re-presents (the router's
/// counter is the freshness signal; the item identity gates SwiftUI's diffing).
struct PrefilledMeasureKind: Identifiable, Hashable {
    let kind: MetricKind
    var id: String {
        kind.rawValue
    }
}
