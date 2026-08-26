import Pow
import SwiftUI

/// v0.5.1-F3 / v0.5.2-A4 — Central "Erfassen" picker.
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
/// - **Liquid Glass sheet surface (iOS 26+)**: the picker's NavigationStack
///   root paints `.glassEffect(.regular, in:)` via `hlGlassBackground(in:)`.
///   iOS 18-25 falls back to `HLColor.background`. The rows themselves keep
///   the existing `hlGlassBackground` treatment — together this reads as a
///   layered glass stack on iOS 26, a flat-translucent surface elsewhere.
///
/// **Liquid Glass row treatment** — the picker rows use the existing
/// `hlGlassBackground(in:fallback:)` helper from `LiquidGlass.swift`. On
/// iOS 26+ this paints the rows as `.regular`-variant glass that floats
/// above the sheet background; on iOS 18-25 it falls back to
/// `HLColor.surface`.
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
        case cycle

        var id: String {
            rawValue
        }

        var titleKey: LocalizedStringKey {
            switch self {
            case .measurement: "capture.picker.measurement.title"
            case .medication: "capture.picker.medication.title"
            case .mood: "capture.picker.mood.title"
            case .cycle: "capture.picker.cycle.title"
            }
        }

        var subtitleKey: LocalizedStringKey {
            switch self {
            case .measurement: "capture.picker.measurement.subtitle"
            case .medication: "capture.picker.medication.subtitle"
            case .mood: "capture.picker.mood.subtitle"
            case .cycle: "capture.picker.cycle.subtitle"
            }
        }

        var systemImage: String {
            switch self {
            case .measurement: "plus.circle.fill"
            case .medication: "pills.fill"
            case .mood: "face.smiling"
            case .cycle: "drop.fill"
            }
        }

        var accessibilityIdentifier: String {
            "capture.picker.row.\(rawValue)"
        }
    }

    /// v0.5.2-A4 — Pow `changeEffect` trigger inherited from the parent
    /// (`AuthenticatedShell.captureTapPulse`). v0.5.2-R3 U-H1: kept on the
    /// public surface for source-compat (existing test suite + parent
    /// call-site still thread a value through), but the picker no longer
    /// binds it to any `.changeEffect`. The triple-row on-settle jump it
    /// used to drive read as stutter on real hardware. Per-row tap effects
    /// still fire via the private `rowTapBeat` state below.
    var pulseTrigger: Int = 0
    /// v0.14.8 C4 — whether to offer the gated `.cycle` row. The parent
    /// (`AuthenticatedShell`) resolves this from `CycleGate.isCycleTrackingAvailable`
    /// so the row is NEVER built for ineligible / opted-out users. Default
    /// `false` keeps every existing call-site + preview unchanged.
    var showsCycleRow: Bool = false
    let onSelect: (CaptureAction) -> Void
    /// v0.6.1 Y2 — retained on the public surface so the parent shell can
    /// still react to interactive-dismiss (drag-down) for analytics / state
    /// reset. The picker no longer surfaces a visible "Abbrechen" toolbar
    /// button; dismissal happens via the drag indicator (Home-Compliance
    /// sheet pattern — `docs/design-handbook-v1.md §2.6`). Parent fires
    /// `onCancel` from the `.sheet`'s automatic dismiss callback path.
    let onCancel: () -> Void
    /// v0.5.2-A4 — local row tap reaction. Each tap increments the
    /// per-row beat so the tapped row scales briefly before the sheet
    /// dismisses, separate from the parent-driven `pulseTrigger`.
    @State private var rowTapBeat: Int = 0
    @State private var tappedAction: CaptureAction?
    /// v0.14.1 W-CAPTURE-GAP — live height of the rendered row stack, used to
    /// fit the sheet detent to exactly the visible rows (see
    /// ``fittedSheetHeight``). `0` until the first geometry read lands, at
    /// which point ``fittedSheetHeight`` falls back to a row-count estimate.
    @State private var measuredContentHeight: CGFloat = 0
    /// Reduce-motion override — Pow effects are visual flourish, so
    /// the system reduce-motion preference disables both the jump and
    /// the optional shine, leaving haptics + the regular glass material.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HLSpace.md) {
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
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.md)
                .padding(.bottom, HLSpace.xl)
                // v0.14.1 W-CAPTURE-GAP — measure the actual rendered rows so
                // the sheet detent below fits them exactly. Measuring the
                // padded stack (not the ScrollView, which fills the detent)
                // yields the intrinsic content height regardless of row count
                // or Dynamic Type.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    measuredContentHeight = newHeight
                }
            }
            .scrollContentBackground(.hidden)
            .hlScreenBackground()
            .navigationTitle(Text("capture.picker.title"))
            .navigationBarTitleDisplayMode(.inline)
            // v0.6.1 Y2 — Home-Compliance sheet pattern: no toolbar chrome,
            // dismiss happens via the drag-indicator only. The parent
            // owns the `onCancel` plumbing via interactive-dismiss.
        }
        // v0.14.1 W-CAPTURE-GAP — fit the sheet to its rows instead of the
        // fixed `.medium` detent the picker used to inherit via
        // `hlSheetPresentation(.compact)`. `.medium` reserved ~half the screen
        // regardless of item count, so with only 3–4 short rows the operator
        // saw a large dead gap BELOW the last row ("below those it renders as
        // empty space"). A content-fitted `.height` detent collapses the sheet
        // to exactly the available rows — and shrinks further when the gated
        // `.cycle` row is absent, so a hidden entry leaves no gap. The
        // drag-indicator (the only dismiss affordance) is re-declared here
        // since the picker no longer routes through `hlSheetPresentation`.
        .presentationDetents([.height(fittedSheetHeight)])
        .presentationDragIndicator(.visible)
    }

    /// v0.14.1 W-CAPTURE-GAP — the sheet height that fits exactly the visible
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
    static let navigationChromeHeight: CGFloat = 52

    /// Pre-measurement height estimate for `rowCount` rows. Pure and strictly
    /// row-count-driven so a regression back to a fixed detent (dead space
    /// below the rows) is caught by a unit test.
    static func estimatedContentHeight(rowCount: Int) -> CGFloat {
        let rows = CGFloat(max(rowCount, 1))
        // 44 pt glyph frame + `md` vertical padding on both sides, rounded up
        // so the estimate never under-shoots a real row at default Dynamic Type.
        let rowHeight: CGFloat = 72
        let interRowSpacing = max(rows - 1, 0) * HLSpace.md
        return HLSpace.md /* top */ + rows * rowHeight + interRowSpacing + HLSpace.xl /* bottom */
    }

    /// The rows actually rendered. The gated `.cycle` row is appended ONLY
    /// when the parent passes `showsCycleRow` (resolved from `CycleGate`); an
    /// ineligible / opted-out user never sees — and the view never builds — it.
    private var visibleActions: [CaptureAction] {
        CaptureAction.allCases.filter { $0 != .cycle || showsCycleRow }
    }

    /// Test-only mirror of ``visibleActions`` (the property is private so it
    /// can't be reached from the test target directly).
    var visibleActionsForTesting: [CaptureAction] {
        visibleActions
    }

    // v0.6.1.12 Y9.2-A — inner `.background(HLColor.surface)` removed.
    // The Y9-A pass aligned the inner canvas token to `HLColor.surface`,
    // but operator real-device walkthrough still showed a lighter shade
    // than the HealthScore + AnstehendeEinnahmen sheets. Root cause: the
    // sister sheets do NOT paint an explicit inner background — they
    // rely on the `.presentationBackground(HLColor.surface)` at the
    // sheet root and let the chrome show through. The explicit inner
    // `.background(HLColor.surface)` layered over the chrome composited
    // slightly brighter (subtle opacity/material interaction). Dropping
    // the inner background brings CapturePickerSheet in line with every
    // other sheet in the app — single source of truth = the
    // `presentationBackground` modifier at the call site.
}

/// One row of the picker. Big-tap-target (≥ 64 pt) with a 40 pt SF Symbol
/// glyph, a `LocalizedStringKey` title, and a muted subtitle. Liquid Glass
/// on iOS 26+, `HLColor.surface` fallback on iOS 18-25.
///
/// v0.5.2-A4 + v0.5.2-R3 U-H1: the row carries a single Pow change-effect
/// chain bound to `rowTapBeat` — fires only for the tapped row, supplying
/// the medium haptic and a 6 pt scale jump. The previous parent-driven
/// `pulseTrigger`-on-settle pulse (every row jumping in unison) is gone:
/// QA flagged it as a triple-row stutter that read as motion noise rather
/// than affordance. `accessibilityReduceMotion` collapses the visual jump
/// but keeps the haptic, same as before.
private struct CapturePickerRow: View {
    let action: CapturePickerSheet.CaptureAction
    let rowTapBeat: Int
    let isTapped: Bool
    let reduceMotion: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HLSpace.md) {
                Image(systemName: action.systemImage)
                    .font(.hlIcon(HLIconSize.hero))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    // UI-MANIFEST §2: row title = `.hlSubhead.semibold`
                    // (card-on-canvas list-row idiom). `.hlHeadline` was
                    // card-headline-weight and read as visually heavy here
                    // — drift from Dashboard tile + Insights elongated card
                    // gold standards. `HLText.primary` instead of the
                    // legacy Dracula-tinted `HLText.primary` alias.
                    Text(action.titleKey)
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                    // v0.14.8 C4 — every row is exactly TWO LINES (title + a
                    // single-line subtitle). The medication subtitle copy used
                    // to wrap to a 2nd explanation line, making that row taller
                    // and reading as "weighted". `lineLimit(1)` + a tight
                    // `minimumScaleFactor` keep every row uniform; the copy was
                    // also shortened so no scale-down is needed in practice.
                    Text(action.subtitleKey)
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                HLDisclosureChevron()
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        // UI-MANIFEST §4: row card surface = `HLSurface.secondary` so the
        // iOS 18-25 fallback matches the Dashboard tile + Insights elongated
        // card. The hlGlassBackground default fallback was `HLColor.surface`
        // (Dracula-tinted) which produced the "manche Kacheln haben helleren
        // Hintergrund" drift the operator flagged.
        .hlGlassBackground(
            in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous),
            fallback: HLSurface.secondary
        )
        // V052-R3 U-H1 — dropped the parent-driven on-settle pulse
        // (`.changeEffect(.jump(height: 3), value: pulseTrigger, ...)`).
        // Three rows pulsing in unison on spring-settle read as stutter,
        // not affordance. The remaining per-row tap effect stays: jump
        // height 6 pt on the tapped row + medium haptic. `isEnabled:
        // !reduceMotion` collapses the visual jump but keeps the haptic.
        .changeEffect(.jump(height: 6), value: isTapped ? rowTapBeat : 0, isEnabled: !reduceMotion)
        .changeEffect(.feedback(hapticImpact: .medium), value: isTapped ? rowTapBeat : 0)
        .accessibilityIdentifier(action.accessibilityIdentifier)
        .accessibilityElement(children: .combine)
    }
}
