import SwiftUI

// MARK: - Glow / Ambiance config (orthogonal to `Motion`)

public extension HLCycleRing {
    /// Award-tier additive glow layers, composable on top of any `Motion`.
    ///
    /// Per `PC-C5-ring-glow-spec.md` the glow is **light escaping the active arc**,
    /// not paint: a soft phase-tinted bloom, a metallic specular sweep masked to
    /// the live phase, and one warm ovulation-peak accent. All additive layers
    /// live OUTSIDE the geometry `.drawingGroup()` (it clamps `.plusLighter` /
    /// `.screen` and clips blur). Every layer has a defined static end-state under
    /// Reduce Motion.
    struct Glow: Sendable, Equatable {
        public var bloom: Bool
        public var sweep: Bool
        public var ovulationSparkle: Bool

        public init(bloom: Bool = true, sweep: Bool = true, ovulationSparkle: Bool = true) {
            self.bloom = bloom
            self.sweep = sweep
            self.ovulationSparkle = ovulationSparkle
        }

        public static let off = Glow(bloom: false, sweep: false, ovulationSparkle: false)
        public static let standard = Glow()
    }

    /// Whisper-subtle ambient backdrop behind the monochrome ring. Opt-in.
    struct Ambiance: Sendable, Equatable {
        public var mesh: Bool

        public init(mesh: Bool = false) {
            self.mesh = mesh
        }

        public static let off = Ambiance(mesh: false)
        public static let withMesh = Ambiance(mesh: true)
    }
}

// MARK: - Pure glow math (testable, no SwiftUI host)

/// Pure, `nonisolated` helpers for the glow layers so the breathing curve and the
/// active-arc anchor are unit-testable without a SwiftUI host.
public enum HLCycleRingGlowMath {
    /// Breathing scalar in `0...1`, sine-based. With `0.5 + 0.5·sin`, `t = 0`
    /// yields `0.5` → the visual mean, which is exactly the Reduce-Motion still.
    public nonisolated static func breath(_ t: Double, period: Double = 5.5) -> Double {
        0.5 + 0.5 * sin(t * 2 * .pi / period)
    }

    /// Linear interpolation.
    public nonisolated static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    /// The unit-circle centre point (in `0...1` fraction space) of the day
    /// marker's slice — used to anchor the bloom on the LIVE phase, not the dial
    /// centre. Day 1 at 12 o'clock, clockwise. Returns an offset in the same
    /// fraction-of-radius space the caller scales by the actual radius.
    ///
    /// `dx`/`dy` are unit-vector components (length 1) pointing from the ring
    /// centre toward the marker; the caller multiplies by the marker radius.
    public nonisolated static func markerUnitVector(day: Int, cycleLength: Int) -> (dx: Double, dy: Double) {
        let angleDeg = HLCycleRing.dayToAngle(day: day, cycleLength: cycleLength)
        // 12 o'clock = -90° in screen space; clockwise positive.
        let rad = (angleDeg - 90.0) * .pi / 180.0
        return (cos(rad), sin(rad))
    }
}

// MARK: - Shared continuous-motion driver

/// One `TimelineView(.animation)` clock shared by every continuous glow layer so
/// they stay phase-locked. Under Reduce Motion it renders the static `t = 0`
/// frame (no `TimelineView`, no redraw, no flicker). No `repeatForever`.
struct HLGlowDriver<Content: View>: View {
    let active: Bool
    @ViewBuilder var content: (Double) -> Content

    var body: some View {
        if active {
            // ~20 fps caps glow redraw — a slow bloom needs no more, saves energy.
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { ctx in
                content(ctx.date.timeIntervalSinceReferenceDate)
            }
        } else {
            content(0) // static end-state: phase = 0 → mean values
        }
    }
}

// MARK: - Bloom halo (additive radial glow behind the active arc)

/// A `Canvas` radial-gradient halo in the active phase tint. Additive
/// (`.plusLighter` dark / `.screen` light) so it glows on near-black without
/// banding. Anchored on the marker position so it tracks the live phase.
struct HLBloomHalo: View {
    let unit: (dx: Double, dy: Double)
    let markerRadius: CGFloat
    let baseRadius: CGFloat
    let tint: Color
    let breath: Double // 0...1; 0.5 = static mean
    let scheme: ColorScheme
    let dimmed: Bool // Increase-Contrast → drop opacity

    var body: some View {
        // Opacity + radius breathe around a mean (spec §3 / §8).
        let opaqueMax = scheme == .dark ? 0.30 : 0.20
        let opaqueMin = scheme == .dark ? 0.16 : 0.10
        let baseOpacity = HLCycleRingGlowMath.lerp(opaqueMin, opaqueMax, breath)
        let opacity = baseOpacity * (dimmed ? 0.7 : 1.0)
        let radius = baseRadius * HLCycleRingGlowMath.lerp(0.92, 1.08, breath)

        Canvas { ctx, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            let center = CGPoint(
                x: mid.x + CGFloat(unit.dx) * markerRadius,
                y: mid.y + CGFloat(unit.dy) * markerRadius
            )
            let grad = Gradient(stops: [
                .init(color: tint.opacity(opacity), location: 0.0),
                .init(color: tint.opacity(opacity * 0.45), location: 0.45),
                .init(color: tint.opacity(0), location: 1.0)
            ])
            let rect = CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
            ctx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(grad, center: center, startRadius: 0, endRadius: radius)
            )
        }
        .blendMode(scheme == .dark ? .plusLighter : .screen)
        .allowsHitTesting(false)
    }
}

// MARK: - Specular sweep (metallic glide masked to the active arc)

/// A thin bright `AngularGradient` band masked to the active phase arc, rotated
/// by the shared clock — Apple Activity-ring "metallic glide". Reduce Motion →
/// omitted by the caller (never inserted).
struct HLSpecularSweep: View {
    let arc: (start: Double, end: Double)
    let stroke: CGFloat
    let t: Double
    let scheme: ColorScheme

    var body: some View {
        let hi = Color.white.opacity(scheme == .dark ? 0.18 : 0.10)
        // Continuous rotation, period ~7 s (spec §5 / §8).
        let angle = Angle.degrees((t / 7.0).truncatingRemainder(dividingBy: 1.0) * 360.0)
        Circle()
            .trim(from: arc.start, to: arc.end)
            .stroke(
                AngularGradient(colors: [.clear, hi, .clear], center: .center, angle: angle),
                style: StrokeStyle(lineWidth: stroke, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .blur(radius: stroke * 0.2)
            .blendMode(scheme == .dark ? .plusLighter : .screen)
            .allowsHitTesting(false)
    }
}

// MARK: - Ambient mesh backdrop (iOS 18, whisper-only)

/// A 3×3 `MeshGradient` of warm phase tones, heavily blurred + clipped behind the
/// ring. Only the four inner control points drift; the arrays are hoisted so no
/// per-frame allocation churn. Opacity 0.05 light / 0.10 dark.
struct HLAmbientMesh: View {
    let warm: Color
    let warm2: Color
    let t: Double
    let scheme: ColorScheme

    /// Hoisted constant colour grid — only the centre point mutates per frame.
    private var colors: [Color] {
        [
            .clear, warm2, .clear,
            warm2, warm, warm2,
            .clear, warm2, .clear
        ]
    }

    var body: some View {
        let d = Float(0.03 * sin(t * 2 * .pi / 11.0)) // slow ±0.03 drift, period 11 s
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                .init(0, 0), .init(0.5, 0), .init(1, 0),
                .init(0, 0.5), .init(0.5 + d, 0.5 - d), .init(1, 0.5),
                .init(0, 1), .init(0.5, 1), .init(1, 1)
            ],
            colors: colors,
            smoothsColors: true
        )
        .blur(radius: 40)
        .opacity(scheme == .dark ? 0.10 : 0.05)
        .blendMode(scheme == .dark ? .plusLighter : .normal)
        .clipShape(Circle())
        .allowsHitTesting(false)
    }
}

// MARK: - Ovulation peak accent (the ONE warm highlight)

/// A single restrained additive bloom ring on the marker, only on the predicted
/// ovulation day. One ease-out rise on appear, then a slightly-brighter steady
/// rest glow. Reduce Motion → static brighter halo, no pulse.
struct HLOvulationSparkle: View {
    let unit: (dx: Double, dy: Double)
    let markerRadius: CGFloat
    let dot: CGFloat
    let tint: Color
    let t: Double
    let active: Bool // false under Reduce Motion → no pulse, steady rest glow
    let scheme: ColorScheme

    var body: some View {
        let restGlow = 0.12
        let peakMax = scheme == .dark ? 0.45 : 0.30
        // One-shot ease-out rise over 1.2 s, then rests (spec §7).
        let rise = active ? min(1.0, t / 1.2) : 1.0
        let ease = 1.0 - pow(1.0 - rise, 3)
        let pulse = active ? peakMax * ease * (1.0 - 0.4 * rise) : 0.0
        let opacity = pulse + restGlow
        let scale = active ? HLCycleRingGlowMath.lerp(0.6, 1.25, ease) : 1.1

        Canvas { ctx, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            let center = CGPoint(
                x: mid.x + CGFloat(unit.dx) * markerRadius,
                y: mid.y + CGFloat(unit.dy) * markerRadius
            )
            let radius = dot * 1.8 * scale
            let grad = Gradient(stops: [
                .init(color: tint.opacity(opacity), location: 0.0),
                .init(color: tint.opacity(opacity * 0.5), location: 0.5),
                .init(color: tint.opacity(0), location: 1.0)
            ])
            let rect = CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
            ctx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(grad, center: center, startRadius: 0, endRadius: radius)
            )
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}
