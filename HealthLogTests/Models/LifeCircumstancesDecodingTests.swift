// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **LIFE (1.5.0, #132)** — the read route decodes every kind of the
/// v1.47.0 contract, skips what it does not know without losing the rest, and
/// keeps an answer it cannot read in full away from the editor.
@Suite("LifeCircumstancesDecoding")
struct LifeCircumstancesDecodingTests {
    typealias Fx = LifeCircumstancesFixtures

    @Test("every kind decodes; an unknown kind and an unknown section are skipped")
    func decodesEveryKind() throws {
        let payload = try Fx.decode(Fx.full)
        #expect(payload.sections.map(\.key) == [.tobacco, .alcohol, .activity, .work, .habits, .goals])
        let tobacco = try #require(payload.section(.tobacco))
        #expect(tobacco.facts.count == 2, "SOMETHING_NEW is skipped")
        #expect(tobacco.fact(.smokingStatus)?.value == .smokingStatus(.former))
        guard case let .tobacco(detail) = tobacco.fact(.tobaccoDetail)?.value else {
            Issue.record("tobacco detail did not decode")
            return
        }
        #expect(detail.products == [.cigarettes])
        #expect(detail.cigarettesPerDay == 10)
        #expect(detail.startYear == 1998)
        #expect(detail.quitMonth == LifeYearMonth(year: 2019, month: 3))
        #expect(detail.secondhandSmoke == nil)

        let activity = try #require(payload.section(.activity))
        #expect(activity.reviewDue)
        #expect(activity.fact(.activityHabit)?.value == .activity(
            LifeActivityHabit(moderateDaysPerWeek: 3, moderateMinutesPerDay: 40, sittingHoursWorkday: 7.5)
        ))
        let work = try #require(payload.section(.work))
        #expect(work.fact(.shiftSchedule)?.value == .shiftSchedule(.rotating))
        #expect(work.fact(.workContext)?.value == .work(
            LifeWorkContext(situation: .indoor, physicalNature: .mostlySitting, nightWork: true, exposures: [.noise])
        ))
        #expect(work.fact(.freeWeekdays)?.value == .freeWeekdays(LifeFreeWeekdays(days: [.sunday, .saturday])))
        guard case let .habits(habits) = payload.section(.habits)?.fact(.habits)?.value else {
            Issue.record("habits did not decode")
            return
        }
        #expect(habits.latestCaffeine == .noonTo15)
        #expect(habits.dietSpecifics == [.lowCarb])
        #expect(payload.section(.goals)?.fact(.healthGoals)?.value == .goals(LifeHealthGoals(goals: [.sleep, .fitness])))
        let alcohol = try #require(payload.section(.alcohol))
        #expect(alcohol.aiSection == "ALCOHOL_PATTERN")
        #expect(!alcohol.aiIncluded)
        #expect(alcohol.lastConfirmedAt == nil)
        #expect(payload.shiftScheduleAIIncluded == false)
    }

    @Test("derived values decode as delivered; an unknown hint is skipped, an unknown reason kept raw")
    func decodesDerived() throws {
        let derived = try Fx.decode(Fx.full).derived
        #expect(derived.packYears == .init(value: 10.5, status: .computed))
        #expect(derived.activityMinutesPerWeek == .init(value: 120, meetsWho150: false, measuredStepsAvailable: true))
        #expect(derived.freeWeekdays?.isDefault == false)
        #expect(derived.screeningHints.map(\.id) == [.lungLowDoseCT])
        let hint = try #require(derived.screeningHints.first)
        #expect(hint.status == .notEligible)
        #expect(hint.reasonKeys == ["pack_years_below_15", "a_reason_from_tomorrow"])
        #expect(hint.sourceURL?.host == "www.g-ba.de")
        // The screen names the known reason and leaves the unknown one out.
        #expect(LifeCopy.screeningReason("pack_years_below_15") != nil)
        #expect(LifeCopy.screeningReason("a_reason_from_tomorrow") == nil)
    }

    @Test("another schema, an unknown option and a value of the wrong kind are unsupported, not dropped")
    func unsupportedValues() throws {
        let json = Fx.payload(sections: [
            Fx.section("tobacco", "SMOKING_STATUS", facts: [
                Fx.fact("a", "SMOKING_STATUS", #""SOMETIMES""#),
                Fx.fact("b", "TOBACCO_DETAIL", #"{"schema":2,"products":[]}"#)
            ]),
            Fx.section("goals", "GOALS", facts: [Fx.fact("c", "HEALTH_GOALS", #"{"schema":1,"goals":["happiness"]}"#)]),
            Fx.section("work", "WORK", facts: [Fx.fact("d", "FREE_WEEKDAYS", "null", unreadable: true)])
        ])
        let payload = try Fx.decode(json)
        #expect(payload.section(.tobacco)?.fact(.smokingStatus)?.value == .unsupported)
        #expect(payload.section(.tobacco)?.fact(.tobaccoDetail)?.value == .unsupported)
        #expect(payload.section(.goals)?.fact(.healthGoals)?.value == .unsupported)
        #expect(payload.section(.work)?.fact(.freeWeekdays)?.value == .unreadable)
        #expect(payload.section(.tobacco)?.validSince == nil, "no readable answer, no 'valid since'")
    }

    @Test("a payload without derived values still decodes; nothing is invented")
    func missingDerived() throws {
        let json = #"{"sections":[],"extraAiSections":{},"auditC":{},"takeOver":[]}"#
        let payload = try Fx.decode(json)
        #expect(payload.sections.isEmpty)
        #expect(payload.derived == .none)
        #expect(payload.shiftScheduleAIIncluded == nil)
    }

    @Test("the quit month parses only YYYY-MM, like the contract's pattern")
    func yearMonthWire() throws {
        #expect(LifeYearMonth(wire: "2019-03") == LifeYearMonth(year: 2019, month: 3))
        #expect(LifeYearMonth(wire: "2019-3") == nil)
        #expect(LifeYearMonth(wire: "2019-13") == nil)
        #expect(LifeYearMonth(wire: "2019-03-01") == nil)
        #expect(LifeYearMonth(wire: "19-03") == nil)
        #expect(LifeYearMonth(year: 2019, month: 3)?.wire == "2019-03")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let ym = try #require(LifeYearMonth(year: 2019, month: 3))
        #expect(try LifeYearMonth(date: #require(ym.date(calendar: calendar)), calendar: calendar) == ym, "the picker anchor round-trips")
    }

    @Test("the quit-month wheels never store a month after this one")
    func quitMonthClamp() throws {
        let now = try #require(LifeYearMonth(year: 2026, month: 11))
        #expect(LifeMonthPickerRow.clamped(year: 2026, month: 12, now: now) == now)
        #expect(LifeMonthPickerRow.clamped(year: 2026, month: 3, now: now) == LifeYearMonth(year: 2026, month: 3))
        #expect(LifeMonthPickerRow.clamped(year: 2019, month: 3, now: now) == LifeYearMonth(year: 2019, month: 3))
    }

    @Test("features.lifeCircumstances opens the About me row; absent or false keeps it closed")
    func featureFlag() throws {
        let on = try JSONDecoder.hlDefault.decode(ServerFeatures.self, from: Data(#"{"lifeCircumstances":true}"#.utf8))
        let off = try JSONDecoder.hlDefault.decode(ServerFeatures.self, from: Data(#"{"lifeCircumstances":false}"#.utf8))
        let absent = try JSONDecoder.hlDefault.decode(ServerFeatures.self, from: Data("{}".utf8))
        let odd = try JSONDecoder.hlDefault.decode(ServerFeatures.self, from: Data(#"{"lifeCircumstances":"yes"}"#.utf8))
        #expect(LifeCircumstancesEntryRow.isOffered(on))
        #expect(!LifeCircumstancesEntryRow.isOffered(off))
        #expect(!LifeCircumstancesEntryRow.isOffered(absent))
        #expect(!LifeCircumstancesEntryRow.isOffered(odd))
        #expect(!LifeCircumstancesEntryRow.isOffered(nil), "no /me yet, an older server or standalone: no row")
    }
}
