import SwiftUI

/// **Phase C5 — the native cycle-prediction hero ring.**
///
/// A pure-SwiftUI, data-driven circular period-forecast ring (rebuilt natively —
/// no images). It draws a monochrome track, warm low-chroma phase arcs over it
/// (the only colour on the surface — see `CyclePhasePalette`), an optional
/// fertile-window band, a current-day marker, calm centre text, and one gentle
/// MOVING element.
///
/// **String-injection driven.** The component owns NO localized strings — the
/// caller passes `centerTitle` / `centerSubtitle` / `accessibility*` already
/// localized.
///
/// **Geometry contract.** Day 1 is at 12 o'clock (top), the ring runs CLOCKWISE.
/// `dayToAngle` / `dayRangeToArc` are pure `nonisolated static` helpers so the
/// mapping is unit-testable without a SwiftUI host (`HLCycleRingTests`).
///
/// **Motion.** Four variants (`Motion`), default `.breathe`. **Every** motion is
/// gated by `accessibilityReduceMotion` → under Reduce Motion the static
/// end-state renders with no animation, no flicker. Ease curves only — no spring
/// bounce, no opacity strobing.
public struct HLCycleRing: View {
    // MARK: - Injected model

    public struct Model: Sendable, Equatable {
        public var cycleLengthDays: Int
        public var dayOfCycle: Int
        /// **Z1 (#72) — may a position on the ring be claimed at all?** The
        /// server sends `dayOfCycle: null` in `OVERDUE`: the arcs still draw,
        /// but no marker, bloom or tracer points at a day, because there is no
        /// day to point at. `dayOfCycle` keeps a clamped value only so the
        /// tinting helpers stay total.
        public var showsDayMarker: Bool
        public var segments: [Segment]
        public var predictedOvulationDay: Int?
        public var fertileWindow: ClosedRange<Int>?
        public var centerTitle: String
        public var centerSubtitle: String

        public struct Segment: Sendable, Equatable {
            public var phase: CyclePhasePalette.Phase
            public var dayRange: ClosedRange<Int>

            public init(phase: CyclePhasePalette.Phase, dayRange: ClosedRange<Int>) {
                self.phase = phase
                self.dayRange = dayRange
            }
        }

        public init(
            cycleLengthDays: Int,
            dayOfCycle: Int,
            showsDayMarker: Bool = true,
            segments: [Segment],
            predictedOvulationDay: Int? = nil,
            fertileWindow: ClosedRange<Int>? = nil,
            centerTitle: String,
            centerSubtitle: String
        ) {
            self.cycleLengthDays = max(1, cycleLengthDays)
            self.dayOfCycle = min(max(1, dayOfCycle), max(1, cycleLengthDays))
            self.showsDayMarker = showsDayMarker
            self.segments = segments
            self.predictedOvulationDay = predictedOvulationDay
            self.fertileWindow = fertileWindow
            self.centerTitle = centerTitle
            self.centerSubtitle = centerSubtitle
        }
    }

    /// The gentle moving element. `none` renders the full static end-state.
    public enum Motion: Sendable, Equatable, CaseIterable {
        /// Current-day marker gently pulses (scale + soft halo), ~2.5 s autoreverse.
        case breathe
        /// A soft glow travels once day1→current on appear, then rests at the marker.
        case tracer
        /// A very slow (~12 s) conic sheen rotates behind the arcs.
        case sheen
        /// No motion at all.
        case none
    }

    private let model: Model
    private let motion: Motion
    private let glow: Glow
    private let ambiance: Ambiance
    private let accessibilityLabel: String
    private let accessibilityValue: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(
        model: Model,
        motion: Motion = .breathe,
        glow: Glow = .standard,
        ambiance: Ambiance = .off,
        accessibilityLabel: String,
        accessibilityValue: String
    ) {
        self.model = model
        self.motion = motion
        self.glow = glow
        self.ambiance = ambiance
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
    }

    /// Fraction of the available square reserved on EACH side as bloom-halo
    /// margin, so the additive glow (which blooms outward from the marker on the
    /// ring) is never clipped by the parent. The drawn ring uses
    /// `outer · (1 − 2·haloInsetFraction)`.
    ///
    /// At 0.18 the bloom's outward reach (`markerRadius + bloomBase·1.08`) stays
    /// inside the full-square glow Canvas on every side, so the halo renders uncut
    /// (the caller frames the ring ~`visibleSide / (1 − 2·0.18)` to keep the drawn
    /// ring at its intended size).
    private static let haloInsetFraction: CGFloat = 0.18

    // MARK: - Geometry helpers (pure, testable)

    /// Maps a cycle day (1...length) to its centre angle in degrees, measured
    /// CLOCKWISE from 12 o'clock. Day 1 sits at the very top.
    ///
    /// Days are *bins*: day `d` occupies `[(d-1)/length, d/length)` of the
    /// circle. The returned angle is that slice's centre — where the dot belongs.
    public nonisolated static func dayToAngle(day: Int, cycleLength: Int) -> Double {
        let length = max(1, cycleLength)
        let clamped = min(max(1, day), length)
        let fraction = (Double(clamped) - 0.5) / Double(length)
        return fraction * 360.0
    }

    /// Maps an inclusive day-range to a (startFraction, endFraction) pair in
    /// 0...1 of the full circle, where day `lo` starts at `(lo-1)/length` and day
    /// `hi` ends at `hi/length`. Clamped to the cycle and to a valid order.
    public nonisolated static func dayRangeToArc(
        range: ClosedRange<Int>,
        cycleLength: Int
    ) -> (start: Double, end: Double) {
        let length = max(1, cycleLength)
        let lo = min(max(1, range.lowerBound), length)
        let hi = min(max(lo, range.upperBound), length)
        let start = Double(lo - 1) / Double(length)
        let end = Double(hi) / Double(length)
        return (start, end)
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geo in
            let outer = min(geo.size.width, geo.size.height)
            // Inset the drawn ring inside the available square so the additive
            // bloom halo (which blooms OUTWARD from the marker on the ring) has
            // room and is never clipped by the parent. ~12% of the side ≈ the
            // bloom's outward reach. All groups share the same `side` so the
            // glow stays geometry-locked.
            let side = outer * (1 - 2 * Self.haloInsetFraction)
            ZStack {
                // GLOW group — additive blends + blur, NO drawingGroup (it would
                // clamp `.plusLighter`/`.screen` and clip blur). Bloom + mesh sit
                // behind the geometry; sweep + sparkle sit above it, still here.
                // Drawn into the FULL `outer` square so the halo can spill into
                // the inset margin instead of being clipped at the ring edge; the
                // marker anchor uses the inset `side` so it stays ring-locked.
                glowGroup(side: side, canvasSide: outer)
                // GEOMETRY group — crisp arcs/marker/track, keeps `.drawingGroup()`.
                // The drawn ring is `side`-sized (centred in `outer`) so it never
                // touches the parent edge, but the group is rasterised + framed at
                // the FULL `outer` square: a stroked `Circle` extends `stroke/2`
                // OUTSIDE its path bounds, so framing the drawingGroup to `side`
                // clipped that outer half at the four cardinals → the ring read as
                // a flat-topped octagon. Rasterising into `outer` leaves the
                // 18 %-per-side halo margin as clip headroom, so the full round
                // crest renders uncut on every side.
                geometryGroup(side: side, canvasSide: outer)
                // Specular sweep + ovulation accent — above geometry, still no
                // drawingGroup (additive must composite against the real backdrop).
                overlayGlowGroup(side: side, canvasSide: outer)
                centerContent(side: side)
            }
            .frame(width: outer, height: outer)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(accessibilityValue))
    }

    // MARK: - Geometry group (crisp arcs/marker — keeps `.drawingGroup()`)

    @ViewBuilder
    private func geometryGroup(side: CGFloat, canvasSide: CGFloat) -> some View {
        let stroke = HLRing.derivedStroke(forSide: side)
        ZStack {
            if motion == .sheen, !reduceMotion {
                SheenLayer(side: side, scheme: colorScheme)
            }
            TrackRing(stroke: stroke)
            ArcsLayer(
                segments: model.segments,
                cycleLength: model.cycleLengthDays,
                stroke: stroke,
                scheme: colorScheme,
                tracerEnabled: motion == .tracer && !reduceMotion && model.showsDayMarker,
                currentDay: model.dayOfCycle
            )
            if let window = model.fertileWindow {
                FertileBand(
                    window: window,
                    cycleLength: model.cycleLengthDays,
                    side: side,
                    stroke: stroke,
                    scheme: colorScheme
                )
            }
            if model.showsDayMarker {
                DayMarker(
                    day: model.dayOfCycle,
                    cycleLength: model.cycleLengthDays,
                    side: side,
                    stroke: stroke,
                    phase: phase(forDay: model.dayOfCycle),
                    scheme: colorScheme,
                    breathing: motion == .breathe && !reduceMotion
                )
            }
        }
        // Keep the drawn ring at the inset `side` size (centred), but GROW the
        // layout bounds to the FULL `canvasSide` square BEFORE rasterising, so
        // `.drawingGroup()` captures into the larger canvas. A stroked `Circle`
        // extends `stroke/2` OUTSIDE its `side` path bounds; rasterising at
        // `side` clipped that outer half at the four cardinals → the ring read as
        // a flat-topped octagon (the operator-reported clip). The order is
        // load-bearing: `.frame(side)` sizes the ring, `.frame(canvasSide)` adds
        // the 18 %-per-side halo headroom as clip room, and `.drawingGroup()`
        // LAST rasterises that full square — so the round crest renders uncut on
        // every side. (b166's order rasterised at `side` first, hence the clip.)
        .frame(width: side, height: side)
        .frame(width: canvasSide, height: canvasSide)
        .drawingGroup()
    }

    // MARK: - Glow group (additive bloom + ambient mesh — NO drawingGroup)

    /// Whether the bloom halo + ambient mesh should *breathe* (vs. render the
    /// static mean frame). Only `.breathe` drives the bloom pulse — under
    /// `.tracer` the travelling comet is the protagonist, under `.sheen` the
    /// specular sweep is, and `.none` is fully still. This is what makes the
    /// four picks visibly distinct: previously the bloom breathed regardless of
    /// `motion`, so every variant read as "breathing". Always gated by Reduce
    /// Motion (then the static mean renders, no flicker).
    private var bloomBreathes: Bool {
        motion == .breathe && !reduceMotion
    }

    @ViewBuilder
    private func glowGroup(side: CGFloat, canvasSide: CGFloat) -> some View {
        let stroke = HLRing.derivedStroke(forSide: side)
        let unit = HLCycleRingGlowMath.markerUnitVector(
            day: model.dayOfCycle, cycleLength: model.cycleLengthDays
        )
        let markerRadius = (side - stroke) / 2
        let bloomBase = side * 0.30
        let tint = CyclePhasePalette.tint(for: phase(forDay: model.dayOfCycle), scheme: colorScheme)
        let dimmed = colorSchemeContrast == .increased

        HLGlowDriver(active: bloomBreathes) { t in
            let b = HLCycleRingGlowMath.breath(t)
            ZStack {
                if ambiance.mesh {
                    HLAmbientMesh(
                        warm: tint,
                        warm2: CyclePhasePalette.soft(for: meshAdjacentPhase, scheme: colorScheme, opacity: 1.0),
                        t: t,
                        scheme: colorScheme
                    )
                    .frame(width: side * 1.1, height: side * 1.1)
                }
                // Bloom is anchored to the day marker — omitted with no day.
                if glow.bloom, model.showsDayMarker {
                    // Canvas at the FULL square so the halo blooms into the
                    // inset margin uncut; marker anchor stays ring-locked.
                    HLBloomHalo(
                        unit: unit,
                        markerRadius: markerRadius,
                        baseRadius: bloomBase,
                        tint: tint,
                        breath: b,
                        scheme: colorScheme,
                        dimmed: dimmed
                    )
                    .frame(width: canvasSide, height: canvasSide)
                }
            }
        }
    }

    // MARK: - Overlay glow (specular sweep + ovulation — above geometry, no drawingGroup)

    @ViewBuilder
    private func overlayGlowGroup(side: CGFloat, canvasSide: CGFloat) -> some View {
        let stroke = HLRing.derivedStroke(forSide: side)
        let activeArc = activePhaseArc
        let unit = HLCycleRingGlowMath.markerUnitVector(
            day: model.dayOfCycle, cycleLength: model.cycleLengthDays
        )
        let markerRadius = (side - stroke) / 2
        let dot = max(8, stroke * 1.15)
        let tint = CyclePhasePalette.tint(for: phase(forDay: model.dayOfCycle), scheme: colorScheme)
        let isOvulationPeak = model.showsDayMarker && model.predictedOvulationDay == model.dayOfCycle
        // The sweep is the DOMINANT motion only under `.sheen` — that's what
        // makes the sheen pick read as a sheen (a specular band gliding the live
        // arc) rather than as "breathing". Under the other motions it would just
        // compete with the bloom/tracer, so we omit it. Reduce Motion → omitted.
        let sweepActive = glow.sweep && motion == .sheen && !reduceMotion

        HLGlowDriver(active: sweepActive || (glow.ovulationSparkle && isOvulationPeak && !reduceMotion)) { t in
            ZStack {
                // Sweep: continuous motion only — omitted entirely under Reduce
                // Motion. Framed to the inset `side` so the band tracks the
                // (inset) arc, not the full square.
                if sweepActive, let arc = activeArc {
                    HLSpecularSweep(arc: arc, stroke: stroke, t: t, scheme: colorScheme)
                        .frame(width: side, height: side)
                }
                if glow.ovulationSparkle, isOvulationPeak {
                    // Canvas at full square so the accent bloom isn't clipped;
                    // marker anchor uses the inset `side` → stays ring-locked.
                    HLOvulationSparkle(
                        unit: unit,
                        markerRadius: markerRadius,
                        dot: dot,
                        tint: tint,
                        t: t,
                        // `.none` is genuinely still: steady rest glow, no rise.
                        active: motion != .none && !reduceMotion,
                        scheme: colorScheme
                    )
                    .frame(width: canvasSide, height: canvasSide)
                }
            }
        }
    }

    /// The arc (fraction 0...1) of the phase covering the current day — anchors
    /// the specular sweep on the LIVE segment. `nil` when no segment matches.
    private var activePhaseArc: (start: Double, end: Double)? {
        guard model.showsDayMarker,
              let segment = model.segments.first(where: { $0.dayRange.contains(model.dayOfCycle) }) else { return nil }
        return HLCycleRing.dayRangeToArc(range: segment.dayRange, cycleLength: model.cycleLengthDays)
    }

    /// A softer adjacent phase for the ambient mesh's secondary warm tone. Falls
    /// back to luteal (the calmest tint).
    private var meshAdjacentPhase: CyclePhasePalette.Phase {
        switch phase(forDay: model.dayOfCycle) {
        case .menstrual: .follicular
        case .follicular: .ovulatory
        case .ovulatory: .luteal
        case .luteal: .menstrual
        }
    }

    @ViewBuilder
    private func centerContent(side: CGFloat) -> some View {
        let inset = HLRing.derivedStroke(forSide: side) * 2 + HLSpace.lg
        VStack(spacing: HLSpace.xs) {
            Text(model.centerTitle)
                .font(.hlMetric(.title))
                .foregroundStyle(HLText.primary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
            Text(model.centerSubtitle)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .lineLimit(2)
        }
        .padding(.horizontal, HLSpace.sm)
        .frame(width: max(0, side - inset * 2))
    }

    /// The phase covering a given day (for tinting the marker). Falls back to
    /// luteal (the calm phase) when no segment matches.
    private func phase(forDay day: Int) -> CyclePhasePalette.Phase {
        model.segments.first { $0.dayRange.contains(day) }?.phase ?? .luteal
    }
}

// MARK: - Track ring

private struct TrackRing: View {
    let stroke: CGFloat

    var body: some View {
        Circle()
            .stroke(
                HLText.primary.opacity(HLChartGrid.lineOpacity),
                style: StrokeStyle(lineWidth: stroke, lineCap: .round)
            )
    }
}

// MARK: - Phase arcs

private struct ArcsLayer: View {
    let segments: [HLCycleRing.Model.Segment]
    let cycleLength: Int
    let stroke: CGFloat
    let scheme: ColorScheme
    let tracerEnabled: Bool
    let currentDay: Int

    /// Tracer sweep progress 0→1 (day1→current). Rests at 1 (the marker).
    @State private var tracerProgress: Double = 0

    var body: some View {
        ZStack {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                let arc = HLCycleRing.dayRangeToArc(range: segment.dayRange, cycleLength: cycleLength)
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(
                        CyclePhasePalette.tint(for: segment.phase, scheme: scheme),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
            }
            if tracerEnabled {
                tracerOverlay
            }
        }
        .onAppear {
            guard tracerEnabled else { return }
            tracerProgress = 0
            withAnimation(.easeInOut(duration: 1.4)) {
                tracerProgress = 1
            }
        }
    }

    /// A soft glow comet that travels day1→current along the ring on appear.
    private var tracerOverlay: some View {
        let target = Double(max(1, currentDay)) / Double(max(1, cycleLength))
        let head = target * tracerProgress
        // A short trailing arc behind the head, fading in.
        let tail = max(0, head - 0.08)
        return Circle()
            .trim(from: tail, to: head)
            .stroke(
                LinearGradient(
                    colors: [
                        HLText.primary.opacity(0),
                        HLText.primary.opacity(0.5)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: stroke * 0.5, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .blur(radius: stroke * 0.25)
            .opacity(tracerProgress < 1 ? 1 : 0)
    }
}

// MARK: - Fertile-window band

private struct FertileBand: View {
    let window: ClosedRange<Int>
    let cycleLength: Int
    let side: CGFloat
    let stroke: CGFloat
    let scheme: ColorScheme

    var body: some View {
        let arc = HLCycleRing.dayRangeToArc(range: window, cycleLength: cycleLength)
        // A delicate dotted inner arc, inset inside the main arc track.
        let inset = stroke * 1.6
        Circle()
            .trim(from: arc.start, to: arc.end)
            .stroke(
                CyclePhasePalette.soft(for: .ovulatory, scheme: scheme, opacity: 0.55),
                style: StrokeStyle(
                    lineWidth: max(1.5, stroke * 0.22),
                    lineCap: .round,
                    dash: [2, max(3, stroke * 0.5)]
                )
            )
            .rotationEffect(.degrees(-90))
            .padding(inset)
    }
}

// MARK: - Current-day marker

private struct DayMarker: View {
    let day: Int
    let cycleLength: Int
    let side: CGFloat
    let stroke: CGFloat
    let phase: CyclePhasePalette.Phase
    let scheme: ColorScheme
    let breathing: Bool

    @State private var pulse = false

    var body: some View {
        let angle = HLCycleRing.dayToAngle(day: day, cycleLength: cycleLength)
        let radius = (side - stroke) / 2
        let dot = max(8, stroke * 1.15)
        let tint = CyclePhasePalette.tint(for: phase, scheme: scheme)
        ZStack {
            // Soft halo — breathes when enabled, else a static gentle glow.
            Circle()
                .fill(tint.opacity(breathing ? (pulse ? 0.06 : 0.22) : 0.16))
                .frame(width: dot * 2.4, height: dot * 2.4)
                .scaleEffect(breathing ? (pulse ? 1.18 : 1.0) : 1.0)
            // The marker cap — a clean ring-on-fill so it reads on any arc.
            Circle()
                .fill(tint)
                .overlay(
                    Circle().stroke(HLSurface.secondary, lineWidth: max(1.5, stroke * 0.18))
                )
                .frame(width: dot, height: dot)
                .scaleEffect(breathing ? (pulse ? 1.12 : 1.0) : 1.0)
        }
        // Position on the ring: rotate the layout to the day angle, then push out.
        .offset(y: -radius)
        .rotationEffect(.degrees(angle))
        .onAppear {
            guard breathing else { return }
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        // W-PERF-SWR (High) — stop the `repeatForever` pulse off-screen. A
        // repeating `withAnimation` keeps driving the layer's animation
        // transaction even when the view leaves the hierarchy (Cycle/Insights
        // ring scrolled away or another tab), burning CPU for no visible
        // benefit. Flipping the state back without animation halts the loop;
        // the next `onAppear` restarts it cleanly.
        .onDisappear {
            guard breathing else { return }
            withAnimation(.linear(duration: 0)) { pulse = false }
        }
    }
}

// MARK: - Sheen layer

private struct SheenLayer: View {
    let side: CGFloat
    let scheme: ColorScheme

    @State private var angle: Double = 0

    var body: some View {
        let stroke = HLRing.derivedStroke(forSide: side)
        Circle()
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [
                        HLText.primary.opacity(0),
                        HLText.primary.opacity(scheme == .dark ? 0.10 : 0.07),
                        HLText.primary.opacity(0)
                    ]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: stroke * 1.6, lineCap: .round)
            )
            .blur(radius: stroke * 0.6)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
            // W-PERF-SWR (High) — cancel the 12s `repeatForever` sheen rotation
            // off-screen so it doesn't keep spinning (and redrawing) when the
            // ring leaves the hierarchy. Reset to a static angle without
            // animation; `onAppear` restarts the loop from 0 → 360.
            .onDisappear {
                withAnimation(.linear(duration: 0)) { angle = 0 }
            }
    }
}

// MARK: - Previews

//
// The DEBUG preview gallery lives in `HLCycleRing+Previews.swift` (split out to
// keep this component file under the 600-line lint budget).
