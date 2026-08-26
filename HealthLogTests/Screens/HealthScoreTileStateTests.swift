import Foundation
@testable import HealthLog
import SnapshotTesting
import Testing

/// Locks the `HealthScoreTile` state matrix (loading / loaded / error)
/// against accidental visual regressions. Image snapshots of `HLCard`
/// are fragile across simulator / SDK rebuilds (system fonts,
/// antialiasing) — we snapshot the **structural state descriptor** the
/// view uses to choose its render branch instead, plus the formatted
/// metric text. That's exactly what changes when someone refactors the
/// tile and is what the user sees once SwiftUI lays it out.
@MainActor
@Suite("HealthScoreTile state matrix")
struct HealthScoreTileStateTests {
    @Test("Loaded state — band/score/delta render exactly as the server emits")
    func loadedState() {
        // v1.34.0 (CU-31): the four-pillar `components` object is gone from
        // every wire; the score now carries its own composition + confidence.
        let score = HealthScore(
            score: 72,
            band: .green,
            delta: 4,
            confidence: HealthScoreConfidence(score: 84, band: .high),
            composition: [.bloodPressure, .activity, .sleep, .wellbeing],
            scoreVersion: 2,
            bandSetter: .sleep
        )

        let descriptor: [String: String] = [
            "state": "loaded",
            "score": "\(score.score)",
            "band": score.band?.rawValue ?? "nil",
            "delta": score.delta.map { "\($0)" } ?? "nil",
            "confidence": score.confidence.map { "\($0.band.rawValue)/\($0.score)" } ?? "nil",
            "composition": score.composition?.map(\.rawValue).joined(separator: ",") ?? "nil",
            "bandSetter": score.bandSetter?.rawValue ?? "nil"
        ]

        assertSnapshot(of: descriptor, as: .dump)
    }

    @Test("Loading state — only the skeleton accessibility label shows")
    func loadingState() {
        let descriptor: [String: String] = [
            "state": "loading",
            "accessibility": "Health Score wird geladen"
        ]
        assertSnapshot(of: descriptor, as: .dump)
    }

    @Test("Error state — error description + retry CTA copy is locked")
    func errorState() {
        let error = HLError.offline
        let descriptor: [String: String] = [
            "state": "error",
            "title": "Health Score nicht verfügbar",
            "message": error.localizedDescription,
            "cta": "Erneut versuchen"
        ]
        assertSnapshot(of: descriptor, as: .dump)
    }

    /// v0.14.10 §2 — the tile's COLOUR band (ring + headline) is now driven by the
    /// numeric score against fixed iOS thresholds, NOT the server's band token:
    /// green ≥67 / amber (yellow) 34–66 / red ≤33. Pins the boundary scores so a
    /// refactor can't silently shift the bands.
    @Test("Colour band follows the numeric thresholds green≥67 / amber 34–66 / red≤33")
    func colourBandThresholds() {
        let cases: [(Int, HealthScoreBand)] = [
            (100, .green),
            (67, .green), // lower green boundary
            (66, .yellow), // upper amber boundary
            (50, .yellow),
            (34, .yellow), // lower amber boundary
            (33, .red), // upper red boundary
            (0, .red)
        ]
        for (score, expected) in cases {
            #expect(HealthScore.colorBand(forScore: score) == expected)
        }
    }

    /// W-B187 / #27 — the COLOUR band now follows the server-authoritative `band`
    /// token via `HealthScore.displayBand`. When the server emits a band it wins,
    /// even if the local numeric thresholds would land elsewhere.
    @Test("Server band drives the tile band — overrides the local numeric threshold")
    func serverBandDrivesTile() {
        // Score 72 → local threshold would say .green, but the server says .red:
        // displayBand must honour the server token.
        let serverRed = HealthScore(score: 72, band: .red, delta: nil)
        #expect(serverRed.displayBand == .red)
        #expect(serverRed.colorBand == .green) // local thresholds untouched

        // Score 20 → local threshold .red, server says .green.
        let serverGreen = HealthScore(score: 20, band: .green, delta: nil)
        #expect(serverGreen.displayBand == .green)
        #expect(serverGreen.colorBand == .red)

        // Score 50 → local .yellow, server says .green.
        let serverGreenMid = HealthScore(score: 50, band: .green, delta: nil)
        #expect(serverGreenMid.displayBand == .green)
    }

    /// W-B187 / #27 — tolerant fallback: a nil server band (older server) keeps the
    /// pre-existing local-threshold behaviour exactly.
    @Test("Nil server band falls back to local numeric thresholds")
    func nilBandFallsBackToLocalThresholds() {
        let cases: [(Int, HealthScoreBand)] = [
            (100, .green),
            (67, .green),
            (66, .yellow),
            (34, .yellow),
            (33, .red),
            (0, .red)
        ]
        for (score, expected) in cases {
            let s = HealthScore(score: score, band: nil, delta: nil)
            #expect(s.displayBand == expected)
            #expect(s.displayBand == s.colorBand) // identical to old behaviour
        }
    }

    /// W-B187 / #27 — "one engine": the same band token resolves to the SAME
    /// status colour token on the Dashboard tile (`displayBand` → HLColor) and the
    /// Insights score surfaces (`HLScoreRing.ScorePresentation.signal(forBand:)` →
    /// `HLSignal` → HLColor). Locking the band→signal correspondence guarantees the
    /// two surfaces can't drift to different colours for the same band.
    @Test("Same band token yields the same colour mapping as Insights")
    func bandColourAgreesWithInsights() {
        let pairs: [(HealthScoreBand, HLScoreRing.HLSignal)] = [
            (.green, .ok),
            (.yellow, .warn),
            (.red, .bad)
        ]
        for (band, expectedSignal) in pairs {
            // Insights maps the wire band string the same way the tile maps the enum.
            let insightsSignal = HLScoreRing.ScorePresentation.signal(forBand: band.rawValue)
            #expect(insightsSignal == expectedSignal)
        }
    }

    /// v1.34.0 (CU-31): the "composite formula" line is gone. The server
    /// stopped shipping per-pillar weights + values, so there is no arithmetic
    /// left to present — the score names its composition instead. The pillar
    /// list is rendered verbatim in the server's registry order; iOS neither
    /// reorders nor re-weights it.
    @Test("Composition renders verbatim in the server's order — no client arithmetic")
    func compositionVerbatim() {
        let score = HealthScore(
            score: 72,
            band: .green,
            delta: nil,
            composition: [.bloodPressure, .glycaemia, .activity, .sleep],
            deltaReason: .belowNoiseFloor,
            bandSetter: .glycaemia
        )
        #expect(score.composition?.map(\.rawValue) == [
            "BLOOD_PRESSURE", "GLYCAEMIA", "ACTIVITY", "SLEEP"
        ])
        #expect(score.bandSetter == .glycaemia)
        // A withheld delta never becomes a narratable one.
        #expect(score.narratableDelta == nil)
        #expect(score.suppressesDeltaNarrative)
    }
}
