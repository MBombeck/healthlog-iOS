import SwiftUI

public struct HLRing: View {
    private let progress: Double // 0...1
    private let label: String?
    private let value: String?
    /// VoiceOver label for the combined ring element. When `nil`, falls back
    /// to the visible `label` (so an un-wrapped ring still reads with context
    /// where one was given). Callers whose visible `label` is a bare word
    /// like "today" should pass a fully-framed label here (e.g. "Medication
    /// compliance today") so VoiceOver doesn't announce only the value.
    /// (Audit H2.)
    private let accessibilityLabelOverride: String?
    /// `nil` ⇒ auto-derive from the ring's side via `HLRing.derivedStroke(forSide:)`.
    /// An explicit value is respected as an override (legacy callers / special cases).
    private let lineWidthOverride: CGFloat?
    private let tint: Color

    /// Geometrische Basis-Ratio (Wert-Font = side × ratio). Über `@ScaledMetric`
    /// skaliert der Multiplier mit Dynamic-Type — bei Accessibility-Größen
    /// wächst der innere Zahlenwert zusammen mit dem Container, statt im Ring
    /// zu schrumpfen. (Audit M5/M6.)
    @ScaledMetric(relativeTo: .title) private var fontRatio: CGFloat = 0.22

    /// v0.11 (AUDIT-FINAL §L1) — the ring's progress sweep must respect the
    /// 200–300 ms doctrine budget AND the reduce-motion gate. The prior
    /// `.easeOut(duration: 0.6)` both overshot the budget and animated
    /// unconditionally; we now drop to 0.28 s and fall to an instant `nil`
    /// animation under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Withings-Proportion: Stroke = `side × strokeRatio`. 60pt→5pt, 92pt→8pt,
    /// 140pt→12pt. Untere Schranke 6pt verhindert „Faden"-Optik bei Mini-Rings
    /// (Skeleton-Placeholders, Activity-Rings in 1×1-Tiles).
    /// Quelle: `.planning/v05x-marathon/R2-visual-design-spec.md` §"Primitive #2".
    public nonisolated static let strokeRatio: CGFloat = 0.085
    public nonisolated static let minStroke: CGFloat = 6

    /// Pure helper — als `static` extrahiert, damit der Stroke-Derivations-
    /// Vertrag in Swift-Testing-Suite (`HLRingStrokeTests`) ohne SwiftUI-Host
    /// verifizierbar ist. `nonisolated`, weil die Funktion ausschließlich auf
    /// `CGFloat`-Arithmetik beruht und keine `View`-/MainActor-Bindings
    /// braucht — sonst zwingt `View`s implizite `@MainActor`-Isolation
    /// Tests in eine `@MainActor`-Suite (Swift 6 / strict concurrency).
    /// Withings-Reference: 8.5 % des Ring-Durchmessers.
    public nonisolated static func derivedStroke(forSide side: CGFloat) -> CGFloat {
        max(minStroke, side * strokeRatio)
    }

    public init(
        progress: Double,
        label: String? = nil,
        value: String? = nil,
        lineWidth: CGFloat? = nil,
        tint: Color = HLChartTints.series,
        accessibilityLabel: String? = nil
    ) {
        self.progress = max(0, min(1, progress))
        self.label = label
        self.value = value
        lineWidthOverride = lineWidth
        self.tint = tint
        accessibilityLabelOverride = accessibilityLabel
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stroke = lineWidthOverride ?? HLRing.derivedStroke(forSide: side)
            ZStack {
                // 1. Track — `HLText.primary @ HLChartGrid.lineOpacity` (10 %).
                //    Theme-2.0 (T2-2): trimmed from textTertiary @ 18 % so the
                //    track sits as a barely-there hairline matching the chart-
                //    gridline tier (`HLChartGrid.lineOpacity`). The ring still
                //    reads complete on `HLSurface.secondary` cards because the
                //    primary-text base hue gives clean contrast on warm-grey/
                //    charcoal. R2 #2 / Theme-2.0.
                Circle()
                    .stroke(
                        HLText.primary.opacity(HLChartGrid.lineOpacity),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                    )
                // 2. Foreground — flat single accent (no AngularGradient, no
                //    70→100% smudge). Default tint resolves to
                //    `HLChartTints.series` → `HLColor.inkGraphite` (refined
                //    graphite, v0.14 light-mode walk; was near-black
                //    `HLText.primary`). Withings-Look. R2 #2.
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: progress)

                VStack(spacing: HLSpace.xxs) {
                    if let value {
                        Text(value)
                            .font(.hlMetric(side * fontRatio))
                            .foregroundStyle(HLText.primary)
                            .monospacedDigit()
                            // v0.12 W3-1 — the hero number must roll like the
                            // small dashboard tiles (`HLDashboardTile.valueRow`
                            // → `.contentTransition(.numericText())`), not pop
                            // from skeleton to value. The score is the biggest,
                            // most-watched number on the selling-page surface;
                            // shipping it without a count-up inverted the polish
                            // hierarchy. Gated through `.hlAnimation` so Reduce
                            // Motion falls to an instant swap (env-gated, not
                            // just the native cross-fade).
                            .contentTransition(.numericText())
                            .hlAnimation(.snappy(duration: 0.25), value: value)
                    }
                    if let label {
                        Text(label)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                    }
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(Text(value ?? String(localized: "\(Int(progress * 100)) percent")))
    }

    /// Resolves the VoiceOver label: an explicit override first, else the
    /// visible `label`, else an empty string (value-only — prior behaviour).
    private var accessibilityLabelText: Text {
        Text(accessibilityLabelOverride ?? label ?? "")
    }
}

#Preview("HLRing") {
    HStack(spacing: HLSpace.lg) {
        HLRing(progress: 0.66, label: "heute", value: "4/6")
            .frame(width: 140, height: 140)
        HLRing(progress: 0.92, label: "Compliance", value: "92%")
            .frame(width: 140, height: 140)
    }
    .padding()
    .background(HLSurface.primary)
}
