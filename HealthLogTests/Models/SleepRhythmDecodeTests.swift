import Foundation
@testable import HealthLog
import Testing

/// **Tolerant decode for `GET /api/sleep/rhythm` (parity Build 4 · 4.7).**
///
/// Pins the payload against the server's real serialiser
/// (`W/src/lib/insights/derived/sleep-rhythm.ts` → `SleepRhythmDto`) along the
/// three axes that actually bite a client: a block PRESENT, ABSENT, and
/// explicitly NULL. All three must land on "that card self-suppresses" — a
/// thrown decode here would blank the whole sleep page over a card the account
/// simply has no data for.
///
/// It also pins the forward-compatibility properties the sleep page depends on:
/// an unknown `band` string, an unknown `state` string, and a fractional minute
/// count must each degrade locally rather than take the payload down.
@Suite("Sleep rhythm — tolerant decode")
struct SleepRhythmDecodeTests {
    private func decode(_ json: String) throws -> SleepRhythmDTO {
        try JSONDecoder.hlDefault.decode(SleepRhythmDTO.self, from: Data(json.utf8))
    }

    // MARK: - Present

    @Test("Full payload decodes all three blocks")
    func fullPayloadDecodes() throws {
        let dto = try decode("""
        {
          "sleepDebt": {
            "state": "ready",
            "debtMinutes": 96,
            "needMinutes": 480,
            "nightsCounted": 5,
            "windowNights": 5,
            "nightsUntilReady": 0,
            "source": "COMPUTED"
          },
          "chronotype": {
            "state": "ready",
            "msfMinutes": 255,
            "msfScMinutes": 240,
            "band": "intermediate",
            "socialJetlagMinutes": 45,
            "freeNightsCounted": 6,
            "workNightsCounted": 14,
            "freeNightsUntilReady": 0
          },
          "averagePerNight": {
            "state": "ready",
            "averageMinutes": 431,
            "nightsCounted": 28,
            "nightsUntilReady": 0
          }
        }
        """)

        let debt = try #require(dto.sleepDebt)
        #expect(debt.state == .ready)
        #expect(debt.debtMinutes == 96)
        #expect(debt.needMinutes == 480)
        #expect(debt.source == "COMPUTED")
        #expect(debt.isCaughtUp == false)

        let chronotype = try #require(dto.chronotype)
        #expect(chronotype.band == .intermediate)
        #expect(chronotype.msfMinutes == 255)
        #expect(chronotype.msfScMinutes == 240)
        #expect(chronotype.socialJetlagMinutes == 45)

        let average = try #require(dto.averagePerNight)
        #expect(average.averageMinutes == 431)
        #expect(average.nightsCounted == 28)
        #expect(dto.isEmpty == false)
    }

    @Test("A settled balance reads as caught up, not as a zero-minute deficit")
    func zeroDebtIsCaughtUp() throws {
        let dto = try decode("""
        {
          "sleepDebt": {
            "state": "ready",
            "debtMinutes": 0,
            "needMinutes": 480,
            "nightsCounted": 5,
            "windowNights": 5,
            "nightsUntilReady": 0,
            "source": "COMPUTED"
          }
        }
        """)
        let debt = try #require(dto.sleepDebt)
        #expect(debt.isCaughtUp)
    }

    // MARK: - Absent

    @Test("Absent blocks decode to nil rather than throwing")
    func absentBlocksDecode() throws {
        let dto = try decode("{}")
        #expect(dto.sleepDebt == nil)
        #expect(dto.chronotype == nil)
        #expect(dto.averagePerNight == nil)
        #expect(dto.isEmpty)
    }

    @Test("A payload carrying only one block keeps that block")
    func partialPayloadKeepsPresentBlock() throws {
        let dto = try decode("""
        {
          "averagePerNight": {
            "state": "partial",
            "averageMinutes": 0,
            "nightsCounted": 2,
            "nightsUntilReady": 2
          }
        }
        """)
        #expect(dto.sleepDebt == nil)
        #expect(dto.chronotype == nil)
        let average = try #require(dto.averagePerNight)
        #expect(average.state == .partial)
        #expect(average.nightsUntilReady == 2)
        #expect(dto.isEmpty == false)
    }

    // MARK: - Explicit null

    @Test("Explicitly null blocks decode to nil rather than throwing")
    func nullBlocksDecode() throws {
        let dto = try decode("""
        { "sleepDebt": null, "chronotype": null, "averagePerNight": null }
        """)
        #expect(dto.sleepDebt == nil)
        #expect(dto.chronotype == nil)
        #expect(dto.averagePerNight == nil)
        #expect(dto.isEmpty)
    }

    @Test("Null chronotype measures decode to nil, never to zero")
    func nullChronotypeMeasuresStayNil() throws {
        let dto = try decode("""
        {
          "chronotype": {
            "state": "learning",
            "msfMinutes": null,
            "msfScMinutes": null,
            "band": null,
            "socialJetlagMinutes": null,
            "freeNightsCounted": 1,
            "workNightsCounted": 4,
            "freeNightsUntilReady": 2
          }
        }
        """)
        let chronotype = try #require(dto.chronotype)
        #expect(chronotype.state == .learning)
        // A `0` here would render as "midnight mid-sleep" — a measurement the
        // server explicitly declined to assert.
        #expect(chronotype.msfMinutes == nil)
        #expect(chronotype.msfScMinutes == nil)
        #expect(chronotype.socialJetlagMinutes == nil)
        #expect(chronotype.band == nil)
        #expect(chronotype.freeNightsCounted == 1)
    }

    // MARK: - Forward compatibility

    @Test("An unknown chronotype band drops the band but keeps the block")
    func unknownBandDegradesLocally() throws {
        let dto = try decode("""
        {
          "chronotype": {
            "state": "ready",
            "msfMinutes": 300,
            "msfScMinutes": 290,
            "band": "hyper_late",
            "socialJetlagMinutes": 30,
            "freeNightsCounted": 5,
            "workNightsCounted": 10,
            "freeNightsUntilReady": 0
          }
        }
        """)
        let chronotype = try #require(dto.chronotype)
        #expect(chronotype.band == nil)
        #expect(chronotype.msfMinutes == 300)
    }

    @Test("An unknown state drops only the unsupported blocks")
    func unknownStateDropsUnsupportedBlocks() throws {
        let dto = try decode("""
        {
          "sleepDebt": {
            "state": "recalibrating",
            "debtMinutes": 120,
            "needMinutes": 480,
            "nightsCounted": 5,
            "windowNights": 5,
            "nightsUntilReady": 0
          },
          "chronotype": {
            "state": "recalibrating",
            "freeNightsCounted": 3,
            "workNightsCounted": 8,
            "freeNightsUntilReady": 0
          }
        }
        """)
        #expect(dto.sleepDebt == nil)
        #expect(dto.chronotype == nil)
        #expect(dto.isEmpty)
    }

    @Test("Fractional minute counts round instead of throwing")
    func fractionalMinutesRound() throws {
        let dto = try decode("""
        {
          "averagePerNight": {
            "state": "ready",
            "averageMinutes": 431.4999999,
            "nightsCounted": 28,
            "nightsUntilReady": 0
          },
          "sleepDebt": {
            "state": "ready",
            "debtMinutes": 95.5,
            "needMinutes": 480,
            "nightsCounted": 5,
            "windowNights": 5,
            "nightsUntilReady": 0
          }
        }
        """)
        let average = try #require(dto.averagePerNight)
        let debt = try #require(dto.sleepDebt)
        #expect(average.averageMinutes == 431)
        #expect(debt.debtMinutes == 96)
    }

    @Test("An absent source is treated as HealthLog's own computed estimate")
    func absentSourceDecodesToNil() throws {
        let dto = try decode("""
        {
          "sleepDebt": {
            "state": "ready",
            "debtMinutes": 30,
            "needMinutes": 480,
            "nightsCounted": 5,
            "windowNights": 5,
            "nightsUntilReady": 0
          }
        }
        """)
        let debt = try #require(dto.sleepDebt)
        #expect(debt.source == nil)
    }

    @Test("A malformed block is dropped without taking its siblings down")
    func malformedBlockDoesNotPoisonSiblings() throws {
        let dto = try decode("""
        {
          "sleepDebt": "unexpected-string",
          "averagePerNight": {
            "state": "ready",
            "averageMinutes": 400,
            "nightsCounted": 10,
            "nightsUntilReady": 0
          }
        }
        """)
        let average = try #require(dto.averagePerNight)
        #expect(dto.sleepDebt == nil)
        #expect(average.averageMinutes == 400)
    }
}
