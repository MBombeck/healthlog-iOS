import SwiftUI

/// **I-2 (v0.14 Insights redesign) — the monochrome wellness-score ring.**
///
/// A `Canvas`-drawn, one-shot, tick-marked score gauge. It does NOT extend
/// `HLRing` (a load-bearing dashboard/compliance/widget primitive with a locked
/// single-accent contract) — instead it BORROWS `HLRing`'s visual constants
/// (`HLRing.derivedStroke`, the `HLChartGrid.lineOpacity` track tier, the 0.28 s
/// reduce-motion-gated appear sweep, the numeric-roll value) so the two read as
/// one family, while owning the score-only affordances the dashboard ring must
/// never grow:
///
/// - **`arcDegrees`** — `360` (full ring, for 0–100 quality scores) or `~220`
///   (open-bottom gauge, for spectrum metrics like VO₂max / Cardio-Fitness
///   where the value is a *position on a band*, not a quality fraction).
/// - **`ticks`** — hairline radial marks at band boundaries (the highest-ROI
///   monochrome differentiator: the eye reads *which band the head landed in*
///   by tick position, with no colour).
/// - **`signal`** — a single ≤3 pt cap dot at the arc head, the **ONLY** colour
///   on the surface (sanctioned `StatusOK/Warn/Bad` via the `HLSignal` token —
///   never a raw `Color`, never a per-score hue).
/// - **`segments`** — an optional opacity-banded sleep-stage bar fill (Deep /
///   Core / REM / Awake by `inkGraphite` opacity steps 1.0 / 0.7 / 0.45 / 0.18).
/// - **`compact`** — a ~24 pt contributor-row variant (no centre label) so the
///   detail-sheet rows visually rhyme with the hero.
///
/// **Monochrome differentiation (the 4 levers, priority order — viz research):**
/// 1. fill fraction (the arc length is the primary signal, always),
/// 2. tick marks at band boundaries,
/// 3. opacity steps (`inkGraphite` 1.0/0.7/0.45/0.18) for multi-part breakdowns,
/// 4. a single signal pinpoint (the cap dot) — ≤1 % of the pixels, the one place
///    colour earns its keep.
///
/// **Performance/energy:** one-shot `Canvas` render per value change; the only
/// animation is the appear-sweep (`fraction` 0→value, 0.28 s, reduce-motion →
/// instant). No `TimelineView`, no `PhaseAnimator`, no shimmer, no glass (glass
/// lives only on the detail-sheet hero platter, never here).
public struct HLScoreRing: View {
    /// The sanctioned signal token for the single cap dot. The ONLY colour on a
    /// `HLScoreRing`. Token-typed (not a raw `Color`) so the monochrome contract
    /// is enforced at the type level — callers pick a *meaning*, the view maps it
    /// to the live status colour.
    public enum HLSignal: Equatable, Sendable {
        case ok
        case warn
        case bad

        var color: Color {
            switch self {
            case .ok: HLColor.statusOK
            case .warn: HLColor.statusWarn
            case .bad: HLColor.statusBad
            }
        }

        /// VoiceOver word for the signal dot's MEANING — so the ok/warn/bad
        /// status the cap dot conveys visually is also announced non-visually
        /// (the dot is the only colour and is otherwise invisible to VoiceOver).
        var accessibilityWord: String {
            switch self {
            case .ok: String(localized: "in range")
            case .warn: String(localized: "borderline")
            case .bad: String(localized: "out of range")
            }
        }
    }

    /// Fill fraction 0…1 (score ÷ scale). For a gauge this is the cap-dot
    /// position along the open arc; for a ring it is the trim end.
    private let fraction: Double
    /// The big centre value text (e.g. "84", "42.1"). `nil` / `compact` → no
    /// centre text.
    private let value: String?
    /// The small label under the value (band word). `nil` → no label.
    private let label: String?
    /// Arc sweep in degrees: `360` = full ring, `<360` = open-bottom gauge
    /// (centred on top, gap at the bottom).
    private let arcDegrees: Double
    /// Band-boundary positions 0…1 drawn as hairline radial ticks. Decorative
    /// (VoiceOver-hidden) — the band is announced in the value text.
    private let ticks: [Double]
    /// The single cap dot at the arc head — the only colour. `nil` → pure mono.
    private let signal: HLSignal?
    /// Optional opacity-banded segmented fill (sleep stages). Each entry is a
    /// fraction of the arc; rendered as adjacent arc wedges in the
    /// `inkGraphite` opacity ladder. `nil` → single flat fill.
    private let segments: [Double]?
    /// Contributor-row variant: ~24 pt, no centre text, thinner stroke, no
    /// signal dot label affordances.
    private let compact: Bool
    /// VoiceOver label for the combined element (framed: "Readiness 84 of 100,
    /// band green"). When `nil`, falls back to `value`.
    private let accessibilityLabelOverride: String?
    /// v0.14.8 Item-1 — explicit fill-arc colour override. `nil` keeps the
    /// default `HLChartTints.series` (graphite, dark-mode-flipping). The wellness
    /// score cards pass a scheme-STABLE ink (`HLColor.wellnessRingInk`) because
    /// their beige gradient card is appearance-invariant, so the default
    /// near-white dark-mode fill would vanish on it.
    private let fillColorOverride: Color?
    /// v0.14.8 Item-1 — explicit track colour override. `nil` keeps the default
    /// `HLText.primary @ lineOpacity` channel. Paired with `fillColorOverride`
    /// so the recessed track stays subtly visible on the appearance-invariant
    /// beige card in both schemes.
    private let trackColorOverride: Color?
    /// v0.14.1 — explicit centre-value colour override. `nil` keeps the default
    /// `HLText.primary` (dark-mode-flipping). Same inversion class as the fill:
    /// the wellness score cards pass a scheme-STABLE ink
    /// (`HLColor.wellnessRingInk`) because the beige gradient card is
    /// appearance-invariant, so the default near-white dark-mode "72" would
    /// wash out on it.
    private let centreValueColorOverride: Color?
    /// v0.14.1 — explicit centre-label (band word, e.g. "Bereit") colour
    /// override. `nil` keeps the default `HLText.secondary`. Paired with
    /// `centreValueColorOverride` so the label stays legible (at a slightly
    /// lower opacity for hierarchy) on the appearance-invariant beige card.
    private let centreLabelColorOverride: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When ON, the cap dot gains a SHAPE channel (filled / hollow / ringed) so
    /// the ok/warn/bad status is distinguishable without relying on hue — for
    /// sighted colour-blind users (VoiceOver already speaks the status word).
    /// The default (OFF) appearance is the unchanged colour-only filled dot.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    /// Drives the fill arc. **Seeded to the real `fraction` at init** so the arc
    /// is CORRECT on first paint — the appear-sweep is a non-essential
    /// enhancement layered on top, never the thing the fill depends on.
    ///
    /// v0.14.x ring-0% fix: the previous `= 0` start made the fill depend ENTIRELY
    /// on a `withAnimation` sweep in `.onAppear`, which does not reliably run in
    /// the lazy Insights grid (view-identity churn / one-shot `Canvas` not
    /// re-rendering through the implicit animation) NOR in an `ImageRenderer`
    /// snapshot — so the ring rendered as an empty track regardless of value.
    /// Seeding from `fraction` makes the arc correct immediately; the sweep then
    /// only adds the 0→value flourish when motion is allowed.
    @State private var animatedFraction: Double

    /// Centre-value font scales with Dynamic Type (mirrors `HLRing.fontRatio`),
    /// so the hero number grows with the Large setting instead of shrinking in
    /// the ring.
    @ScaledMetric(relativeTo: .title) private var fontRatio: CGFloat = 0.22

    /// Centre-value scale floor. A 2-digit number sits at full size; the floor
    /// only engages for the widest 3-digit centre value ("100") so it fits on
    /// one line inside the ring. ~0.6 is enough to fit "100" where "84" sat,
    /// without over-shrinking smaller numbers.
    nonisolated static let centreValueScaleFloor: CGFloat = 0.6

    public init(
        fraction: Double,
        value: String? = nil,
        label: String? = nil,
        arcDegrees: Double = 360,
        ticks: [Double] = [],
        signal: HLSignal? = nil,
        segments: [Double]? = nil,
        compact: Bool = false,
        fillColor: Color? = nil,
        trackColor: Color? = nil,
        centreValueColor: Color? = nil,
        centreLabelColor: Color? = nil,
        accessibilityLabel: String? = nil
    ) {
        let clamped = max(0, min(1, fraction))
        self.fraction = clamped
        // Seed the fill to the real value so the arc is correct on first paint,
        // independent of whether the appear-sweep ever runs.
        _animatedFraction = State(initialValue: clamped)
        self.value = value
        self.label = label
        self.arcDegrees = max(1, min(360, arcDegrees))
        self.ticks = ticks
        self.signal = signal
        self.segments = segments
        self.compact = compact
        fillColorOverride = fillColor
        trackColorOverride = trackColor
        centreValueColorOverride = centreValueColor
        centreLabelColorOverride = centreLabelColor
        accessibilityLabelOverride = accessibilityLabel
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let stroke = compact
                ? max(2.5, side * HLRing.strokeRatio)
                : HLRing.derivedStroke(forSide: side)
            ZStack {
                Canvas { ctx, size in
                    Self.draw(
                        in: ctx,
                        size: size,
                        stroke: stroke,
                        fraction: animatedFraction,
                        arcDegrees: arcDegrees,
                        ticks: ticks,
                        segments: segments,
                        signal: signal,
                        trackColor: trackColorOverride ?? HLText.primary.opacity(HLChartGrid.lineOpacity),
                        fillColor: fillColorOverride ?? HLChartTints.series,
                        differentiateWithoutColor: differentiateWithoutColor
                    )
                }
                if !compact {
                    centreLabel(side: side)
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            // The arc is already seeded to `fraction` (see `animatedFraction`).
            // When motion is allowed, REWIND to 0 and sweep up so the appear
            // flourish still plays — but if this never runs (lazy grid / snapshot)
            // the seeded value already shows the correct fill. Reduce-motion: no-op,
            // the seeded value stands.
            guard !reduceMotion else { return }
            animatedFraction = 0
            withAnimation(.easeOut(duration: 0.28)) { animatedFraction = fraction }
        }
        .onChange(of: fraction) { _, newValue in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
                animatedFraction = newValue
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabelOverride ?? value ?? ""))
        .accessibilityValue(Text(accessibilityValueText))
    }

    /// The default VoiceOver value — composes the centre value with the band
    /// word (the `label`) and the signal-dot meaning, so the ring announces
    /// e.g. "84, ready, in range" instead of the bare "84, 84". Callers that
    /// pass an explicit `accessibilityLabel:` keep their own label; this value
    /// rides alongside it. Falls back to the percentage when there is no value.
    private var accessibilityValueText: String {
        Self.composedAccessibilityValue(value: value, label: label, signal: signal, fraction: fraction)
    }

    /// Pure composition of the default VoiceOver value (`value`, band `label`,
    /// signal-dot word), hoisted `nonisolated static` so the announcement is
    /// unit-testable without a SwiftUI host. Falls back to the percentage when
    /// nothing else is present.
    nonisolated static func composedAccessibilityValue(
        value: String?,
        label: String?,
        signal: HLSignal?,
        fraction: Double
    ) -> String {
        var parts: [String] = []
        if let value, !value.isEmpty {
            parts.append(value)
        }
        if let label, !label.isEmpty {
            parts.append(label)
        }
        if let signal {
            parts.append(signal.accessibilityWord)
        }
        if parts.isEmpty {
            // Catalog key `%lld percent` (EN + DE present) — the no-value /
            // compact ring fallback. Explicit comment so the key resolves.
            return String(localized: "\(Int(fraction * 100)) percent", comment: "Ring a11y value fallback, e.g. \"60 percent\"")
        }
        return parts.joined(separator: ", ")
    }

    private func centreLabel(side: CGFloat) -> some View {
        VStack(spacing: HLSpace.xxs) {
            if let value {
                Text(value)
                    .font(.hlMetric(side * fontRatio))
                    .foregroundStyle(centreValueColorOverride ?? HLText.primary)
                    .monospacedDigit()
                    // A 3-digit score ("100") otherwise wraps to two lines inside
                    // the ring; pin a single line and let it tighten + scale down
                    // only as far as the floor needs (≈0.6 ⇒ "100" fits at every
                    // 0–100 score, while 2-digit numbers never shrink).
                    .lineLimit(1)
                    .minimumScaleFactor(Self.centreValueScaleFloor)
                    .allowsTightening(true)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
                    .hlAnimation(.snappy(duration: 0.25), value: value)
            }
            if let label {
                Text(label)
                    .font(.hlCaption)
                    .foregroundStyle(centreLabelColorOverride ?? HLText.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        // Keep the centre stack clear of the stroke + gauge gap.
        .padding(.horizontal, side * 0.18)
    }

    // MARK: - Canvas drawing (pure, one-shot)

    /// Draws track → fill (single or segmented) → boundary ticks → the single
    /// signal cap dot, in one pass. `nonisolated static` + pure args so the
    /// geometry is unit-testable without a SwiftUI host (the band/tick/signal
    /// resolution is exercised separately via ``ScorePresentation``).
    ///
    /// Angle convention: 0° is the top (12 o'clock), sweeping clockwise. A
    /// `360°` arc is a full ring starting at top; a `<360°` arc is centred on
    /// top with the gap split evenly at the bottom (open-bottom gauge).
    nonisolated static func draw(
        in ctx: GraphicsContext,
        size: CGSize,
        stroke: CGFloat,
        fraction: Double,
        arcDegrees: Double,
        ticks: [Double],
        segments: [Double]?,
        signal: HLSignal?,
        trackColor: Color,
        fillColor: Color,
        differentiateWithoutColor: Bool = false
    ) {
        let side = min(size.width, size.height)
        let radius = (side - stroke) / 2
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let sweep = min(360, max(1, arcDegrees))
        // Start at top, centred. Full ring → start at top (−90° in standard
        // math frame). Gauge → rotate the start back by half the missing arc.
        let gap = 360 - sweep
        // Full ring → start at top (−90° in the standard math frame). Gauge →
        // rotate the start back by half the missing arc so the gap is centred
        // at the bottom.
        let startDeg = -90 + gap / 2
        let startAngle = Angle.degrees(startDeg)
        let endAngle = Angle.degrees(startDeg + sweep)

        func point(at t: Double) -> CGPoint {
            let deg = startDeg + sweep * max(0, min(1, t))
            let rad = deg * .pi / 180
            return CGPoint(x: centre.x + radius * cos(rad), y: centre.y + radius * sin(rad))
        }

        // 1. Track — recessed hairline channel (the groove).
        var track = Path()
        track.addArc(center: centre, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        ctx.stroke(track, with: .color(trackColor), style: StrokeStyle(lineWidth: stroke, lineCap: .round))

        // 2. Fill — single flat accent, OR an opacity-banded segmented bar
        //    (sleep stages). Segments differentiate by the inkGraphite opacity
        //    ladder, never by hue.
        if let segments, !segments.isEmpty {
            let total = max(0.0001, segments.reduce(0, +))
            let opacitySteps: [Double] = [1.0, 0.7, 0.45, 0.18]
            var cursor = 0.0
            for (index, raw) in segments.enumerated() {
                let frac = raw / total
                let segStart = cursor
                let segEnd = cursor + frac * fraction
                cursor += frac * fraction
                guard segEnd > segStart else { continue }
                var seg = Path()
                seg.addArc(
                    center: centre,
                    radius: radius,
                    startAngle: .degrees(startDeg + sweep * segStart),
                    endAngle: .degrees(startDeg + sweep * segEnd),
                    clockwise: false
                )
                let op = opacitySteps[min(index, opacitySteps.count - 1)]
                ctx.stroke(
                    seg,
                    with: .color(fillColor.opacity(op)),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .butt)
                )
            }
        } else if fraction > 0 {
            var fill = Path()
            fill.addArc(
                center: centre,
                radius: radius,
                startAngle: startAngle,
                endAngle: .degrees(startDeg + sweep * fraction),
                clockwise: false
            )
            ctx.stroke(fill, with: .color(fillColor), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
        }

        // 3. Boundary ticks — hairline radial marks at band cutoffs. inkGraphite
        //    @ 0.40 so they read above the 0.10 track without competing with the
        //    fill. Drawn from just inside to just outside the stroke channel.
        let tickColor = fillColor.opacity(0.40)
        let tickWidth = max(1, stroke * 0.18)
        for t in ticks where t > 0 && t < 1 {
            let deg = startDeg + sweep * t
            let rad = deg * .pi / 180
            let inner = radius - stroke * 0.55
            let outer = radius + stroke * 0.55
            var tick = Path()
            tick.move(to: CGPoint(x: centre.x + inner * cos(rad), y: centre.y + inner * sin(rad)))
            tick.addLine(to: CGPoint(x: centre.x + outer * cos(rad), y: centre.y + outer * sin(rad)))
            ctx.stroke(tick, with: .color(tickColor), style: StrokeStyle(lineWidth: tickWidth, lineCap: .butt))
        }

        // 4. The single signal cap dot — the ONLY colour. Sits at the arc head
        //    (fraction position), ≤3 pt, where the eye lands last.
        if let signal {
            let dotRadius = min(3, stroke * 0.42)
            let head = point(at: fraction)
            let dotRect = CGRect(
                x: head.x - dotRadius,
                y: head.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            let dot = Path(ellipseIn: dotRect)
            if differentiateWithoutColor {
                // Differentiate-without-color: add a SHAPE channel so ok/warn/bad
                // read without relying on hue. Monochrome-safe, within the ≤3 pt
                // footprint — colour is still applied on top.
                //   .ok   → filled disc  (the canonical look)
                //   .warn → hollow ring  (stroked outline, transparent centre)
                //   .bad  → ringed dot   (filled disc + a concentric outer ring)
                let glyphStroke = max(0.75, dotRadius * 0.5)
                switch signal {
                case .ok:
                    ctx.fill(dot, with: .color(signal.color))
                case .warn:
                    let inset = glyphStroke / 2
                    let ring = Path(ellipseIn: dotRect.insetBy(dx: inset, dy: inset))
                    ctx.stroke(ring, with: .color(signal.color), style: StrokeStyle(lineWidth: glyphStroke))
                case .bad:
                    ctx.fill(dot, with: .color(signal.color))
                    let outer = Path(ellipseIn: dotRect.insetBy(dx: -glyphStroke, dy: -glyphStroke))
                    ctx.stroke(outer, with: .color(signal.color), style: StrokeStyle(lineWidth: glyphStroke))
                }
            } else {
                ctx.fill(dot, with: .color(signal.color))
            }
        }
    }

    // MARK: - Pure presentation resolution (unit-testable)

    /// Pure descriptor mapping a 0–100 score → ring inputs. Hoisted out of the
    /// view so the band → signal + the tick set can be locked in a test without
    /// a SwiftUI host. The standard 0–100 wellness banding is
    /// `green ≥70 / yellow 40–69 / red <40` (server `bandForScore`), with the
    /// canonical tick set at the two band cutoffs (0.40 / 0.70).
    public struct ScorePresentation: Equatable {
        public let fraction: Double
        public let signal: HLSignal
        public let ticks: [Double]

        /// Canonical 0–100 wellness banding (READINESS / SLEEP_SCORE etc.).
        public nonisolated static func wellness(score: Double) -> ScorePresentation {
            let clamped = max(0, min(100, score))
            let signal: HLSignal = clamped >= 70 ? .ok : (clamped >= 40 ? .warn : .bad)
            return ScorePresentation(fraction: clamped / 100, signal: signal, ticks: [0.40, 0.70])
        }

        /// Map a server band string directly (`green/yellow/red`) when the score
        /// is absent or the band is authoritative.
        public nonisolated static func signal(forBand band: String?) -> HLSignal? {
            switch band {
            case "green": .ok
            case "yellow": .warn
            case "red": .bad
            default: nil
            }
        }
    }
}

#Preview("HLScoreRing — ring / gauge / sleep / compact") {
    ScrollView {
        VStack(spacing: HLSpace.xxl) {
            HStack(spacing: HLSpace.lg) {
                HLScoreRing(
                    fraction: 0.84,
                    value: "84",
                    label: "Bereit",
                    ticks: [0.40, 0.70],
                    signal: .ok
                )
                .frame(width: 140, height: 140)

                HLScoreRing(
                    fraction: 0.32,
                    value: "32",
                    label: "Niedrig",
                    ticks: [0.40, 0.70],
                    signal: .bad
                )
                .frame(width: 140, height: 140)
            }
            // Open-bottom gauge — Cardio-Fitness / VO₂max spectrum position.
            HLScoreRing(
                fraction: 0.62,
                value: "42.1",
                label: "ml/kg/min",
                arcDegrees: 220,
                ticks: [0.33, 0.66],
                signal: .ok
            )
            .frame(width: 160, height: 160)

            // Segmented sleep-stage bar (opacity ladder, no hue).
            HLScoreRing(
                fraction: 1.0,
                value: "78",
                label: "Schlaf",
                signal: .warn,
                segments: [0.55, 0.20, 0.18, 0.07]
            )
            .frame(width: 140, height: 140)

            // Compact contributor-row dots.
            HStack(spacing: HLSpace.lg) {
                ForEach([0.9, 0.6, 0.3], id: \.self) { f in
                    HLScoreRing(fraction: f, compact: true)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .padding(HLSpace.xl)
        .frame(maxWidth: .infinity)
    }
    .background(HLSurface.primary)
}
