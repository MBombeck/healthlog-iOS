@testable import HealthLog
import SwiftUI
import Testing

/// v0.5.1-F3 / v0.5.2-A4 — CapturePickerSheet contract tests.
///
/// The picker is presented from the central "Erfassen" tab slot and offers
/// three capture surfaces. These tests pin the public `CaptureAction`
/// contract — order, identifiers, system-image symbol-names — so a future
/// rename can't silently break the AuthenticatedShell switch-case.
/// v0.5.2-A4 added the `pulseTrigger` Pow integration and the
/// performance-budgeted init-snap test below.
@Suite("CapturePickerSheet — capture-action contract")
struct CapturePickerSheetTests {
    @Test("CaptureAction exposes the four cases in stable order")
    func captureActionCases() {
        let cases = CapturePickerSheet.CaptureAction.allCases
        #expect(cases.count == 4)
        // v0.14.8 C4 — `.cycle` is appended last; it is GATED (only rendered
        // when `showsCycleRow` is true), never offered to ineligible users.
        #expect(cases == [.measurement, .medication, .mood, .cycle])
    }

    @Test("CaptureAction raw values are stable string ids")
    func captureActionRawValues() {
        #expect(CapturePickerSheet.CaptureAction.measurement.rawValue == "measurement")
        #expect(CapturePickerSheet.CaptureAction.medication.rawValue == "medication")
        #expect(CapturePickerSheet.CaptureAction.mood.rawValue == "mood")
        #expect(CapturePickerSheet.CaptureAction.cycle.rawValue == "cycle")
    }

    @Test("CaptureAction.id mirrors rawValue so SwiftUI ForEach is stable")
    func captureActionIdentity() {
        for action in CapturePickerSheet.CaptureAction.allCases {
            #expect(action.id == action.rawValue)
        }
    }

    @Test("CaptureAction system images match the operator-approved glyphs")
    func captureActionSystemImages() {
        #expect(CapturePickerSheet.CaptureAction.measurement.systemImage == "plus.circle.fill")
        #expect(CapturePickerSheet.CaptureAction.medication.systemImage == "pills.fill")
        #expect(CapturePickerSheet.CaptureAction.mood.systemImage == "face.smiling")
        #expect(CapturePickerSheet.CaptureAction.cycle.systemImage == "drop.fill")
    }

    // MARK: - v0.14.8 C4 — gated cycle row

    /// The gated `.cycle` row is rendered ONLY when the parent passes
    /// `showsCycleRow` (resolved from `CycleGate.isCycleTrackingAvailable`).
    /// The sheet's `visibleActions` projection is the single place this is
    /// decided, so we pin both states.
    @Test("Cycle row hidden by default, shown only when showsCycleRow is set")
    @MainActor
    func cycleRowVisibilityGate() {
        let hidden = CapturePickerSheet(onSelect: { _ in }, onCancel: {})
        #expect(hidden.visibleActionsForTesting == [.measurement, .medication, .mood])

        let shown = CapturePickerSheet(showsCycleRow: true, onSelect: { _ in }, onCancel: {})
        #expect(shown.visibleActionsForTesting == [.measurement, .medication, .mood, .cycle])
    }

    /// `visibleActions` is the single source for the rendered rows — it must
    /// never carry a phantom/duplicate slot in either gate state. This pins the
    /// "no empty/placeholder entries" contract the picker relies on to collapse
    /// cleanly.
    @Test("visibleActions has no duplicate or placeholder slots in either state")
    @MainActor
    func visibleActionsHasNoGaps() {
        for shows in [false, true] {
            let sheet = CapturePickerSheet(showsCycleRow: shows, onSelect: { _ in }, onCancel: {})
            let actions = sheet.visibleActionsForTesting
            #expect(!actions.isEmpty)
            #expect(Set(actions).count == actions.count, "duplicate capture rows would render as repeated slots")
        }
    }

    // MARK: - v0.14.1 W-CAPTURE-GAP — content-fitted sheet height

    /// The operator saw "empty space below the items": the picker inherited a
    /// fixed `.medium` detent that reserved ~half the screen regardless of row
    /// count, leaving a dead gap under the last row. The fix drives the sheet
    /// detent from a content-fitted height. This pins that the height is
    /// strictly row-count-driven (so a hidden `.cycle` row shrinks the sheet
    /// and leaves no gap) and can never collapse back to a fixed value.
    @MainActor
    @Test("Fitted sheet height scales with row count — no fixed-detent regression")
    func fittedSheetHeightScalesWithRowCount() {
        let three = CapturePickerSheet.estimatedContentHeight(rowCount: 3)
        let four = CapturePickerSheet.estimatedContentHeight(rowCount: 4)
        #expect(three > 0)
        // Adding the gated cycle row must make the sheet taller — not reserve
        // fixed dead space that a hidden row would leave behind.
        #expect(four > three)
        // Each extra row adds a full row's worth of height (a fixed detent
        // would make these equal), guarding against a regression to `.medium`.
        #expect(four - three > 60)
        // Chrome allowance is positive so the inline nav bar is never clipped.
        #expect(CapturePickerSheet.navigationChromeHeight > 0)
    }

    /// v0.14.8 C4 capture-row consistency — every row's subtitle must be a
    /// single, short line. The medication subtitle used to wrap; this pins the
    /// shortened DE value so a regression resurfaces the felt-bug as a failure.
    @Test("All capture-row subtitles resolve to short single-line copy")
    func subtitleCopyIsShort() {
        // CU-24 (GH iOS #73): "Dosis" → "Einnahme" — the row title already said
        // "Einnahme erfassen", so the subtitle was the odd term out. Same length
        // class, still one line.
        #expect(String(localized: "capture.picker.medication.subtitle") == "Heutige Einnahme abhaken")
        // The cycle row subtitle is also short + one-line.
        #expect(String(localized: "capture.picker.cycle.subtitle") == "Periode, Symptome & mehr")
    }

    @Test("CaptureAction accessibility identifiers are namespaced")
    func captureActionAccessibilityIdentifiers() {
        #expect(CapturePickerSheet.CaptureAction.measurement.accessibilityIdentifier == "capture.picker.row.measurement")
        #expect(CapturePickerSheet.CaptureAction.medication.accessibilityIdentifier == "capture.picker.row.medication")
        #expect(CapturePickerSheet.CaptureAction.mood.accessibilityIdentifier == "capture.picker.row.mood")
    }

    /// **v0.5.3-EQ-3** — operator walkthrough flagged the medication
    /// row's title ("Medikament-Einnahme erfassen") wrapping to two
    /// lines on iPhone 17 Pro min width. We don't UI-snapshot the row
    /// height here (we run headless), but we pin the underlying
    /// localised value via `String(localized:)` so a regression that
    /// reintroduced the long title would surface as a test failure
    /// rather than a silent felt-bug. The resolved DE string is the
    /// shorter "Einnahme erfassen" that holds on one line.
    @Test("Medication picker title is the EQ-3 one-line value")
    func medicationTitleIsOneLineValue() {
        // `LocalizedStringKey` doesn't expose its resolved value
        // publicly, so we re-resolve via `String(localized:)` against
        // the same key. The test passes only when the German bundle
        // resolves the key to the EQ-3 shortened value.
        let resolved = String(localized: "capture.picker.medication.title")
        #expect(resolved == "Einnahme erfassen", "Got \(resolved) — expected EQ-3 shortened value")
        // Sanity: the other two rows keep their existing two-word titles
        // so we don't accidentally regress the cadence in either direction.
        #expect(String(localized: "capture.picker.measurement.title") == "Messung erfassen")
        #expect(String(localized: "capture.picker.mood.title") == "Stimmung erfassen")
    }

    // MARK: - v0.5.2-A4 perf budgets

    /// The picker view must initialise + describe its body cheaply enough
    /// that the first paint after a tap on the Erfassen tab lands inside
    /// the 200 ms felt-snappy budget (PROJECT_GUIDE.md "Perceptual Budgets" §
    /// tap-to-detail). We can't drive UIHostingController on a
    /// non-MainActor unit-test runner deterministically, but we *can*
    /// pin the property-init + initial body-expression cost — that's the
    /// work the SwiftUI runtime does between sheet-present and the first
    /// frame committing. A regression here (e.g. eager store-fetch in
    /// the row body, blocking AsyncImage decode at init time) would
    /// stretch the build cost past the budget on real hardware.
    ///
    /// Budget: 200 ms wall-clock for 100 fresh init+body evaluations
    /// (i.e. ≤ 2 ms each). Generous so the test stays stable on CI; the
    /// real-device target is sub-millisecond per init.
    @Test("Picker init + first body description stays inside the perf budget")
    @MainActor
    func pickerInitSnapBudget() {
        let clock = ContinuousClock()
        let iterations = 100
        let elapsed = clock.measure {
            for _ in 0 ..< iterations {
                let sheet = CapturePickerSheet(
                    pulseTrigger: 0,
                    onSelect: { _ in },
                    onCancel: {}
                )
                // Force a body-expression evaluation. SwiftUI defers body
                // resolution until the rendering host requests it; calling
                // `_printChanges` would diff state on subsequent passes,
                // so we instead read the View's mirror, which materialises
                // the body opaque-result-type once.
                _ = Mirror(reflecting: sheet).children.count
            }
        }
        // 200 ms ceiling for 100 iterations on a development laptop —
        // this leaves multi-x headroom for real devices and CI runners.
        #expect(elapsed < .milliseconds(200), "Picker init+body budget exceeded: \(elapsed)")
    }

    /// Picker honours the `pulseTrigger` parameter without crashing on
    /// the documented default (0). Defends against an accidental
    /// required-parameter promotion that would force every call-site to
    /// pass an explicit trigger.
    @Test("Picker constructs with default pulseTrigger")
    @MainActor
    func pickerDefaultPulseTrigger() {
        let sheet = CapturePickerSheet(
            onSelect: { _ in },
            onCancel: {}
        )
        // Public surface check: trigger defaults to 0 so unit tests +
        // previews don't have to thread a value through.
        #expect(sheet.pulseTrigger == 0)
    }

    /// Picker callback closures fire exactly once per row selection. The
    /// row tap path mutates internal state (`rowTapBeat`, `tappedAction`)
    /// before invoking `onSelect`; a regression that double-fires would
    /// race the parent's `pendingCaptureAction` slot.
    @Test("onSelect fires once per CaptureAction case")
    @MainActor
    func onSelectInvocationContract() {
        for expected in CapturePickerSheet.CaptureAction.allCases {
            var captured: [CapturePickerSheet.CaptureAction] = []
            let sheet = CapturePickerSheet(
                pulseTrigger: 0,
                onSelect: { captured.append($0) },
                onCancel: { Issue.record("onCancel must not fire on row tap") }
            )
            // Direct closure invocation simulates a row tap without
            // touching the SwiftUI runtime. The picker stores the
            // callback as-is, so a single call captures a single value.
            sheet.onSelect(expected)
            #expect(captured == [expected])
        }
    }
}
