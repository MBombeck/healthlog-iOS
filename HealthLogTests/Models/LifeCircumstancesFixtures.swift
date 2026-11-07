import Foundation
@testable import HealthLog

/// **LIFE (1.5.0)** — wire fixtures of `GET /api/anamnesis/life-circumstances`
/// in the v1.47.0 shape. Invented values only.
enum LifeCircumstancesFixtures {
    static let date = "2026-03-01T12:00:00.000Z"

    static func fact(_ id: String, _ kind: String, _ value: String, unreadable: Bool = false) -> String {
        #"{"id":"\#(id)","kind":"\#(kind)","value":\#(value),"unreadable":\#(unreadable),"#
            + #""validFrom":"\#(date)","validUntil":null,"provenance":"USER_REPORTED","createdAt":"\#(date)"}"#
    }

    static let tobaccoValue = #"{"schema":1,"products":["cigarettes"],"cigarettesPerDay":10,"startYear":1998,"quitMonth":"2019-03","secondhandSmoke":null}"#
    static let activityValue = #"{"schema":1,"moderateDaysPerWeek":3,"moderateMinutesPerDay":40,"sittingHoursWorkday":7.5}"#
    static let workValue = #"{"schema":1,"situation":"indoor","physicalNature":"mostly_sitting","nightWork":true,"exposures":["noise"]}"#
    static let freeValue = #"{"schema":1,"days":[7,6]}"#
    static let habitsValue = #"{"schema":1,"napRegularly":false,"snoringReported":null,"dietPattern":"mixed","#
        + #""dietSpecifics":["low_carb"],"lateMealsPerWeek":2,"fruitVegPortionsPerDay":4,"caffeineDrinksPerDay":3,"#
        + #""latestCaffeine":"12_15"}"#
    static let goalsValue = #"{"schema":1,"goals":["sleep","fitness"]}"#

    static func section(
        _ key: String,
        _ ai: String,
        facts: [String],
        aiIncluded: Bool = true,
        reviewDue: Bool = false,
        confirmed: String? = date
    ) -> String {
        let stamp = confirmed.map { "\"\($0)\"" } ?? "null"
        return #"{"key":"\#(key)","aiSection":"\#(ai)","aiIncluded":\#(aiIncluded),"lastConfirmedAt":\#(stamp),"reviewDue":\#(reviewDue),"facts":[\#(facts.joined(separator: ","))]}"#
    }

    static let derived = #"""
    {"packYears":{"value":10.5,"status":"computed"},
     "activityMinutesPerWeek":{"value":120,"meetsWho150":false,"measuredStepsAvailable":true},
     "freeWeekdays":{"days":[6,7],"source":"fact"},
     "screeningHints":[
       {"id":"lung_ldct","status":"not_eligible","reasonKeys":["pack_years_below_15","a_reason_from_tomorrow"],"region":"DE",
        "sourceLabel":"G-BA, Beschluss vom 18.06.2025 (Deutschland)","sourceUrl":"https://www.g-ba.de/presse/pressemitteilungen-meldungen/1263/"},
       {"id":"colonoscopy_from_tomorrow","status":"suggested","reasonKeys":[],"region":"DE","sourceLabel":"x","sourceUrl":"https://x.invalid"}]}
    """#

    /// The `auditC` block of a server that has nothing on file and an
    /// instrument this build does not render (no items).
    static let emptyAuditC = #"{"latest":null,"history":[],"offerDue":true,"#
        + #""instrument":{"items":[],"locale":"de","validatedLocale":true,"standardDrink":"","attribution":""}}"#

    /// `auditC: nil` leaves the block out, as a server before v1.43 would.
    static func payload(
        sections: [String],
        derived: String = derived,
        extra: String = #"{"SHIFT_SCHEDULE":false}"#,
        auditC: String? = emptyAuditC
    ) -> String {
        let block = auditC.map { #""auditC":\#($0),"# } ?? ""
        return #"""
        {"sections":[\#(sections.joined(separator: ","))],"extraAiSections":\#(extra),"derived":\#(derived),
         \#(block)"takeOver":[]}
        """#
    }

    /// Every kind answered, plus one kind and one section from a newer server.
    static var full: String {
        payload(sections: [
            section("tobacco", "SMOKING_STATUS", facts: [
                fact("f-smoke", "SMOKING_STATUS", #""FORMER""#),
                fact("f-tob", "TOBACCO_DETAIL", tobaccoValue),
                fact("f-new", "SOMETHING_NEW", #"{"schema":1}"#)
            ]),
            section("alcohol", "ALCOHOL_PATTERN", facts: [], aiIncluded: false, confirmed: nil),
            section("activity", "ACTIVITY", facts: [fact("f-act", "ACTIVITY_HABIT", activityValue)], reviewDue: true),
            section("work", "WORK", facts: [
                fact("f-shift", "SHIFT_SCHEDULE", #""ROTATING""#),
                fact("f-work", "WORK_CONTEXT", workValue),
                fact("f-free", "FREE_WEEKDAYS", freeValue)
            ]),
            section("habits", "HABITS", facts: [fact("f-hab", "HABITS", habitsValue)]),
            section("goals", "GOALS", facts: [fact("f-goal", "HEALTH_GOALS", goalsValue)]),
            section("finances", "FINANCES", facts: [])
        ])
    }

    static func envelope(_ data: String) -> String {
        #"{"data":\#(data),"error":null}"#
    }

    static func decode(_ json: String) throws -> LifeCircumstances {
        try JSONDecoder.hlDefault.decode(LifeCircumstances.self, from: Data(json.utf8))
    }
}
