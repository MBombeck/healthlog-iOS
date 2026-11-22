import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping file_length

// Server 1.49.0 on the app side, part B (#191): the energy balance, the
// notable-value push, the allowed range of a refused field, the analytics
// range in the account's unit, Apple Health screener rows in the history and
// the scheduled doctor report. Fixture shapes follow `release/v1.49.0`.
// Every suite also reads what a server before the field sends.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder.hlDefault.decode(type, from: Data(json.utf8))
}

// MARK: - Energy balance

@Suite("1.49 energy balance: decode and what the page shows")
struct CatchupBEnergyBalanceTests {
    /// Shape of `computeEnergyBalance`: seven closed days, today partial.
    static let body = #"""
    {"windowDays":8,"days":[
      {"day":"2026-11-14","intakeKcal":2100,"restingKcal":1650,"restingEstimated":false,"activeKcal":500,"expenditureKcal":2150,"balanceKcal":-50,"trendKcal":null,"partial":false},
      {"day":"2026-11-15","intakeKcal":2400,"restingKcal":1600,"restingEstimated":true,"activeKcal":400,"expenditureKcal":2000,"balanceKcal":400,"trendKcal":null,"partial":false},
      {"day":"2026-11-16","intakeKcal":null,"restingKcal":1650,"restingEstimated":false,"activeKcal":300,"expenditureKcal":1950,"balanceKcal":null,"trendKcal":null,"partial":false},
      {"day":"2026-11-17","intakeKcal":1900,"restingKcal":1650,"restingEstimated":false,"activeKcal":450,"expenditureKcal":2100,"balanceKcal":-200,"trendKcal":null,"partial":false},
      {"day":"2026-11-18","intakeKcal":2000,"restingKcal":1650,"restingEstimated":false,"activeKcal":250,"expenditureKcal":1900,"balanceKcal":100,"trendKcal":63,"partial":false},
      {"day":"2026-11-19","intakeKcal":2200,"restingKcal":null,"restingEstimated":false,"activeKcal":350,"expenditureKcal":null,"balanceKcal":null,"trendKcal":63,"partial":false},
      {"day":"2026-11-20","intakeKcal":2050,"restingKcal":1650,"restingEstimated":false,"activeKcal":500,"expenditureKcal":2150,"balanceKcal":-100,"trendKcal":30,"partial":false},
      {"day":"2026-11-21","intakeKcal":900,"restingKcal":1650,"restingEstimated":false,"activeKcal":120,"expenditureKcal":1770,"balanceKcal":-870,"trendKcal":null,"partial":true}
    ],"summary":{"daysWithBalance":5,"meanIntakeKcal":2080,"meanExpenditureKcal":2060,"meanBalanceKcal":30},
    "estimateGaps":[]}
    """#

    @Test("null stays null, never zero, and today is the running day")
    func decodesNullsAndPartial() throws {
        let balance = try decode(EnergyBalanceDTO.self, Self.body)
        #expect(balance.days.count == 8)
        let gap = try #require(balance.days.first { $0.day == "2026-11-16" })
        #expect(gap.intakeKcal == nil)
        #expect(gap.balanceKcal == nil)
        #expect(balance.runningDay?.day == "2026-11-21")
        #expect(balance.completeDays.count == 7)
        #expect(balance.days[1].restingEstimated)
    }

    @Test("the headline is the latest trend of a closed day, never today")
    func headlineIsTrend() throws {
        let balance = try decode(EnergyBalanceDTO.self, Self.body)
        #expect(balance.latestTrendKcal == 30)
        #expect(balance.headlineKcal == 30)
        #expect(balance.headlineIsTrend)
        #expect(balance.missingReason == nil)
    }

    @Test("the listed days carry a balance, newest first, today left out")
    func listedDays() throws {
        let balance = try decode(EnergyBalanceDTO.self, Self.body)
        let listed = balance.listedDays()
        #expect(listed.map(\.day) == ["2026-11-20", "2026-11-18", "2026-11-17", "2026-11-15", "2026-11-14"])
        #expect(balance.listedDays(limit: 2).map(\.day) == ["2026-11-20", "2026-11-18"])
        #expect(balance.estimatedDayCount == 1)
    }

    @Test("without a trend the headline is the window mean")
    func headlineFallsBackToMean() throws {
        let body = Self.body.replacingOccurrences(of: #""trendKcal":63"#, with: #""trendKcal":null"#)
            .replacingOccurrences(of: #""trendKcal":30"#, with: #""trendKcal":null"#)
        let balance = try decode(EnergyBalanceDTO.self, body)
        #expect(balance.latestTrendKcal == nil)
        #expect(balance.headlineKcal == 30)
        #expect(!balance.headlineIsTrend)
    }

    @Test("no balance at all names what is missing")
    func missingReason() throws {
        let profile = try decode(EnergyBalanceDTO.self, #"""
        {"windowDays":7,"days":[{"day":"2026-11-20","intakeKcal":2000,"restingKcal":null,"restingEstimated":false,
          "activeKcal":null,"expenditureKcal":null,"balanceKcal":null,"trendKcal":null,"partial":false}],
         "summary":{"daysWithBalance":0,"meanIntakeKcal":null,"meanExpenditureKcal":null,"meanBalanceKcal":null},
         "estimateGaps":["height","sex"]}
        """#)
        #expect(profile.hasIntake)
        #expect(profile.headlineKcal == nil)
        #expect(profile.missingReason == .needsProfile)
        let active = try decode(EnergyBalanceDTO.self, #"""
        {"windowDays":7,"days":[{"day":"2026-11-20","intakeKcal":2000,"restingKcal":1600,"restingEstimated":false,
          "activeKcal":null,"expenditureKcal":null,"balanceKcal":null,"trendKcal":null,"partial":false}],
         "summary":{"daysWithBalance":0,"meanIntakeKcal":null,"meanExpenditureKcal":null,"meanBalanceKcal":null},
         "estimateGaps":[]}
        """#)
        #expect(active.missingReason == .needsExpenditure)
    }

    @Test("a day this build cannot read costs that day, a missing summary reads empty")
    func lossyDays() throws {
        let balance = try decode(EnergyBalanceDTO.self, #"""
        {"windowDays":7,"days":[{"intakeKcal":5},{"day":"2026-11-20","intakeKcal":"x","balanceKcal":12}]}
        """#)
        #expect(balance.days.map(\.day) == ["2026-11-20"])
        #expect(balance.days.first?.intakeKcal == nil)
        #expect(balance.days.first?.balanceKcal == 12)
        #expect(balance.summary.daysWithBalance == 0)
        #expect(balance.estimateGaps.isEmpty)
        #expect(!balance.hasIntake)
    }

    @Test("a window without any intake shows no row")
    func noIntakeHides() throws {
        let balance = try decode(EnergyBalanceDTO.self, #"""
        {"windowDays":7,"days":[{"day":"2026-11-20","intakeKcal":null,"balanceKcal":null}],"summary":{"daysWithBalance":0},"estimateGaps":[]}
        """#)
        #expect(EnergyBalanceModel.state(for: balance) == .hidden)
        let full = try decode(EnergyBalanceDTO.self, Self.body)
        #expect(EnergyBalanceModel.state(for: full) == .loaded(full))
    }

    @Test("module off and an older server hide the row; other failures offer a retry", arguments: [
        (HLError.moduleDisabled("nutrients"), EnergyBalanceModel.State?.some(.hidden)),
        (HLError.server(status: 403, code: "module.disabled", message: "off"), .some(.hidden)),
        (HLError.server(status: 404, code: nil, message: "Not found"), .some(.hidden)),
        (HLError.server(status: 500, code: nil, message: "boom"), .some(.failed)),
        (HLError.network(.timeout), .some(.failed)),
        (HLError.canceled, nil)
    ])
    func stateAfterError(error: HLError, expected: EnergyBalanceModel.State?) {
        #expect(EnergyBalanceModel.state(after: error) == expected)
    }

    @Test("the page's figures are the server's, with their sign")
    func format() throws {
        #expect(EnergyBalanceFormat.signedKcal(120).hasPrefix("+"))
        #expect(EnergyBalanceFormat.signedKcal(120).hasSuffix(" kcal"))
        #expect(!EnergyBalanceFormat.signedKcal(-340).hasPrefix("+"))
        #expect(EnergyBalanceFormat.signedKcal(-340).contains("340"))
        let balance = try decode(EnergyBalanceDTO.self, Self.body)
        #expect(EnergyBalanceFormat.headlineMeta(balance) == String(localized: "nutrients.energyBalance.trendMeta"))
        #expect(EnergyBalanceFormat.estimatedNote(balance) == String(localized: "nutrients.energyBalance.estimated.one"))
        let gap = try #require(balance.days.first { $0.day == "2026-11-19" })
        #expect(EnergyBalanceFormat.dayLine(gap) == nil)
        #expect(try EnergyBalanceScreen
            .status(for: #require(balance.runningDay)) == HLRowStatus(String(localized: "nutrients.energyBalance.running")))
        #expect(EnergyBalanceScreen
            .status(for: balance.days[1]) == HLRowStatus(String(localized: "nutrients.energyBalance.restingEstimated")))
        #expect(EnergyBalanceScreen.status(for: balance.days[0]) == nil)
    }

    @Test("today and yesterday by name, other days by date")
    func dayTitle() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 9)))
        let today = EnergyBalanceDTO.Day(
            day: "2026-11-21",
            intakeKcal: nil,
            restingKcal: nil,
            activeKcal: nil,
            expenditureKcal: nil,
            balanceKcal: nil
        )
        let yesterday = EnergyBalanceDTO.Day(
            day: "2026-11-20",
            intakeKcal: nil,
            restingKcal: nil,
            activeKcal: nil,
            expenditureKcal: nil,
            balanceKcal: nil
        )
        let earlier = EnergyBalanceDTO.Day(
            day: "2026-11-12",
            intakeKcal: nil,
            restingKcal: nil,
            activeKcal: nil,
            expenditureKcal: nil,
            balanceKcal: nil
        )
        #expect(EnergyBalanceFormat.dayTitle(today, now: now, calendar: calendar) == String(localized: "Today"))
        #expect(EnergyBalanceFormat.dayTitle(yesterday, now: now, calendar: calendar) == String(localized: "Yesterday"))
        #expect(EnergyBalanceFormat.dayTitle(earlier, now: now, calendar: calendar) == RelatedRecordFormat.date("2026-11-12"))
    }
}

@Suite("1.49 energy balance: the read", .serialized, .mockURLSession)
struct CatchupBEnergyBalanceReadTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    @Test("asks the thirty-day window and decodes the envelope")
    func readsWindow() async throws {
        MockURLProtocol.install { req in
            #expect(req.url?.path == "/api/nutrients/energy-balance")
            let days = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "days" }?.value
            #expect(days == "30")
            let body = #"{"data":\#(CatchupBEnergyBalanceTests.body),"error":null}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let balance = try await EnergyBalanceRepository(api: makeAPI()).read()
        #expect(balance.days.count == 8)
    }

    @Test("a window outside 7 to 90 days is clamped before it is asked")
    func clampsWindow() async throws {
        MockURLProtocol.install { req in
            let days = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "days" }?.value
            #expect(days == "90")
            let body = #"{"data":{"windowDays":90,"days":[],"summary":{"daysWithBalance":0},"estimateGaps":[]},"error":null}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        _ = try await EnergyBalanceRepository(api: makeAPI()).read(days: 365)
    }

    @Test("an older server's 404 hides the row")
    @MainActor
    func olderServer() async {
        MockURLProtocol.install { req in
            let body = #"{"data":null,"error":"Not found"}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let api = makeAPI()
        let model = EnergyBalanceModel()
        let repository = EnergyBalanceRepository(api: api)
        await model.load { try await repository.read() }
        #expect(model.state == .hidden)
    }
}

// MARK: - MEASUREMENT_ANOMALY

#if canImport(UserNotifications) && canImport(UIKit)
    @Suite("1.49 notable value: opt-in row and tap target")
    @MainActor
    struct CatchupBMeasurementAnomalyTests {
        private func payload(url: String?, event: String = "MEASUREMENT_ANOMALY") -> APNsPayload {
            APNsPayload(title: "t", body: "b", eventType: event, metricType: nil, deepLink: nil, url: url)
        }

        @Test("the server's tap target /insights opens Insights")
        func pathOpensInsights() {
            #expect(DeepLinkRoute.fromPushPath("/insights") == .insights(metric: nil))
            #expect(NotificationService.bodyTapTarget(for: payload(url: "/insights")) == .route(.insights(metric: nil)))
        }

        @Test("without a url the event itself opens Insights; another event stays where it was")
        func eventFallback() {
            #expect(NotificationService.bodyTapTarget(for: payload(url: nil)) == .route(.insights(metric: nil)))
            #expect(NotificationService.bodyTapTarget(for: payload(url: nil, event: "SYSTEM_ALERT")) == nil)
        }

        @Test("the matrix names it, with how often it comes, ranked with the insights")
        func matrixRow() {
            #expect(NotificationEventLocalization.title(for: "MEASUREMENT_ANOMALY") == String(localized: "Notable value"))
            #expect(NotificationEventLocalization.hint(for: "MEASUREMENT_ANOMALY")
                == String(localized: "notifications.event.measurementAnomaly.hint"))
            #expect(NotificationEventPriority.rank(of: "MEASUREMENT_ANOMALY")
                > NotificationEventPriority.rank(of: "INSIGHT_READY"))
        }

        @Test("the row shows the server's default, off")
        func offByDefault() throws {
            let payload = try decode(NotificationPreferencesPayload.self, #"""
            {"channels":[{"id":"c1","type":"APNS","label":"iPhone","enabled":true,"globallyEnabled":true}],
             "preferences":[{"channelId":"c1","eventType":"MEASUREMENT_ANOMALY","enabled":false}],
             "eventTypes":["DAILY_BRIEFING","MEASUREMENT_ANOMALY"]}
            """#)
            #expect(payload.eventTypes.contains("MEASUREMENT_ANOMALY"))
            #expect(payload.preferences.first { $0.eventType == "MEASUREMENT_ANOMALY" }?.enabled == false)
        }
    }
#endif

// MARK: - Allowed range of a refused field

@Suite("1.49 a refused field names its allowed range")
struct CatchupBValidationBoundsTests {
    private static func body(_ issues: String) -> Data {
        Data(#"{"data":null,"error":"Validation failed","details":{"issues":[\#(issues)]}}"#.utf8)
    }

    @Test("a too-big number reads as an inclusive maximum")
    func maximum() throws {
        let bounds = try #require(APIValidationBounds.from(body: Self.body(
            #"{"path":"targets.magnesium.value","code":"too_big","message":"Too big","maximum":5000,"inclusive":true,"origin":"number"}"#
        )))
        #expect(bounds.maximum == .init(value: 5000, inclusive: true))
        #expect(bounds.minimum == nil)
        #expect(bounds.origin == .number)
        #expect(bounds.rangeText == String(localized: "error.bounds.atMost \(HLValueFormat.number(5000, fractionDigits: 0 ... 2))"))
    }

    @Test("positive() reads as above zero")
    func exclusiveMinimum() throws {
        let bounds = try #require(APIValidationBounds.from(body: Self.body(
            #"{"path":"value","code":"too_small","message":"Too small","minimum":0,"inclusive":false,"origin":"number"}"#
        )))
        #expect(bounds.rangeText == String(localized: "error.bounds.above \(HLValueFormat.number(0, fractionDigits: 0 ... 2))"))
    }

    @Test("two bounds of one field join into a range; a text's length counts characters")
    func joinedAndString() throws {
        let joined = try #require(APIValidationBounds.from(body: Self.body(
            #"{"path":"a","code":"too_small","minimum":1,"inclusive":true},{"path":"a","code":"too_big","maximum":10,"inclusive":true}"#
        )))
        #expect(joined.minimum?.value == 1)
        #expect(joined.maximum?.value == 10)
        let text = try #require(APIValidationBounds.from(body: Self.body(
            #"{"path":"note","code":"too_big","maximum":128,"inclusive":true,"origin":"string"}"#
        )))
        #expect(text.origin == .string)
        #expect(text
            .rangeText ==
            String(
                localized: "error.bounds.atMost \(String(localized: "error.bounds.characters \(HLValueFormat.number(128, fractionDigits: 0 ... 2))"))"
            ))
    }

    @Test("no bound, a date bound, another status: the message stays the server's")
    func noBound() {
        #expect(APIValidationBounds.from(body: Self.body(#"{"path":"a","code":"invalid_type","message":"Expected number"}"#)) == nil)
        #expect(APIValidationBounds.from(body: Self.body(#"{"path":"d","code":"too_big","maximum":1767225600000,"origin":"date"}"#)) == nil)
        #expect(APIValidationBounds.from(body: Data(#"{"data":null,"error":"Validation failed"}"#.utf8)) == nil)
        let bounded = Self.body(#"{"path":"a","code":"too_big","maximum":5}"#)
        #expect(APIValidationBounds.message(status: 400, serverMessage: "Validation failed", body: bounded) == nil)
        #expect(APIValidationBounds.message(status: 422, serverMessage: "Validation failed", body: bounded) != nil)
        #expect(APIValidationBounds.message(status: 422, serverMessage: nil, body: bounded) != nil)
        // A sentence the route composed itself stays; callers may match on it.
        #expect(APIValidationBounds.message(status: 422, serverMessage: "Unknown selection leaf x", body: bounded) == nil)
    }
}

@Suite("1.49 the nutrient target editor names the range", .serialized, .mockURLSession)
@MainActor
struct CatchupBTargetRangeTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    @Test("a 422 with a maximum becomes the store's sentence with the range")
    func storeShowsRange() async throws {
        MockURLProtocol.install { req in
            let issue = #"{"path":"targets.magnesium.value","code":"too_big","message":"Too big","maximum":5000,"inclusive":true,"origin":"number"}"#
            let body = #"{"data":null,"error":"Validation failed","details":{"issues":[\#(issue)]},"meta":{"requestId":"r1","errorCode":"validation_failed"}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let repository = try NutrientReadRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        let store = NutrientStore(repository: repository)
        let saved = await store.setTarget(NutrientPersonalTarget(value: 90000, direction: .target), for: .magnesium)
        #expect(!saved)
        let expected = APIValidationBounds(
            minimum: nil,
            maximum: .init(value: 5000, inclusive: true),
            origin: .number
        ).sentence
        #expect(store.lastError == expected)
    }

    @Test("an older server's 422 keeps its own message")
    func olderServerKeepsMessage() async throws {
        MockURLProtocol.install { req in
            let body = #"{"data":null,"error":"Validation failed","details":{"issues":[{"path":"targets.magnesium.value","code":"too_big","message":"Too big"}]}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let repository = try NutrientReadRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        let store = NutrientStore(repository: repository)
        _ = await store.setTarget(NutrientPersonalTarget(value: 90000, direction: .target), for: .magnesium)
        #expect(store.lastError == "Validation failed")
    }
}

// MARK: - Analytics range in the account's unit

@Suite("1.49 analytics range in the account's unit")
struct CatchupBRangeUnitTests {
    private static func body(unit: String?) -> String {
        let field = unit.map { #","unit":"\#($0)""# } ?? ""
        return #"{"range":"30d","windowDays":30,"delta":-0.4,"deltaPct":-0.07,"trend":"down"\#(field)}"#
    }

    @Test("the unit decodes; an older server has none")
    func decodesUnit() throws {
        #expect(try decode(AnalyticsRangeTrend.self, Self.body(unit: "mmol/L")).unit == "mmol/L")
        #expect(try decode(AnalyticsRangeTrend.self, Self.body(unit: "mmol/L")).isInAccountUnit)
        #expect(try decode(AnalyticsRangeTrend.self, Self.body(unit: nil)).unit == nil)
        #expect(try decode(AnalyticsRangeTrend.self, Self.body(unit: "")).unit == nil)
    }

    @Test("glucose takes the window comparison only with a unit")
    func glucoseNeedsUnit() throws {
        let new = try decode(AnalyticsRangeTrend.self, Self.body(unit: "mmol/L"))
        let old = try decode(AnalyticsRangeTrend.self, Self.body(unit: nil))
        #expect(ChartDetailStore.usableRangeTrend(new, kind: .glucose) == new)
        #expect(ChartDetailStore.usableRangeTrend(old, kind: .glucose) == nil)
        #expect(ChartDetailStore.usableRangeTrend(old, kind: .weight) == old)
        #expect(ChartDetailStore.usableRangeTrend(nil, kind: .weight) == nil)
    }

    @Test("a change in the account's unit is marked so it is never converted again")
    func changeKeepsUnitFlag() throws {
        let new = try decode(AnalyticsRangeTrend.self, Self.body(unit: "lb"))
        let change = try #require(ChartDetailStore.rangeChange(series: nil, rangeTrend: new))
        #expect(change.inAccountUnit)
        #expect(change.delta == -0.4)
        let old = try decode(AnalyticsRangeTrend.self, Self.body(unit: nil))
        #expect(ChartDetailStore.rangeChange(series: nil, rangeTrend: old)?.inAccountUnit == false)
    }

    @Test("glucose is asked of the route since 1.49")
    func glucoseQuery() {
        #expect(MetricInsightsRepository.rangeQuery(for: .glucose, windowDays: 30)?.type == "BLOOD_GLUCOSE")
        #expect(MetricInsightsRepository.rangeQuery(for: .glucose, windowDays: 180) == nil)
    }
}

// MARK: - Screener list rows

@Suite("1.49 screener history names an Apple Health score without answers")
struct CatchupBAssessmentListTests {
    private static func row(_ extra: String) -> String {
        #"""
        {"id":"a1","instrument":"PHQ9","locale":"de","version":"standard","totalScore":6,"severityBand":"mild",
         "item9Flagged":false,"crisisShownAt":null,"takenAt":"2026-11-10T08:00:00.000Z","createdAt":"2026-11-10T08:00:00.000Z"\#(extra)}
        """#
    }

    @Test("source and itemsUnavailable decode; an older server reads as before")
    func decodes() throws {
        let apple = try decode(MentalHealthAssessmentDTO.self, Self.row(#","source":"APPLE_HEALTH","itemsUnavailable":true"#))
        #expect(apple.source == "APPLE_HEALTH")
        #expect(apple.itemsUnavailable)
        #expect(apple.isAppleHealthScoreOnly)
        let old = try decode(MentalHealthAssessmentDTO.self, Self.row(""))
        #expect(old.source == nil)
        #expect(!old.itemsUnavailable)
        #expect(!old.isAppleHealthScoreOnly)
        let web = try decode(MentalHealthAssessmentDTO.self, Self.row(#","source":"WEB","itemsUnavailable":false"#))
        #expect(!web.isAppleHealthScoreOnly)
    }

    @Test("the history row says the score came alone")
    func rowNote() throws {
        let apple = try decode(MentalHealthAssessmentDTO.self, Self.row(#","source":"APPLE_HEALTH","itemsUnavailable":true"#))
        #expect(MentalHealthHistoryRowContent(row: apple).detail == String(localized: "mentalHealth.history.appleHealthScoreOnly"))
        let old = try decode(MentalHealthAssessmentDTO.self, Self.row(""))
        #expect(MentalHealthHistoryRowContent(row: old).detail == nil)
    }
}

// MARK: - Scheduled doctor report

@Suite("1.49 a scheduled doctor report decodes and is named")
struct CatchupBScheduledReportTests {
    private static func document(source: String) -> String {
        #"""
        {"id":"d1","kind":"OTHER","title":"Arztbericht","filename":"bericht.pdf","mimeType":"application/pdf",
         "byteSize":2048,"status":"STORED","providerType":null,"reportDate":null,"documentDate":"2026-11-20",
         "errorReason":null,"factCount":0,"pendingCount":0,"conditionLinks":[],"servingClass":"inline",
         "hasContentIndex":false,"contentIndexSource":null,"lastIndexAttemptAt":null,"lastIndexOutcome":null,
         "hasThumbnail":false,\#(source),
         "createdAt":"2026-11-20T08:00:00.000Z","updatedAt":"2026-11-20T08:00:00.000Z"}
        """#
    }

    @Test("REPORT_SCHEDULE decodes and opens no archive link")
    func decodes() throws {
        let report = try decode(InboundDocument.self, Self.document(source: #""sourceSystem":"REPORT_SCHEDULE","sourceUrl":null"#))
        #expect(report.isScheduledReport)
        #expect(report.sourceLink == nil)
        let upload = try decode(InboundDocument.self, Self.document(source: #""sourceSystem":null"#))
        #expect(!upload.isScheduledReport)
        let paperless = try decode(InboundDocument.self, Self.document(source: #""sourceSystem":"PAPERLESS""#))
        #expect(!paperless.isScheduledReport)
    }
}
