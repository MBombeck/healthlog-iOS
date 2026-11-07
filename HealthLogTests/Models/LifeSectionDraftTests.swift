// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **LIFE (1.5.0, #132)** — one section save becomes exactly the writes it
/// needs: POST for a first answer, PATCH for a change, DELETE for "no answer",
/// nothing for what did not change. Follow-up answers count only where they
/// apply, and an answer this build cannot read is never written over.
@Suite("LifeSectionDraft")
struct LifeSectionDraftTests {
    typealias Fx = LifeCircumstancesFixtures

    private func section(_ key: String, _ ai: String, _ facts: [String]) throws -> LifeSection {
        try #require(Fx.decode(Fx.payload(sections: [Fx.section(key, ai, facts: facts)])).sections.first)
    }

    private func json(_ value: LifeFactWireValue) throws -> [String: Any] {
        let data = try JSONEncoder.hlDefault.encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("an empty section answered for the first time is one POST per answered kind")
    func firstAnswersCreate() throws {
        let empty = try section("tobacco", "SMOKING_STATUS", [])
        var draft = LifeSectionDraft(section: empty)
        #expect(draft.writes(against: empty, validFrom: nil).isEmpty)
        draft.smokingStatus = .former
        draft.tobacco.quitMonth = LifeYearMonth(year: 2019, month: 3)
        let writes = draft.writes(against: empty, validFrom: "2026-10-01")
        #expect(writes.count == 2)
        #expect(writes.first == .create(kind: .smokingStatus, value: .string("FORMER"), validFrom: "2026-10-01"))
        guard case let .create(kind, value, _) = writes.last else {
            Issue.record("expected a create for the tobacco detail")
            return
        }
        #expect(kind == .tobaccoDetail)
        let body = try json(value)
        #expect(body["schema"] as? Int == 1)
        #expect(body["quitMonth"] as? String == "2019-03")
        // Every key is sent, "no answer" as an explicit null (the schema requires them).
        #expect(Set(body.keys) == ["schema", "products", "cigarettesPerDay", "startYear", "quitMonth", "secondhandSmoke"])
        #expect(body["cigarettesPerDay"] is NSNull)
        #expect(body["secondhandSmoke"] is NSNull)
    }

    @Test("a changed answer is a PATCH on its revision, an unchanged one sends nothing")
    func changesCorrect() throws {
        let current = try section("tobacco", "SMOKING_STATUS", [
            Fx.fact("s1", "SMOKING_STATUS", #""FORMER""#),
            Fx.fact("t1", "TOBACCO_DETAIL", Fx.tobaccoValue)
        ])
        var draft = LifeSectionDraft(section: current)
        #expect(!draft.hasChanges(against: current))
        draft.tobacco.quitMonth = LifeYearMonth(year: 2020, month: 11)
        let writes = draft.writes(against: current, validFrom: nil)
        #expect(writes.count == 1)
        guard case let .correct(id, kind, value, validFrom) = writes.first else {
            Issue.record("expected a correction")
            return
        }
        #expect(id == "t1")
        #expect(kind == .tobaccoDetail)
        #expect(validFrom == nil)
        #expect(try json(value)["quitMonth"] as? String == "2020-11")
    }

    @Test("clearing an answer to 'no answer' deletes its revision")
    func clearRemoves() throws {
        let current = try section("goals", "GOALS", [Fx.fact("g1", "HEALTH_GOALS", Fx.goalsValue)])
        var draft = LifeSectionDraft(section: current)
        draft.goals.goals = []
        #expect(draft.writes(against: current, validFrom: nil) == [.remove(revisionID: "g1")])
    }

    @Test("the quit month only for a former smoker, cigarettes only with cigarettes, details never for a never-smoker")
    func tobaccoFollowUps() throws {
        let current = try section("tobacco", "SMOKING_STATUS", [
            Fx.fact("s1", "SMOKING_STATUS", #""FORMER""#),
            Fx.fact("t1", "TOBACCO_DETAIL", Fx.tobaccoValue)
        ])
        var draft = LifeSectionDraft(section: current)
        #expect(draft.asksQuitMonth && draft.asksCigarettesPerDay)

        draft.smokingStatus = .current
        #expect(!draft.asksQuitMonth)
        #expect(draft.normalized.tobacco.quitMonth == nil)
        #expect(draft.normalized.tobacco.cigarettesPerDay == 10)

        draft.tobacco.products = [.eCigarette]
        #expect(!draft.asksCigarettesPerDay)
        #expect(draft.normalized.tobacco.cigarettesPerDay == nil)

        draft.smokingStatus = .never
        draft.tobacco.secondhandSmoke = true
        let saved = draft.normalized.tobacco
        #expect(saved.products.isEmpty && saved.startYear == nil && saved.cigarettesPerDay == nil && saved.quitMonth == nil)
        #expect(saved.secondhandSmoke == true, "second-hand smoke is asked of everyone")

        // An unanswered status still asks the details, like the web.
        draft.smokingStatus = nil
        #expect(draft.asksTobaccoDetails && !draft.asksQuitMonth)
    }

    @Test("night work only with shift work")
    func nightWorkFollowUp() throws {
        let current = try section("work", "WORK", [
            Fx.fact("s1", "SHIFT_SCHEDULE", #""ROTATING""#),
            Fx.fact("w1", "WORK_CONTEXT", Fx.workValue)
        ])
        var draft = LifeSectionDraft(section: current)
        #expect(draft.asksNightWork)
        draft.shiftSchedule = .declaredNone
        let writes = draft.writes(against: current, validFrom: nil)
        #expect(writes.count == 2)
        guard case let .correct(_, kind, value, _) = writes.last else {
            Issue.record("expected the work context to drop night work")
            return
        }
        #expect(kind == .workContext)
        #expect(try json(value)["nightWork"] is NSNull)
    }

    @Test("an answer this build cannot read is never written over, whatever the form holds")
    func unsupportedIsProtected() throws {
        let current = try section("goals", "GOALS", [Fx.fact("g1", "HEALTH_GOALS", #"{"schema":2,"goals":[]}"#)])
        var draft = LifeSectionDraft(section: current)
        #expect(draft.writes(against: current, validFrom: nil).isEmpty)
        draft.goals.goals = [.sleep]
        #expect(draft.writes(against: current, validFrom: nil).isEmpty)
    }

    @Test("an unreadable answer is not deleted by an empty form, only replaced by a new answer")
    func unreadableIsReplacedOnlyOnPurpose() throws {
        let current = try section("goals", "GOALS", [Fx.fact("g1", "HEALTH_GOALS", "null", unreadable: true)])
        var draft = LifeSectionDraft(section: current)
        #expect(draft.writes(against: current, validFrom: nil).isEmpty)
        draft.goals.goals = [.fitness]
        guard case let .correct(id, _, _, _) = draft.writes(against: current, validFrom: nil).first else {
            Issue.record("expected a correction of the unreadable revision")
            return
        }
        #expect(id == "g1")
    }

    @Test("free weekdays compare as a set in ISO order")
    func weekdaysOrder() throws {
        let current = try section("work", "WORK", [Fx.fact("f1", "FREE_WEEKDAYS", Fx.freeValue)])
        var draft = LifeSectionDraft(section: current)
        #expect(!draft.hasChanges(against: current), "server order 7,6 is the same answer")
        draft.freeWeekdays.days = [.saturday, .sunday]
        #expect(!draft.hasChanges(against: current))
        draft.freeWeekdays.days = [.friday, .saturday, .sunday]
        #expect(draft.writes(against: current, validFrom: nil).count == 1)
    }

    @Test("the update path: a smoking status from the old anamnesis screen is the starting answer")
    func updatePathFromOldScreen() throws {
        // A 1.4.1 install answered smoking on the old screen; the new kinds do not exist yet.
        let current = try section("tobacco", "SMOKING_STATUS", [Fx.fact("old", "SMOKING_STATUS", #""CURRENT""#)])
        var draft = LifeSectionDraft(section: current)
        #expect(draft.smokingStatus == .current)
        #expect(draft.tobacco == .empty)
        draft.tobacco.products = [.cigarettes]
        draft.tobacco.cigarettesPerDay = 5
        let writes = draft.writes(against: current, validFrom: nil)
        #expect(writes.count == 1, "the old answer stays untouched")
        guard case let .create(kind, _, _) = writes.first else {
            Issue.record("expected only a create for the new detail")
            return
        }
        #expect(kind == .tobaccoDetail)
    }
}
