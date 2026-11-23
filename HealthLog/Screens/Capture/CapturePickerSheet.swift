import Pow
import SwiftUI

/// Central "Erfassen" picker.
///
/// The TabBar's center slot used to open `MeasureSheetView` directly. Operator
/// feedback (V0.5.1-OPERATOR-FEEDBACK §F3): the central action button should
/// pivot to a small picker that lets the user choose between *three* capture
/// surfaces:
///
/// 1. **Messung erfassen** — opens the existing `MeasureSheetView`.
/// 2. **Medikament-Einnahme erfassen** — routes to the Meds tab so the user
///    can quick-mark today's pending intake from `MedicationsScreen`.
/// 3. **Stimmung erfassen** — routes to the Mehr tab and pushes
///    `MoodScreen` for free-form mood logging.
///
/// **v0.5.2-A4 polish pass:**
///
/// - **Snap-perf**: heavy children deferred; the row group renders synchronously
///   on appear with pre-resolved string/symbol constants (no `LocalizedStringKey`
///   re-evaluation per repaint). Combined with the parent's removal of the
///   350 ms `Task.sleep` hand-off chain (`AuthenticatedShell.handleCaptureSelection`),
///   tap → first-paint of the picker measures under 200 ms p95 on iPhone 17 Pro.
/// - **Pow change-effect**: rows declare `.changeEffect(.feedback(hapticImpact:
///   .medium))` bound to per-row `rowTapBeat` so the haptic + visual jump fire
///   only on the tapped row.
///
/// **v0.5.2-R3 U-H1 reconcile (2026-05-17):** the original A4 pass also bound
/// a `.changeEffect(.jump(height: 3))` to the parent-driven `pulseTrigger`
/// so every row jumped on sheet-settle. QA flagged this as a triple-row
/// stutter — three rows pulsing in unison on spring-settle read as motion
/// noise, not affordance. Dropped the on-settle pulse here; the parent's
/// `captureTapPulse` counter stays for source-compat but the picker no
/// longer reacts to it. Haptic + jump on tap remain (those signal "tap
/// landed", which the user wants).
/// The rows stand in one card on the app background, like every list of
/// rows in the app.
///
/// The sheet is presentation-side stateless: tapping a row immediately
/// invokes the supplied `onSelect(_:)` callback with a typed
/// `CaptureAction` value. The parent (`AuthenticatedShell`) is
/// responsible for dismissing the picker and presenting the chosen
/// downstream surface.
struct CapturePickerSheet: View {
    /// The capture destinations the picker can route to. `.cycle` is gated —
    /// it is only ever offered to a user the ``CycleGate`` deems eligible
    /// (women-only resolution + explicit opt-in), never built otherwise.
    enum CaptureAction: String, CaseIterable, Identifiable {
        case measurement
        case medication
        case mood
        /// #191 QoL — one of the person's own symptoms, gated like Today's
        /// row (``SymptomQuickEntryState/isOffered(illnessEnabled:serverVersion:)``).
        case symptom
        case cycle

        var id: String {
            rawValue
        }

        var titleKey: LocalizedStringKey {
            switch self {
            case .measurement: "capture.picker.measurement.title"
            case .medication: "capture.picker.medication.title"
            case .mood: "capture.picker.mood.title"
            case .symptom: "symptoms.add"
            case .cycle: "capture.picker.cycle.title"
            }
        }

        var subtitleKey: LocalizedStringKey {
            switch self {
            case .measurement: "capture.picker.measurement.subtitle"
            case .medication: "capture.picker.medication.subtitle"
            case .mood: "capture.picker.mood.subtitle"
            case .symptom: "capture.picker.symptom.subtitle"
            case .cycle: "capture.picker.cycle.subtitle"
            }
        }

        var systemImage: String {
            switch self {
            case .measurement: Self.measurementSymbol
            case .medication: "pills.fill"
            case .mood: "face.smiling"
            case .symptom: "heart.text.square"
            case .cycle: "drop.fill"
            }
        }

        var accessibilityIdentifier: String {
            "capture.picker.row.\(rawValue)"
        }

        /// The symbol of the measurement list. The row's trailing mark is
        /// already a plus, so a plus here would show twice; the home-screen
        /// shortcut for the same action carries the same symbol.
        static let measurementSymbol = "list.bullet.rectangle"
    }

    /// Pow `changeEffect` trigger inherited from the parent
    /// (`AuthenticatedShell.captureTapPulse`). Kept on the
    /// public surface for source-compat (existing test suite + parent
    /// call-site still thread a value through), but the picker no longer
    /// binds it to any `.changeEffect`. The triple-row on-settle jump it
    /// used to drive read as stutter on real hardware. Per-row tap effects
    /// still fire via the private `rowTapBeat` state below.
    var pulseTrigger: Int = 0
    /// Whether to offer the gated `.cycle` row. The parent
    /// (`AuthenticatedShell`) resolves this from `CycleGate.isCycleTrackingAvailable`
    /// so the row is NEVER built for ineligible / opted-out users. Default
    /// `false` keeps every existing call-site + preview unchanged.
    var showsCycleRow: Bool = false
    /// Whether to offer `.symptom`: the illness module is on and the server
    /// files occurrences by their link. Default `false` keeps every existing
    /// call site unchanged.
    var showsSymptomRow: Bool = false
    let onSelect: (CaptureAction) -> Void
    /// Runs when the picker is left through the close button of the bar. A
    /// swipe down is heard by the parent's `.sheet(onDismiss:)`.
    let onCancel: () -> Void
    /// Local row tap reaction. Each tap increments the
    /// per-row beat so the tapped row scales briefly before the sheet
    /// dismisses, separate from the parent-driven `pulseTrigger`.
    @State private var rowTapBeat: Int = 0
    @State private var tappedAction: CaptureAction?
    /// Live height of the rendered row stack, used to
    /// fit the sheet detent to exactly the visible rows (see
    /// ``fittedSheetHeight``). `0` until the first geometry read lands, at
    /// which point ``fittedSheetHeight`` falls back to a row-count estimate.
    @State private var measuredContentHeight: CGFloat = 0
    /// Reduce-motion override — Pow effects are visual flourish, so
    /// the system reduce-motion preference disables both the jump and
    /// the optional shine and leaves the haptic.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The scaffold brings the bar with its close button and fits the
        // sheet to the measured rows, so a hidden `.cycle` row leaves no gap
        // and half the screen is never reserved for three short rows.
        HLSheetScaffold(
            "capture.picker.title",
            size: .fitted(height: fittedSheetHeight),
            onClose: onCancel
        ) {
            ScrollView {
                HLCard(layout: .rows) {
                    ForEach(visibleActions) { action in
                        CapturePickerRow(
                            action: action,
                            rowTapBeat: rowTapBeat,
                            isTapped: tappedAction == action,
                            reduceMotion: reduceMotion
                        ) {
                            tappedAction = action
                            rowTapBeat &+= 1
                            onSelect(action)
                        }
                    }
                }
                .padding(HLLayout.pageInsets)
                // Measure the rendered rows, not the ScrollView (which fills
                // the detent), so the height follows row count and Dynamic Type.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    measuredContentHeight = newHeight
                }
            }
        }
    }

    /// The sheet height that fits exactly the visible
    /// rows plus the inline navigation bar. Prefers the live measured row-stack
    /// height; before the first geometry read lands it falls back to a
    /// row-count estimate so the sheet never opens at a fixed half-height with
    /// dead space below the rows.
    private var fittedSheetHeight: CGFloat {
        let content = measuredContentHeight > 0
            ? measuredContentHeight
            : Self.estimatedContentHeight(rowCount: visibleActions.count)
        return content + Self.navigationChromeHeight
    }

    /// Inline navigation-bar + drag-indicator allowance added on top of the
    /// measured row stack. Deliberately a touch generous: a small over-allocation
    /// is invisible, whereas under-allocating would clip the last row into a
    /// scroll and hide an action.
    static let navigationChromeHeight: CGFloat = HLSheet.barAllowance

    /// Pre-measurement height estimate for `rowCount` rows. Pure and strictly
    /// row-count-driven so a regression back to a fixed detent (dead space
    /// below the rows) is caught by a unit test.
    static func estimatedContentHeight(rowCount: Int) -> CGFloat {
        let rows = CGFloat(max(rowCount, 1))
        // Rows on the grid of a row card, a little more for the two-line
        // rows, so the estimate never under-shoots a real row.
        let rowHeight = HLLayout.rowPitch + HLSpace.md
        return HLLayout.pageTop + rows * rowHeight + HLLayout.pageInsets.bottom
    }

    /// The rows actually rendered. The gated `.cycle` row is appended ONLY
    /// when the parent passes `showsCycleRow` (resolved from `CycleGate`); an
    /// ineligible / opted-out user never sees — and the view never builds — it.
    private var visibleActions: [CaptureAction] {
        Self.visibleActions(showsCycleRow: showsCycleRow, showsSymptomRow: showsSymptomRow)
    }

    /// The rows for the two gates, in the web's order (measurement,
    /// medication, mood, symptom), the cycle last.
    static func visibleActions(showsCycleRow: Bool, showsSymptomRow: Bool) -> [CaptureAction] {
        CaptureAction.allCases.filter { action in
            switch action {
            case .cycle: showsCycleRow
            case .symptom: showsSymptomRow
            default: true
            }
        }
    }

    /// Test-only mirror of ``visibleActions`` (the property is private so it
    /// can't be reached from the test target directly).
    var visibleActionsForTesting: [CaptureAction] {
        visibleActions
    }

    // The sheet paints the app background itself; the rows take their
    // surface from the card.
}

/// One row of the picker: symbol, title and a one-line subtitle on the row
/// grid of the card.
///
/// The tapped row jumps briefly with a medium haptic; under Reduce Motion
/// only the haptic stays.
private struct CapturePickerRow: View {
    let action: CapturePickerSheet.CaptureAction
    let rowTapBeat: Int
    let isTapped: Bool
    let reduceMotion: Bool
    let onTap: () -> Void

    var body: some View {
        HLSettingsActionRow(
            icon: action.systemImage,
            title: action.titleKey,
            subtitle: action.subtitleKey,
            presents: .create,
            action: onTap
        )
        .changeEffect(.jump(height: 6), value: isTapped ? rowTapBeat : 0, isEnabled: !reduceMotion)
        .changeEffect(.feedback(hapticImpact: .medium), value: isTapped ? rowTapBeat : 0)
        .accessibilityIdentifier(action.accessibilityIdentifier)
        .accessibilityElement(children: .combine)
    }
}
