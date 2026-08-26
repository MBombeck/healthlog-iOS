import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// **v0.14.9 §3+§4 render-verify** — renders the wellness score-ring grid with a
/// FULL fixture (every promoted tile/hue) via `ImageRenderer`, in dark (the app
/// default) + light, so the operator-facing changes can be eyeballed:
///   • §3 — Erholung/Recovery is no longer red (now honey-yellow).
///   • §4 — every tile gradient is softened ≥40% (calm, not punchy).
///   • the WHITE ring + value stay legible on every (softened) hue.
///
/// Renders the SHIPPING `InsightsScoreCardsBlock` (not a stand-in), so the PNG is
/// a faithful artefact of the surface the operator sees. PNGs land in a sim-
/// writable dir (override via `TILE_OUT`); the path is printed for host copy-out.
@MainActor
@Suite("Wellness tile render-verify")
struct WellnessTileRenderVerify {
    private var outDir: URL {
        if let override = ProcessInfo.processInfo.environment["TILE_OUT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("insights-tiles", isDirectory: true)
    }

    private func write(_ view: some View, name: String, scheme: ColorScheme) {
        let host = view
            .frame(width: 393)
            .padding(HLSpace.lg)
            .background(scheme == .dark ? Color.black : Color(white: 0.96))
            .environment(\.colorScheme, scheme)
            // v0141 — `InsightsScoreCardsBlock` now reads the per-card hide store
            // from the environment; inject a fresh (empty → nothing hidden) one so
            // the render matches the shipping default.
            .environment(WellnessCardVisibilityStore())
        let renderer = ImageRenderer(content: host)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let suffix = scheme == .dark ? "dark" : "light"
        try? data.write(to: outDir.appendingPathComponent("\(name)-\(suffix).png"))
    }

    private func env(_ metric: String, value: DerivedMetricDTO.Value, band: String) -> DerivedMetricDTO {
        DerivedMetricDTO(
            metric: metric, status: "ok", value: value,
            coverage: .init(requiredInputs: 5, presentInputs: 5, historyDays: 28, missing: []),
            confidence: .init(score: 80, band: band),
            provenance: .init(
                inputs: ["RESTING_HEART_RATE", "HEART_RATE_VARIABILITY"],
                source: "DAY", windowDays: 30, computedAt: .now
            ),
            reason: nil
        )
    }

    /// One fixture per promoted hue so the rendered grid covers ALL tiles.
    private func fullFixture() -> [DerivedMetricDTO] {
        [
            env("READINESS", value: .init(score: 78, band: "green"), band: "high"),
            env("SLEEP_SCORE", value: .init(score: 84, band: "green"), band: "high"),
            env("STRAIN_SCORE", value: .init(score: 55, band: "yellow"), band: "medium"),
            env("RECOVERY_SCORE", value: .init(score: 64, band: "yellow"), band: "medium"),
            env("STRESS_SCORE", value: .init(score: 42, band: "green"), band: "medium"),
            env(
                "FITNESS_AGE",
                value: .init(score: nil, band: "high", fitnessAgeDeltaYears: -6, vo2Max: 44.2, referenceBand: .init(low: 38, high: 46)),
                band: "high"
            ),
            env("VASCULAR_AGE_DELTA", value: .init(score: nil, band: "green", deltaYears: 3), band: "high"),
            env("HRV_BALANCE", value: .init(score: nil, band: "balanced"), band: "high")
        ]
    }

    @Test("render the full wellness score grid on every hue (dark + light)")
    func renderTiles() {
        let block = InsightsScoreCardsBlock(
            metrics: fullFixture(),
            onSelectMetric: nil,
            onSelectMood: nil,
            showsSignals: false
        )
        for scheme in [ColorScheme.dark, .light] {
            write(block, name: "wellness-grid", scheme: scheme)
        }
        let landed = FileManager.default.fileExists(
            atPath: outDir.appendingPathComponent("wellness-grid-dark.png").path
        )
        print("TILE_SCREENS_DIR=\(outDir.path)")
        #expect(landed, "wellness tiles written to \(outDir.path)")
    }

    // MARK: - v0.14.11 Task B+C render-verify

    /// A representative cycle ring model — the textbook 28-day shape the server
    /// itself falls back to for a low-data tracker (`verdict.ts:idealizedSpans`),
    /// so the rendered cycle tile is a faithful stand-in for
    /// `CycleScoreRingCard` (which can't be hosted directly — its `CycleStore`
    /// verdict/prediction are `private(set)`).
    ///
    /// Z1 (#72): this used to call `CycleScreenModel.representativeModel`, the
    /// client-side "your data looks sparse, here is a population backdrop"
    /// substitution. That decision belongs to the server now, so the harness
    /// carries its own literal rather than keeping a shipping code path alive.
    private func cycleModel() -> HLCycleRing.Model {
        HLCycleRing.Model(
            cycleLengthDays: 28,
            dayOfCycle: 18,
            segments: [
                .init(phase: .menstrual, dayRange: 1 ... 5),
                .init(phase: .follicular, dayRange: 6 ... 13),
                .init(phase: .ovulatory, dayRange: 14 ... 15),
                .init(phase: .luteal, dayRange: 16 ... 28)
            ],
            predictedOvulationDay: 15,
            fertileWindow: 12 ... 16,
            centerTitle: "in ~10 days",
            centerSubtitle: "Day 18"
        )
    }

    /// A tile composite mirroring `CycleScoreRingCard.tile` (cycle ring + label in
    /// the `WellnessGradientCard` chrome) so the cycle tile reads as a sibling.
    private func cycleTilePreview(scheme: ColorScheme) -> some View {
        let tint = CyclePhasePalette.tint(for: .luteal, scheme: scheme)
        let tinted = tint.blended(with: HLColor.wellnessGradientDark, fraction: WellnessGradient.darkenTowardBase)
        let gradient = LinearGradient(
            stops: [
                .init(color: tinted, location: 0),
                .init(color: tinted.blended(with: HLColor.wellnessGradientDark, fraction: 0.5), location: 0.5),
                .init(color: HLColor.wellnessGradientDark, location: 1)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        return WellnessGradientCard(gradient: nil, customGradient: gradient) {
            VStack(spacing: HLSpace.sm) {
                HLCycleRing(
                    model: cycleModel(), motion: .none, glow: .off,
                    accessibilityLabel: "Cycle", accessibilityValue: "Day 18"
                )
                .frame(width: 96, height: 96)
                Text("Cycle · Luteal")
                    .font(.hlSubhead.weight(.medium))
                    .foregroundStyle(WellnessRingPalette.label)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLSpace.xs)
        }
        .frame(width: 180)
    }

    @Test("render the cycle ring tile beside the score tiles (Task B)")
    func renderCycleTile() {
        for scheme in [ColorScheme.dark, .light] {
            write(cycleTilePreview(scheme: scheme), name: "cycle-tile", scheme: scheme)
        }
        #expect(
            FileManager.default.fileExists(atPath: outDir.appendingPathComponent("cycle-tile-dark.png").path)
        )
    }

    /// A single score tile with the glow frozen at an explicit `breath` value, so
    /// the two breathing EXTREMES (min `-1` / mid `0` / max `+1`) are judgeable
    /// from stills (motion can't be screenshotted live).
    private func glowExtremeTile(breath: Double) -> some View {
        let radius = WellnessTileMotion.endRadius(breath: breath)
        let scale = WellnessTileMotion.opacityScale(breath: breath)
        return ZStack {
            WellnessGradient.tagesform.linearGradient
            RadialGradient(
                colors: [HLColor.wellnessTileGlow.opacity(scale), .clear],
                center: .center, startRadius: 0, endRadius: radius
            )
            HLScoreRing(
                fraction: 0.78, value: "78",
                fillColor: WellnessRingPalette.fill, trackColor: WellnessRingPalette.track,
                centreValueColor: WellnessRingPalette.value, centreLabelColor: WellnessRingPalette.label,
                accessibilityLabel: "Readiness"
            )
            .frame(width: 96, height: 96)
            .padding(HLSpace.lg)
        }
        .frame(width: 180, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
    }

    @Test("render the glow breath extremes min/mid/max as stills (Task C)")
    func renderGlowExtremes() {
        for (label, breath) in [("min", -1.0), ("mid", 0.0), ("max", 1.0)] {
            write(glowExtremeTile(breath: breath), name: "glow-\(label)", scheme: .dark)
        }
        #expect(
            FileManager.default.fileExists(atPath: outDir.appendingPathComponent("glow-max-dark.png").path)
        )
    }

    // MARK: - W-B190 — the P9 uniform prism renders (unlike the Metal shader)

    /// Hero-sized + small ring, BOTH with the P9 `prismUniform` effect, side by
    /// side — the proof the new default renders identically on every tile in the
    /// `ImageRenderer` / Simulator (the prior P5 Metal `.layerEffect` did not). The
    /// rings carry `signal: nil` (no cap dot), matching the shipping appearance.
    @MainActor
    private func prismUniformProof() -> some View {
        HStack(spacing: HLSpace.xl) {
            HLScoreRing(fraction: 0.84, value: "84")
                .frame(width: 140, height: 140)
                .insightsRingEffect(.prismUniform, fraction: 0.84, isHero: true)
            HLScoreRing(fraction: 0.62, value: "62")
                .frame(width: 96, height: 96)
                .insightsRingEffect(.prismUniform, fraction: 0.62, isHero: false)
        }
        .padding(HLSpace.xl)
    }

    @Test("the P9 uniform prism renders on hero + small tiles (W-B190 proof)")
    func renderPrismUniformProof() {
        let host = prismUniformProof()
            .frame(width: 393)
            .padding(HLSpace.lg)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: host)
        renderer.scale = 3
        let image = renderer.uiImage
        #expect(image != nil, "the pure-SwiftUI P9 prism must render (unlike the Metal P5 shader)")
        // Write the proof beside the score tiles for the operator. Lands in the
        // simulator sandbox temp dir; the harness copies it to the repo .planning
        // dir afterwards (absolute sandbox paths vary per app-install container).
        write(prismUniformProof().background(Color.black), name: "prism-uniform-verify", scheme: .dark)
    }
}
