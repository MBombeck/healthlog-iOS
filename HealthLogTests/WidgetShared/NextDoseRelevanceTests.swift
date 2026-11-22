import Foundation
@testable import HealthLog
import Testing

/// Pins the Smart Stack window of the next-dose widget and complication.
@Suite("Next dose relevance")
struct NextDoseRelevanceTests {
    private let due = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(minutes: Double) -> Date {
        due.addingTimeInterval(minutes * 60)
    }

    @Test("No open dose scores zero")
    func noDose() {
        #expect(NextDoseRelevance.relevance(for: nil, now: due) == NextDoseRelevance.noDoseScore)
        #expect(NextDoseRelevance.noDoseScore == 0)
    }

    @Test("High from 30 minutes before to 60 minutes after the slot, low outside")
    func windowEdges() {
        let high = NextDoseRelevance.highScore
        let low = NextDoseRelevance.lowScore
        #expect(NextDoseRelevance.relevance(for: due, now: at(minutes: -31)) == low)
        #expect(NextDoseRelevance.relevance(for: due, now: at(minutes: -30).addingTimeInterval(-1)) == low)
        #expect(NextDoseRelevance.relevance(for: due, now: at(minutes: -30)) == high)
        #expect(NextDoseRelevance.relevance(for: due, now: due) == high)
        #expect(NextDoseRelevance.relevance(for: due, now: at(minutes: 60).addingTimeInterval(-1)) == high)
        #expect(NextDoseRelevance.relevance(for: due, now: at(minutes: 60)) == low)
        #expect(NextDoseRelevance.relevance(for: due, now: at(minutes: 240)) == low)
        #expect(high > low && low > NextDoseRelevance.noDoseScore)
    }

    @Test("A dose the widget saved or queued drops to zero, one that was not saved stays high")
    func settledDose() {
        let recorded = WidgetDoseOutcomeStore.Kind.recorded.settlesDose
        let queued = WidgetDoseOutcomeStore.Kind.queued.settlesDose
        let notSaved = WidgetDoseOutcomeStore.Kind.notSaved.settlesDose
        #expect(NextDoseRelevance.relevance(for: due, now: due, settled: recorded) == NextDoseRelevance.noDoseScore)
        #expect(NextDoseRelevance.relevance(for: due, now: due, settled: queued) == NextDoseRelevance.noDoseScore)
        #expect(NextDoseRelevance.relevance(for: due, now: due, settled: notSaved) == NextDoseRelevance.highScore)
        #expect(NextDoseRelevance.relevance(for: due, now: at(minutes: 120), settled: notSaved) == NextDoseRelevance.lowScore)
    }

    @Test("Boundaries are the window edges still ahead")
    func boundaries() {
        #expect(NextDoseRelevance.boundaries(for: nil, after: due).isEmpty)
        #expect(NextDoseRelevance.boundaries(for: due, after: at(minutes: -120)) == [at(minutes: -30), at(minutes: 60)])
        #expect(NextDoseRelevance.boundaries(for: due, after: at(minutes: -30)) == [at(minutes: 60)])
        #expect(NextDoseRelevance.boundaries(for: due, after: at(minutes: 60)).isEmpty)
    }

    @Test("Boundary frames inherit the armed state before them and keep the order")
    func framesMerge() {
        let now = at(minutes: -32)
        let closes = at(minutes: -29)
        let frames = NextDoseRelevance.frames([(now, true), (closes, false)], scheduledAt: due, now: now)
        #expect(frames.map(\.date) == [now, at(minutes: -30), closes, at(minutes: 60)])
        #expect(frames.map(\.armed) == [true, true, false, false])
    }

    @Test("Without a dose the frames stay as they were")
    func framesWithoutDose() {
        let frames = NextDoseRelevance.frames([(due, false)], scheduledAt: nil, now: due)
        #expect(frames.count == 1)
        #expect(frames.first?.date == due)
    }

    @Test("Each score held by a frame matches the score at its date")
    func framesScoreAtTheirDate() {
        let now = at(minutes: -45)
        let frames = NextDoseRelevance.frames([(now, false)], scheduledAt: due, now: now)
        let scores = frames.map { NextDoseRelevance.relevance(for: due, now: $0.date) }
        #expect(scores == [NextDoseRelevance.lowScore, NextDoseRelevance.highScore, NextDoseRelevance.lowScore])
    }
}
