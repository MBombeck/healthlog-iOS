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

    /// Untere Schranke, auf die der Wert im Ring schrumpfen darf, bevor er
    /// abgeschnitten wird — 60 % der Dynamic-Type-Größe.
    ///
    /// Public issue #6 (TestFlight-Build 275): ein Tester mit 11 Tagesdosen sah
    /// „11/11" als „11/1" + „1" umbrechen, die zweite Zeile fiel auf die
    /// „heute"-Caption. Der Wert-`Text` hatte weder `lineLimit` noch
    /// `minimumScaleFactor`; sobald der String breiter wurde als die Ringmitte
    /// hergibt, hat SwiftUI an der „/" umgebrochen statt zu verkleinern. Der
    /// Wert bleibt jetzt einzeilig und skaliert bis zu diesem Faktor herunter.
    /// 0.6 hält auch die längste realistische Compliance-Form („11/11" bei
    /// Accessibility-Größen) noch lesbar über der 11-pt-Grenze.
    public nonisolated static let valueMinimumScale: CGFloat = 0.6

    /// Schrumpf-Schranke der Caption (`label`): „heute" / „von 100" dürfen
    /// sich weder übereinander stapeln noch zu „heu…" werden. `.hlCaption`
    /// ist ein Text-Style und wächst bei Accessibility-Größen auf gut das
    /// Doppelte, während der Ring 92 pt bleibt — bei 0.8 wurde „today" bei
    /// AX5 zu „tod…" (Public issue #6, Runde 2, Host-Render). 0.5 bringt die
    /// Caption dort auf etwa ihre Standardgröße zurück.
    private static let labelMinimumScale: CGFloat = 0.5

    /// Obergrenze für die Wert-Schrift als Anteil des INNEREN Ringdurchmessers.
    ///
    /// Public issue #6, Runde 2: `fontRatio` ist eine `@ScaledMetric`, bei
    /// Accessibility-Textgrößen wächst der Wert also fast auf das Doppelte,
    /// während der Ring 92 pt bleibt. `valueMinimumScale` allein reicht dann
    /// nicht mehr — fünf Glyphen („11/11") passen selbst bei 60 % nicht in die
    /// Ringmitte, und `lineLimit(1)` antwortet mit „11/…", was über einen
    /// Elf-Dosen-Tag genauso wenig sagt wie der Umbruch. Die Schrift wächst
    /// darum mit Dynamic Type nur bis zu diesem Anteil des inneren
    /// Durchmessers (92 pt → ≈ 30.39 pt), darüber bleibt sie stehen. Bei
    /// Standardgröße (20.2 pt) greift die Kappe nicht; bei fünf Glyphen à
    /// ≈ 0.55 em bleibt am Floor (0.6) mit ≈ 47 pt Textbreite in ≈ 72.36 pt
    /// Innenraum Luft. Rein, damit `HLRingStrokeTests` den Vertrag ohne
    /// SwiftUI-Host prüfen kann.
    public nonisolated static let valueFontCap: CGFloat = 0.42

    /// Innerer Durchmesser: Seite minus beide Stroke-Hälften minus ein Hauch
    /// Luft (`HLSpace.xs`), damit Glyphe und Stroke sich nie berühren.
    public nonisolated static func innerDiameter(forSide side: CGFloat, stroke: CGFloat) -> CGFloat {
        max(0, side - 2 * stroke - HLSpace.xs)
    }

    /// Wert-Schriftgröße: Dynamic-Type-skalierte Proportion, gekappt auf
    /// `valueFontCap` des inneren Durchmessers. (Public issue #6.)
    public nonisolated static func valueFontSize(
        forSide side: CGFloat,
        stroke: CGFloat,
        scaledRatio: CGFloat
    ) -> CGFloat {
        min(side * scaledRatio, innerDiameter(forSide: side, stroke: stroke) * valueFontCap)
    }

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
                            .font(.hlMetric(HLRing.valueFontSize(forSide: side, stroke: stroke, scaledRatio: fontRatio)))
                            .foregroundStyle(HLText.primary)
                            .monospacedDigit()
                            // Public issue #6 — the value NEVER wraps. Without
                            // these three the 11-dose case ("11/11") broke at
                            // the "/" and dropped its second line onto the
                            // caption. One line, tightened, and scaled down to
                            // `valueMinimumScale` before anything is cut.
                            .lineLimit(1)
                            .minimumScaleFactor(HLRing.valueMinimumScale)
                            .allowsTightening(true)
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
                            // Public issue #6 — same rule for the caption:
                            // "heute" / "von 100" shrink rather than stack.
                            .lineLimit(1)
                            .minimumScaleFactor(HLRing.labelMinimumScale)
                            .allowsTightening(true)
                    }
                }
                // Public issue #6 — the centre stack is measured against the
                // ring's INNER diameter, not its outer side. Otherwise the
                // value is offered the full `side` and only discovers it does
                // not fit once it has already run under the stroke. `HLSpace.xs`
                // keeps a hair of air between glyph and stroke.
                .frame(width: HLRing.innerDiameter(forSide: side, stroke: stroke))
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
