import Foundation
@testable import HealthLog
import Testing

/// **1.5 VISIT** — "Nächster Termin" on Vorsorge: which visit shows, when the
/// section is absent, and what "Auffälliges seither" lists. The sentences of
/// the app bundle are tested once at the end; the model tests word rows with a
/// plain wording so they read without the catalogue.
@MainActor
@Suite("Next visit section model (VISIT)", .timeLimit(.minutes(1)))
struct NextVisitModelTests {
    nonisolated static let plain = NotableWording(
        change: { "\($0.kind):\($0.title)" },
        observation: { $0.kind == "firstValue" ? nil : "\($0.kind):\($0.type ?? "")" }
    )

    nonisolated static let preparation = EncounterPreparation(
        from: "2026-08-12", to: "2026-11-18", basis: .practitioner,
        since: .init(occurredAt: nil, kind: "ROUTINE", practitionerName: "Dr. Weber", specialty: nil)
    )

    nonisolated static func visit(_ id: String, prep: EncounterPreparation? = preparation, status: String = "PLANNED") -> EncounterDTO {
        EncounterDTO(
            id: id,
            occurredAt: Date(timeIntervalSince1970: 1_795_000_000),
            status: status,
            practitioner: .init(name: "Dr. Weber", specialty: "Dermatologie", practice: nil),
            preparation: prep
        )
    }

    nonisolated static func window(from: String = "2026-08-12", anchor: String = "nextVisit") -> DayNotableWindow {
        DayNotableWindow(
            from: from, to: "2026-11-05", anchor: anchor,
            observations: [
                .init(date: "2026-09-03", kind: "extremeHigh", type: "WEIGHT", since: "2026-01-02"),
                .init(date: "2026-08-15", kind: "firstValue", type: "PULSE")
            ],
            changes: [
                .init(date: "2026-10-01", kind: "doseChange", id: "m1", title: "Lisinopril"),
                .init(date: "2026-08-20", kind: "illnessOnset", id: "e1", title: "Erkältung")
            ]
        )
    }

    nonisolated static func loaded(_ phase: NextVisitModel.Phase) -> NextVisitModel.NextVisit? {
        if case let .loaded(next) = phase { return next }
        return nil
    }

    private func model(
        upcoming: [EncounterDTO],
        notable: @escaping @Sendable () async throws -> DayNotableWindow = { NextVisitModelTests.window() }
    ) -> NextVisitModel {
        NextVisitModel(
            fetchUpcoming: { UpcomingEncounters(upcoming: upcoming) },
            fetchNotable: notable,
            wording: Self.plain
        )
    }

    @Test("no visit booked: no section")
    func noVisitNoSection() async {
        let model = model(upcoming: [])
        await model.load(focus: nil)
        #expect(model.phase == .hidden)
    }

    @Test("a visit with its window: rows oldest first, the first reading left out")
    func loadedWithRows() async throws {
        let model = model(upcoming: [Self.visit("a"), Self.visit("b")])
        await model.load(focus: nil)
        let next = try #require(Self.loaded(model.phase), "not loaded: \(model.phase)")
        #expect(next.visit.id == "a")
        #expect(next.notable.map(\.text) == ["illnessOnset:Erkältung", "extremeHigh:WEIGHT", "doseChange:Lisinopril"])
        #expect(next.notable.map(\.date) == ["2026-08-20", "2026-09-03", "2026-10-01"])
    }

    @Test("at most five rows")
    func capsAtFive() {
        let changes = (1 ... 8).map { DayNotableWindow.Change(date: "2026-09-0\($0)", kind: "labResult", id: "l\($0)", title: "Labor") }
        let window = DayNotableWindow(from: "2026-08-12", to: "2026-11-05", anchor: "nextVisit", observations: [], changes: changes)
        let rows = NextVisitModel.rows(window, preparation: Self.preparation, wording: Self.plain)
        #expect(rows.count == NextVisitModel.maxNotableRows)
        #expect(rows.first?.date == "2026-09-01")
    }

    @Test("a window that is not the visit's own (older server, other anchor) lists nothing; an unknown anchor on the same window lists")
    func windowMustMatch() async throws {
        let other = model(upcoming: [Self.visit("a")], notable: { NextVisitModelTests.window(from: "2026-10-01", anchor: "lastVisit") })
        await other.load(focus: nil)
        #expect(other.phase == .loaded(.init(visit: Self.visit("a"), notable: [])))

        let unknown = model(upcoming: [Self.visit("a")], notable: { NextVisitModelTests.window(anchor: "future") })
        await unknown.load(focus: nil)
        let next = try #require(Self.loaded(unknown.phase), "not loaded")
        #expect(next.notable.count == 3)
    }

    @Test("a server without preparation: date and practice only, the notable read is not made")
    func noPreparation() async {
        let model = model(upcoming: [Self.visit("a", prep: nil)], notable: {
            Issue.record("notable must not be read without a window")
            return NextVisitModelTests.window()
        })
        await model.load(focus: nil)
        #expect(model.phase == .loaded(.init(visit: Self.visit("a", prep: nil), notable: [])))
    }

    @Test("a failed or refused notable read leaves the line out, the visit stays")
    func notableFailure() async {
        for error in [HLError.server(status: 500, code: nil, message: "x"), .server(status: 403, code: nil, message: "x"), .offline] {
            let model = model(upcoming: [Self.visit("a")], notable: { throw error })
            await model.load(focus: nil)
            #expect(model.phase == .loaded(.init(visit: Self.visit("a"), notable: [])))
        }
    }

    @Test("a named visit shows while it is booked; its rows are only read for the soonest")
    func focus() async throws {
        let model = model(upcoming: [Self.visit("a"), Self.visit("b")])
        await model.load(focus: "b")
        #expect(model.phase == .loaded(.init(visit: Self.visit("b"), notable: [])))
        await model.load(focus: "gone")
        let next = try #require(Self.loaded(model.phase), "not loaded")
        #expect(next.visit.id == "a")
        #expect(NextVisitModel.visit(toShow: [Self.visit("x", status: "CANCELLED"), Self.visit("y")], focus: "x")?.id == "y")
    }

    @Test("visit read errors: refusal, absent route, offline, retryable; a held answer stays")
    func errors() {
        typealias M = NextVisitModel
        let held = M.Phase.loaded(.init(visit: Self.visit("a"), notable: []))
        #expect(M.phase(after: HLError.moduleDisabled("off"), holding: .loading) == .disabled("off"))
        #expect(M.phase(after: HLError.server(status: 403, code: nil, message: ""), holding: .loading) == .disabled(nil))
        #expect(M.phase(after: HLError.server(status: 404, code: nil, message: ""), holding: .loading) == .hidden)
        #expect(M.phase(after: HLError.offline, holding: .loading) == .hidden)
        #expect(M.phase(after: HLError.offline, holding: held) == held)
        #expect(M.phase(after: HLError.server(status: 500, code: nil, message: ""), holding: .loading) == .failed)
        #expect(M.phase(after: HLError.server(status: 500, code: nil, message: ""), holding: held) == held)
        #expect(M.phase(after: CancellationError(), holding: .loading) == nil)
        #expect(M.phase(after: HLError.canceled, holding: held) == nil)
    }

    @Test("the visit read failing shows the retry state")
    func failedThenRetry() async {
        let model = NextVisitModel(
            fetchUpcoming: { throw HLError.server(status: 502, code: nil, message: "") },
            fetchNotable: { NextVisitModelTests.window() },
            wording: Self.plain
        )
        await model.load(focus: nil)
        #expect(model.phase == .failed)
    }
}
