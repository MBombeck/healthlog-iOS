import Foundation
@testable import HealthLog
import Testing

/// Locks the wire shape of `GET /api/sleep/night?date=YYYY-MM-DD` (#124) against
/// the server contract: the `data`-wrapped main night + naps array, the partial
/// per-stage minutes map, the ordered hypnogram segments, and the `main == null`
/// (no-data) arm.
@Suite("SleepNightDTO wire shape")
struct SleepNightDTODecodingTests {
    private func decode(_ json: String) throws -> SleepNightDTO {
        try JSONDecoder.hlDefault.decode(SleepNightEnvelope.self, from: Data(json.utf8)).data
    }

    @Test("Decodes main night with naps, stages, and segment spans")
    func mainWithNaps() throws {
        let dto = try decode(#"""
        {
          "data": {
            "main": {
              "night": "2026-06-04",
              "source": "APPLE_HEALTH",
              "start": "2026-06-03T22:10:00Z",
              "end": "2026-06-04T06:30:00Z",
              "asleepMinutes": 432,
              "inBedMinutes": 500,
              "awakeMinutes": 24,
              "awakenings": 3,
              "stages": { "REM": 90, "CORE": 240, "DEEP": 60, "AWAKE": 24, "IN_BED": 68 },
              "segments": [
                { "stage": "IN_BED", "start": "2026-06-03T22:10:00Z", "end": "2026-06-03T22:18:00Z", "minutes": 8 },
                { "stage": "CORE",   "start": "2026-06-03T22:18:00Z", "end": "2026-06-03T23:30:00Z", "minutes": 72 }
              ]
            },
            "naps": [
              {
                "night": "2026-06-04",
                "source": "APPLE_HEALTH",
                "start": "2026-06-04T14:00:00Z",
                "end": "2026-06-04T14:35:00Z",
                "asleepMinutes": 35,
                "inBedMinutes": 35,
                "awakeMinutes": 0,
                "awakenings": 0,
                "stages": { "ASLEEP": 35 },
                "segments": [
                  { "stage": "ASLEEP", "start": "2026-06-04T14:00:00Z", "end": "2026-06-04T14:35:00Z", "minutes": 35 }
                ]
              }
            ]
          }
        }
        """#)

        let main = try #require(dto.main)
        #expect(main.source == "APPLE_HEALTH")
        #expect(main.asleepMinutes == 432)
        #expect(main.inBedMinutes == 500)
        #expect(main.awakeMinutes == 24)
        #expect(main.awakenings == 3)
        // Partial stage map keyed by the wire enum.
        #expect(main.stages[.rem] == 90)
        #expect(main.stages[.core] == 240)
        #expect(main.stages[.deep] == 60)
        #expect(main.stages[.awake] == 24)
        #expect(main.stages[.inBed] == 68)
        // Ordered segment spans.
        #expect(main.segments.count == 2)
        let first = try #require(main.segments.first)
        #expect(first.stage == .inBed)
        #expect(first.minutes == 8)
        // Segment span instants decode as UTC.
        let cal = Calendar(identifier: .iso8601)
        let comps = try cal.dateComponents(in: #require(TimeZone(identifier: "UTC")), from: first.start)
        #expect(comps.hour == 22)
        #expect(comps.minute == 10)

        // Naps surface separately, with the coarse ASLEEP bucket.
        #expect(dto.naps.count == 1)
        let nap = try #require(dto.naps.first)
        #expect(nap.asleepMinutes == 35)
        #expect(nap.stages[.asleep] == 35)
        #expect(nap.segments.first?.stage == .asleep)
    }

    @Test("main == null renders empty state (no main, empty naps default)")
    func nullMain() throws {
        let dto = try decode(#"{ "data": { "main": null, "naps": [] } }"#)
        #expect(dto.main == nil)
        #expect(dto.naps.isEmpty)
    }

    @Test("Partial stages — an absent stage key is simply absent")
    func partialStages() throws {
        let dto = try decode(#"""
        {
          "data": {
            "main": {
              "night": "2026-06-04",
              "start": "2026-06-03T23:00:00Z",
              "end": "2026-06-04T05:00:00Z",
              "stages": { "ASLEEP": 360 },
              "segments": [
                { "stage": "ASLEEP", "start": "2026-06-03T23:00:00Z", "end": "2026-06-04T05:00:00Z", "minutes": 360 }
              ]
            }
          }
        }
        """#)
        let main = try #require(dto.main)
        // Only the present key maps; absent stages are nil, never zero-filled.
        #expect(main.stages[.asleep] == 360)
        #expect(main.stages[.deep] == nil)
        #expect(main.stages[.rem] == nil)
        // Optional summary fields tolerate omission.
        #expect(main.asleepMinutes == nil)
        #expect(main.awakenings == nil)
        // `naps` omitted entirely → defaults to [].
        #expect(dto.naps.isEmpty)
    }

    @Test("Unknown stage key is dropped, not thrown")
    func unknownStageDropped() throws {
        let dto = try decode(#"""
        {
          "data": {
            "main": {
              "night": "2026-06-04",
              "start": "2026-06-03T23:00:00Z",
              "end": "2026-06-04T05:00:00Z",
              "stages": { "DEEP": 60, "FUTURE_STAGE": 10 },
              "segments": []
            }
          }
        }
        """#)
        let main = try #require(dto.main)
        #expect(main.stages[.deep] == 60)
        #expect(main.stages.count == 1) // FUTURE_STAGE dropped
    }

    // MARK: - W-SLEEP (v0.14.8) — fractional minutes + stage-less segments

    //
    // The live route serialises every summary minute field UNROUNDED
    // (`route.ts` only `Math.round`s `segments[].minutes`): Apple Watch stage
    // segments have second-resolution bounds, the iOS uploader sends
    // `duration / 60.0` as a Double, and the server sums those floats into
    // `asleepMinutes` / `inBedMinutes` / `awakeMinutes` / `stages`. Decoding
    // them as `Int` threw on essentially every REAL night → the hypnogram
    // never rendered. These tests lock the tolerant decode.

    @Test("Fractional minutes (live wire shape) decode — rounded, never thrown")
    func fractionalMinutesDecode() throws {
        let dto = try decode(#"""
        {
          "data": {
            "main": {
              "night": "2026-06-10",
              "source": "APPLE_HEALTH",
              "start": "2026-06-09T22:10:30Z",
              "end": "2026-06-10T06:30:15Z",
              "asleepMinutes": 433.49999999999994,
              "inBedMinutes": 499.75,
              "awakeMinutes": 24.25,
              "awakenings": 3,
              "stages": { "REM": 90.5, "CORE": 282.99999999999994, "DEEP": 60.0, "AWAKE": 24.25 },
              "segments": [
                { "stage": "CORE", "start": "2026-06-09T22:10:30Z", "end": "2026-06-09T23:30:00Z", "minutes": 79.5 }
              ]
            },
            "naps": []
          }
        }
        """#)
        let main = try #require(dto.main)
        #expect(main.asleepMinutes == 433)
        #expect(main.inBedMinutes == 500)
        #expect(main.awakeMinutes == 24)
        #expect(main.stages[.rem] == 91)
        #expect(main.stages[.core] == 283)
        #expect(main.stages[.deep] == 60)
        #expect(main.segments.first?.minutes == 80)
    }

    @Test("Stage-less segment (stage: null) maps to the coarse ASLEEP bucket")
    func nullStageSegmentMapsToAsleep() throws {
        // Legacy / manual rows have no per-stage label; the server emits
        // `stage: null` for their reconstructed segments. Stage-less = the
        // night's asleep signal (server `asleepMinutesOf` semantics) → render
        // it as the coarse ASLEEP band instead of throwing.
        let dto = try decode(#"""
        {
          "data": {
            "main": {
              "night": "2026-06-10",
              "start": "2026-06-09T23:00:00Z",
              "end": "2026-06-10T05:00:00Z",
              "asleepMinutes": 360.0,
              "stages": {},
              "segments": [
                { "stage": null, "start": "2026-06-09T23:00:00Z", "end": "2026-06-10T05:00:00Z", "minutes": 360 }
              ]
            }
          }
        }
        """#)
        let main = try #require(dto.main)
        #expect(main.segments.count == 1)
        #expect(main.segments.first?.stage == .asleep)
    }

    @Test("Unknown segment stage is dropped — siblings survive")
    func unknownSegmentStageDropped() throws {
        let dto = try decode(#"""
        {
          "data": {
            "main": {
              "night": "2026-06-10",
              "start": "2026-06-09T23:00:00Z",
              "end": "2026-06-10T05:00:00Z",
              "stages": { "DEEP": 60 },
              "segments": [
                { "stage": "FUTURE_STAGE", "start": "2026-06-09T23:00:00Z", "end": "2026-06-09T23:30:00Z", "minutes": 30 },
                { "stage": "DEEP", "start": "2026-06-09T23:30:00Z", "end": "2026-06-10T00:30:00Z", "minutes": 60 }
              ]
            }
          }
        }
        """#)
        let main = try #require(dto.main)
        #expect(main.segments.count == 1)
        #expect(main.segments.first?.stage == .deep)
    }

    // MARK: - W-B189 (server 1.17.1) — reconstructed flag + render gating

    @Test("reconstructed: true decodes (WHOOP-summary ordered timeline)")
    func reconstructedTrueDecodes() throws {
        let dto = try decode(#"""
        {
          "data": {
            "main": {
              "night": "2026-06-14",
              "source": "WHOOP",
              "start": "2026-06-13T23:00:00Z",
              "end": "2026-06-14T06:00:00Z",
              "reconstructed": true,
              "stages": { "REM": 90, "CORE": 240, "DEEP": 60 },
              "segments": [
                { "stage": "DEEP", "start": "2026-06-13T23:00:00Z", "end": "2026-06-14T00:00:00Z", "minutes": 60 },
                { "stage": "CORE", "start": "2026-06-14T00:00:00Z", "end": "2026-06-14T04:00:00Z", "minutes": 240 },
                { "stage": "REM",  "start": "2026-06-14T04:00:00Z", "end": "2026-06-14T05:30:00Z", "minutes": 90 }
              ]
            },
            "naps": []
          }
        }
        """#)
        let main = try #require(dto.main)
        #expect(main.reconstructed)
        // The reconstructed timeline carries REAL contiguous spans, so it is
        // NOT summary-shaped — the screen renders the timed chart + the
        // approximate caption, never the distribution fallback.
        #expect(!SleepHypnogramLayout.isSummaryShaped(main.segments))
    }

    @Test("reconstructed: false decodes (measured hypnogram, no label)")
    func reconstructedFalseDecodes() throws {
        let dto = try decode(#"""
        {
          "data": {
            "main": {
              "night": "2026-06-14",
              "source": "APPLE_HEALTH",
              "start": "2026-06-13T23:00:00Z",
              "end": "2026-06-14T06:00:00Z",
              "reconstructed": false,
              "stages": { "DEEP": 60 },
              "segments": [
                { "stage": "DEEP", "start": "2026-06-13T23:00:00Z", "end": "2026-06-14T00:00:00Z", "minutes": 60 }
              ]
            },
            "naps": []
          }
        }
        """#)
        let main = try #require(dto.main)
        #expect(!main.reconstructed)
    }

    @Test("reconstructed absent (older server) defaults false → heuristic fallback")
    func reconstructedAbsentDefaultsFalse() throws {
        // Legacy ≤ 1.16.x WHOOP-summary night — no `reconstructed` field; every
        // stage shares the sleep-end instant (right-stacked totals). The flag
        // defaults to false, so render gating falls back to the
        // `isSummaryShaped` heuristic, which still catches this night.
        let dto = try decode(#"""
        {
          "data": {
            "main": {
              "night": "2026-06-14",
              "source": "WHOOP",
              "start": "2026-06-13T23:00:00Z",
              "end": "2026-06-14T06:00:00Z",
              "stages": { "REM": 90, "CORE": 240, "DEEP": 60 },
              "segments": [
                { "stage": "DEEP", "start": "2026-06-14T05:00:00Z", "end": "2026-06-14T06:00:00Z", "minutes": 60 },
                { "stage": "CORE", "start": "2026-06-14T02:00:00Z", "end": "2026-06-14T06:00:00Z", "minutes": 240 },
                { "stage": "REM",  "start": "2026-06-14T04:30:00Z", "end": "2026-06-14T06:00:00Z", "minutes": 90 }
              ]
            },
            "naps": []
          }
        }
        """#)
        let main = try #require(dto.main)
        #expect(!main.reconstructed) // absent → default false
        // Heuristic still recognises the legacy right-stacked totals.
        #expect(SleepHypnogramLayout.isSummaryShaped(main.segments))
    }

    @Test("depthRank orders stages shallow→deep for lane position + distribution order")
    func depthRankOrdering() {
        #expect(SleepStage.awake.depthRank < SleepStage.inBed.depthRank)
        #expect(SleepStage.inBed.depthRank < SleepStage.asleep.depthRank)
        #expect(SleepStage.asleep.depthRank < SleepStage.rem.depthRank)
        #expect(SleepStage.rem.depthRank < SleepStage.core.depthRank)
        #expect(SleepStage.core.depthRank < SleepStage.deep.depthRank)
    }

    // MARK: - W-CRASHGUARD — non-finite / out-of-range server values must not

    // trap the decoder (they were `Int(x.rounded())` traps before the fix).

    @Test("Extreme summary-minute value decodes to absent, not a crash")
    func extremeMinuteValueDecodesAbsent() throws {
        let dto = try decode(#"""
        {
          "data": {
            "main": {
              "night": "2026-06-04",
              "start": "2026-06-03T22:10:00Z",
              "end": "2026-06-04T06:30:00Z",
              "asleepMinutes": 1e308,
              "inBedMinutes": 500,
              "awakeMinutes": 24,
              "stages": {},
              "segments": []
            },
            "naps": []
          }
        }
        """#)
        let main = try #require(dto.main)
        // `1e308` is finite but far out of `Int.range` → absent (nil), not a trap.
        #expect(main.asleepMinutes == nil)
        // The well-formed sibling field still decodes.
        #expect(main.inBedMinutes == 500)
    }

    @Test("Out-of-range stage minutes drop that stage instead of crashing")
    func extremeStageValueDropsStage() throws {
        let dto = try decode(#"""
        {
          "data": {
            "main": {
              "night": "2026-06-04",
              "start": "2026-06-03T22:10:00Z",
              "end": "2026-06-04T06:30:00Z",
              "stages": { "REM": 90, "CORE": 1e308 },
              "segments": []
            },
            "naps": []
          }
        }
        """#)
        let main = try #require(dto.main)
        // The finite REM minutes survive; the out-of-range CORE is dropped.
        #expect(main.stages[.rem] == 90)
        #expect(main.stages[.core] == nil)
    }
}
