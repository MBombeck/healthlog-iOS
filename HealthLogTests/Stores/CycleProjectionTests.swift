import Foundation
@testable import HealthLog
import Testing

/// #164 — `projection` and `projectionState` on `/api/cycle/calendar`
/// (server v1.47.1): decoded tolerantly, rendered as sent, never extended on
/// the device; an older server shows no card.
@Suite("Cycle: upcoming cycles from the server's projection")
@MainActor
struct CycleProjectionTests {
    private static func decode(_ extra: String) throws -> CycleCalendarResponse {
        let json = #"{"data":{"days":[]\#(extra)},"error":null}"#
        let envelope = try JSONDecoder.hlDefault.decode(APIEnvelope<CycleCalendarResponse>.self, from: Data(json.utf8))
        return try #require(envelope.data)
    }

    private static let threeCycles = """
    ,"projection":[\
    {"k":1,"start":"2026-12-01","periodLength":5,"bandStart":"2026-11-29","bandEnd":"2026-12-03"},\
    {"k":2,"start":"2026-12-29","periodLength":5,"bandStart":"2026-12-25","bandEnd":"2027-01-02"},\
    {"k":3,"start":"2027-01-26","periodLength":5,"bandStart":"2027-01-20","bandEnd":"2027-02-01"}],\
    "projectionState":"OK"
    """

    @Test("A 1.47.1 calendar decodes the projection and its state")
    func decodesProjection() throws {
        let calendar = try Self.decode(Self.threeCycles)
        #expect(calendar.projection?.map(\.k) == [1, 2, 3])
        #expect(calendar.projection?[1].bandEnd == "2027-01-02")
        #expect(calendar.projectionState == .ok)
    }

    @Test("An older server sends neither field and shows no card")
    func olderServer() throws {
        let calendar = try Self.decode("")
        #expect(calendar.projection == nil)
        #expect(calendar.projectionState == nil)
        #expect(CycleUpcomingContent.resolve(projection: nil, state: nil, showsNextPeriod: true) == .none)
    }

    @Test("A malformed projection drops the card, not the calendar")
    func malformedProjection() throws {
        let calendar = try Self.decode(#","projection":"nope","projectionState":"OK""#)
        #expect(calendar.projection == nil)
        #expect(calendar.days.isEmpty)
    }

    @Test("A state this build does not know reads unknown and shows nothing")
    func unknownState() throws {
        let calendar = try Self.decode(#","projection":[],"projectionState":"SOMETHING_NEW""#)
        #expect(calendar.projectionState == .unknown)
        #expect(CycleUpcomingContent.resolve(projection: [], state: .unknown, showsNextPeriod: true) == .none)
    }

    @Test("The projection survives the cache round trip")
    func encodesForCache() throws {
        let calendar = try Self.decode(Self.threeCycles)
        let data = try JSONEncoder.hlDefault.encode(calendar)
        let again = try JSONDecoder.hlDefault.decode(CycleCalendarResponse.self, from: data)
        #expect(again.projection == calendar.projection)
        #expect(again.projectionState == .ok)
    }

    @Test("Beside the prediction card the list starts after the next period")
    func skipsNextPeriodBesidePrediction() throws {
        let projection = try #require(try Self.decode(Self.threeCycles).projection)
        let shown = CycleUpcomingContent.resolve(projection: projection, state: .ok, showsNextPeriod: true)
        #expect(shown == .cycles(Array(projection.dropFirst())))
        let alone = CycleUpcomingContent.resolve(projection: projection, state: .ok, showsNextPeriod: false)
        #expect(alone == .cycles(projection), "without the card above, the next period is listed too")
    }

    @Test("Learning with only the next period shows no list")
    func learningShowsNothingBeyondNext() {
        let next = [CycleProjectedCycle(k: 1, start: "2026-12-01", bandStart: "2026-11-29", bandEnd: "2026-12-03")]
        #expect(CycleUpcomingContent.resolve(projection: next, state: .learning, showsNextPeriod: true) == .none)
    }

    @Test("Late is stated, off shows nothing")
    func lateAndOff() {
        #expect(CycleUpcomingContent.resolve(projection: [], state: .late, showsNextPeriod: true) == .late)
        #expect(CycleUpcomingContent.resolve(projection: [], state: .off, showsNextPeriod: true) == .none)
    }

    @Test("The list is never extended on the device")
    func neverExtrapolates() throws {
        let projection = try #require(try Self.decode(Self.threeCycles).projection)
        guard case let .cycles(rows) = CycleUpcomingContent.resolve(
            projection: projection, state: .ok, showsNextPeriod: false
        ) else {
            Issue.record("expected cycles")
            return
        }
        #expect(rows.count == projection.count)
        #expect(rows.map(\.start) == projection.map(\.start))
    }

    @Test("A one-day band reads as one date, a real band as a range")
    func windowWording() {
        let single = CycleProjectedCycle(k: 2, start: "2026-12-29", bandStart: "2026-12-29", bandEnd: "2026-12-29")
        #expect(!CycleUpcomingCard.window(single).isEmpty)
        let band = CycleProjectedCycle(k: 2, start: "2026-12-29", bandStart: "2026-12-25", bandEnd: "2027-01-02")
        #expect(CycleUpcomingCard.window(band) != CycleUpcomingCard.window(single))
    }
}
