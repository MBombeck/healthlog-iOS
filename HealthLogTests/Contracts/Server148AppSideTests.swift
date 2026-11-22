import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping file_length

// The app side of server 1.48 (#176, #182 A2 / A8 / part B, #184).
// Fixture shapes follow `docs/api/openapi.yaml` at `v1.48.5`. Every suite
// also decodes the body of a server before the field, which must render as
// it did in 1.6.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder.hlDefault.decode(type, from: Data(json.utf8))
}

private func encodeObject(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder.hlDefault.encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - #176 trend window on the dashboard card

@Suite("#176 dashboard card trend window")
@MainActor
struct DashboardTrendWindowTests {
    private static func card(_ extra: String) -> String {
        #"{"id":"w","kind":"weight","titleKey":"dashboard.metric.title.weight","latestValue":80.2,"secondaryValue":null,"#
            + #""unitKey":"dashboard.metric.unit.kg","trend":"down","sparkline":[80.9,80.2],"updatedAt":null\#(extra)}"#
    }

    @Test("trendWindowDays 30 keeps the server's arrow")
    func monthWindowKeepsArrow() throws {
        let metric = try decode(DashboardMetric.self, Self.card(#","trendWindowDays":30"#))
        #expect(metric.deliversTrendWindow)
        #expect(metric.trendWindowDays == 30)
        #expect(metric.dashboardTrend == .down)
    }

    @Test("trendWindowDays null hides the arrow")
    func nullWindowHidesArrow() throws {
        let metric = try decode(DashboardMetric.self, Self.card(#","trendWindowDays":null"#))
        #expect(metric.deliversTrendWindow)
        #expect(metric.trendWindowDays == nil)
        #expect(metric.dashboardTrend == .unknown)
        #expect(TrendChip.symbolName(for: metric.dashboardTrend) == nil)
    }

    @Test("an older server without the field keeps its arrow")
    func olderServerKeepsArrow() throws {
        let metric = try decode(DashboardMetric.self, Self.card(""))
        #expect(!metric.deliversTrendWindow)
        #expect(metric.dashboardTrend == .down)
    }

    @Test("a delivered null survives the cache round trip")
    func roundTripKeepsNull() throws {
        let metric = try decode(DashboardMetric.self, Self.card(#","trendWindowDays":null"#))
        let data = try JSONEncoder.hlDefault.encode(metric)
        let back = try JSONDecoder.hlDefault.decode(DashboardMetric.self, from: data)
        #expect(back.deliversTrendWindow)
        #expect(back.dashboardTrend == .unknown)
        let month = try decode(DashboardMetric.self, Self.card(#","trendWindowDays":30"#))
        let monthBack = try JSONDecoder.hlDefault.decode(DashboardMetric.self, from: JSONEncoder.hlDefault.encode(month))
        #expect(monthBack.trendWindowDays == 30)
    }

    @Test("a malformed window reads as null, never fails the card")
    func malformedWindow() throws {
        let metric = try decode(DashboardMetric.self, Self.card(#","trendWindowDays":"thirty""#))
        #expect(metric.trendWindowDays == nil)
        #expect(metric.dashboardTrend == .unknown)
    }
}

// MARK: - #176 trend from /api/analytics/range

@Suite("#176 metric page range trend")
struct AnalyticsRangeTrendTests {
    private static func body(trend: String?, delta: String = "-0.4") -> String {
        let field = trend.map { #","trend":"\#($0)""# } ?? ""
        return #"{"range":"30d","windowDays":30,"granularity":"DAY","current":{"count":20},"previous":{"count":18},"delta":\#(delta),"deltaPct":-0.005\#(field)}"#
    }

    @Test("the server's trend and delta decode")
    func decodesTrend() throws {
        let value = try decode(AnalyticsRangeTrend.self, Self.body(trend: "down"))
        #expect(value.trend == .down)
        #expect(value.delta == -0.4)
        #expect(value.shownChange?.trend == .down)
    }

    @Test("an older server without trend shows nothing from this read")
    func olderServer() throws {
        let value = try decode(AnalyticsRangeTrend.self, Self.body(trend: nil))
        #expect(value.trend == .unknown)
        #expect(value.shownChange == nil)
    }

    @Test("unknown with a null delta shows nothing")
    func unknownTrend() throws {
        let value = try decode(AnalyticsRangeTrend.self, Self.body(trend: "unknown", delta: "null"))
        #expect(value.shownChange == nil)
    }

    @Test("the range change takes the server's direction, flat as a dash")
    func rangeChangeUsesServerTrend() throws {
        let flat = try decode(AnalyticsRangeTrend.self, Self.body(trend: "flat", delta: "0.04"))
        let change = try #require(ChartDetailStore.rangeChange(series: nil, rangeTrend: flat))
        #expect(change.basis == .priorWindow)
        #expect(change.trend == .flat)
        #expect(change.symbol == "minus")
        let down = try decode(AnalyticsRangeTrend.self, Self.body(trend: "down"))
        #expect(ChartDetailStore.rangeChange(series: nil, rangeTrend: down)?.symbol == "arrow.down")
    }

    @Test("the series verdict colours the pill only when it points the same way")
    func agreeingVerdict() {
        let falling = SeriesChange(from: 73, to: 72.4, delta: -0.6, sentiment: .positive)
        let rising = SeriesChange(from: 72, to: 72.4, delta: 0.4, sentiment: .negative)
        #expect(ChartDetailStore.agreeingSentiment(falling, trend: .down) == .positive)
        #expect(ChartDetailStore.agreeingSentiment(rising, trend: .down) == nil)
        #expect(ChartDetailStore.agreeingSentiment(rising, trend: .up) == .negative)
        #expect(ChartDetailStore.agreeingSentiment(falling, trend: .flat) == nil)
        #expect(ChartDetailStore.agreeingSentiment(nil, trend: .down) == nil)
    }

    @Test("without a range trend the series' own change stays")
    func fallsBackToSeries() {
        #expect(ChartDetailStore.rangeChange(series: nil, rangeTrend: nil) == nil)
        let unknown = AnalyticsRangeTrend(range: "30d", windowDays: 30, delta: nil, deltaPct: nil, trend: .unknown)
        #expect(ChartDetailStore.rangeChange(series: nil, rangeTrend: unknown) == nil)
    }

    @Test("the route is asked only for week, month and year; glucose too since 1.49")
    func rangeQuery() {
        #expect(MetricInsightsRepository.rangeQuery(for: .weight, windowDays: 30)?.range == "30d")
        #expect(MetricInsightsRepository.rangeQuery(for: .weight, windowDays: 7)?.range == "7d")
        #expect(MetricInsightsRepository.rangeQuery(for: .weight, windowDays: 365)?.range == "1y")
        #expect(MetricInsightsRepository.rangeQuery(for: .bloodPressure, windowDays: 30)?.type == "BLOOD_PRESSURE_SYS")
        #expect(MetricInsightsRepository.rangeQuery(for: .weight, windowDays: 1) == nil)
        #expect(MetricInsightsRepository.rangeQuery(for: .weight, windowDays: 180) == nil)
        #expect(MetricInsightsRepository.rangeQuery(for: .glucose, windowDays: 30)?.type == "BLOOD_GLUCOSE")
        #expect(MetricInsightsRepository.rangeQuery(for: .sleep, windowDays: 30) == nil)
    }

    @Test("the caption compares with the previous window, in the unit")
    func caption() throws {
        let result = try #require(MetricRangeDelta.resolve(.priorWindow(delta: -0.42, unit: "kg", trend: .down)))
        #expect(result.comparesPriorWindow)
        #expect(result.symbol == "arrow.down")
        #expect(result.deltaText.hasSuffix(" kg"))
        #expect(result.deltaText.hasPrefix("−"))
        #expect(MetricRangeDelta.resolve(.priorWindow(delta: 1, unit: "kg", trend: .unknown)) == nil)
        let flat = try #require(MetricRangeDelta.resolve(.priorWindow(delta: 0.03, unit: "kg", trend: .flat)))
        #expect(flat.symbol == "minus")
        #expect(flat.deltaText.hasPrefix("±"))
    }
}

// MARK: - #176 Today text language

@Suite("#176 Today texts in the app language")
struct DigestTextLanguageTests {
    private static func digest(
        lead: String? = #"{"text":"Guten Morgen, dein Puls ist ruhig.","source":"briefing","language":"de"}"#,
        signal: String? = #"{"headline":"Puls ruhiger","delta":"-3 bpm","language":"de"}"#,
        languages: String? = #"{"response":"en","briefing":"de","reaction":null}"#
    ) throws -> DailyDigest {
        var fields =
            [
                #""generatedAt":"2026-11-21T07:00:00Z","phase":"final","sleepPending":false,"line":"Your pulse is calm today.","worthALook":[]"#
            ]
        fields.append(#""briefingLead":"Guten Morgen.""#)
        if let lead { fields.append(#""lead":\#(lead)"#) }
        if let signal { fields.append(#""signalLine":\#(signal)"#) }
        if let languages { fields.append(#""languages":\#(languages)"#) }
        return try decode(DailyDigest.self, "{\(fields.joined(separator: ","))}")
    }

    @Test("a German briefing lead under an English app falls to the line in English")
    func foreignLeadFallsToLine() throws {
        let digest = try Self.digest()
        #expect(digest.languages?.response == "en")
        #expect(digest.lead(for: .en) == "Your pulse is calm today.")
        #expect(digest.lead(for: .de) == "Guten Morgen, dein Puls ist ruhig.")
    }

    @Test("a signal line in another language is left out")
    func foreignSignalHidden() throws {
        let digest = try Self.digest()
        #expect(digest.signalText(for: .en) == nil)
        #expect(digest.signalText(for: .de) == "Puls ruhiger, -3 bpm")
    }

    @Test("when the response language differs too, the app says its own sentence")
    func ownWording() throws {
        let digest = try Self.digest(languages: #"{"response":"de","briefing":"de","reaction":null}"#)
        #expect(digest.lead(for: .nl) == DailyDigest.ownLeadFallback)
    }

    @Test("an older server without languages renders as sent")
    func olderServer() throws {
        let digest = try Self.digest(
            lead: #"{"text":"Guten Morgen.","source":"briefing"}"#,
            signal: #"{"headline":"Puls ruhiger","delta":null}"#,
            languages: nil
        )
        #expect(digest.languages == nil)
        #expect(digest.lead(for: .en) == "Guten Morgen.")
        #expect(digest.signalText(for: .en) == "Puls ruhiger")
    }

    @Test("a null language (text older than the tag) is unknown and renders")
    func nullLanguageRenders() throws {
        let digest = try Self.digest(
            lead: #"{"text":"Old lead.","source":"signal","language":null}"#,
            languages: #"{"response":"en","briefing":null,"reaction":null}"#
        )
        #expect(digest.lead(for: .en) == "Old lead.")
    }

    @Test("a region tag matches its language, never a different one")
    func regionTags() {
        #expect(DailyDigest.reads("de-AT", in: .de))
        #expect(DailyDigest.reads("nl_BE", in: .nl))
        #expect(!DailyDigest.reads("pt-BR", in: .en))
        #expect(DailyDigest.reads(nil, in: .ko))
        #expect(DailyDigest.reads("es-MX", in: .es))
        #expect(!DailyDigest.reads("es", in: .en))
    }

    @Test("languages and the text languages survive the cache round trip")
    func roundTrip() throws {
        let digest = try Self.digest()
        let back = try JSONDecoder.hlDefault.decode(DailyDigest.self, from: JSONEncoder.hlDefault.encode(digest))
        #expect(back == digest)
        #expect(back.resolvedLead?.language == "de")
        #expect(back.signalLine?.language == "de")
    }
}

@Suite("#176 Accept-Language carries the app language", .serialized, .mockURLSession)
struct AcceptLanguageHeaderTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @Test("every request names the interface language", arguments: AppLanguage.allCases)
    func header(language: AppLanguage) async throws {
        let api = makeClient()
        let request = try await AppLanguage.$pinned.withValue(language) {
            try await api.buildURLRequest(APIRequest<EmptyPayload>.get("/api/daily/digest"))
        }
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == language.rawValue)
    }
}

// MARK: - #182 A8 next doses

@Suite("#182 A8 next doses on the medication card")
struct NextDosesTests {
    private static let morning = ISO8601DateFormatter.plain.date(from: "2026-11-21T07:00:00Z")!
    private static let noon = ISO8601DateFormatter.plain.date(from: "2026-11-21T12:00:00Z")!
    private static let evening = ISO8601DateFormatter.plain.date(from: "2026-11-21T19:00:00Z")!

    @Test("scheduledTodayAt decodes from medsToday and round-trips")
    func decodes() throws {
        let json = #"{"briefingState":"ready","medsToday":{"activeCount":2,"scheduledToday":3,"takenToday":1,"skippedToday":0,"#
            + #""scheduledTodayAt":["2026-11-21T07:00:00.000Z","2026-11-21T12:00:00.000Z","2026-11-21T19:00:00Z"],"#
            + #""nextDueAt":null,"nextDueOverdue":false,"nextDueMedicationName":null,"nextDueMedicationId":null,"dueCandidates":[]}}"#
        let snapshot = try decode(DashboardSnapshotBriefing.self, json)
        #expect(snapshot.scheduledTodayAt == [Self.morning, Self.noon, Self.evening])
        let back = try JSONDecoder.hlDefault.decode(DashboardSnapshotBriefing.self, from: JSONEncoder.hlDefault.encode(snapshot))
        #expect(back.scheduledTodayAt == snapshot.scheduledTodayAt)
    }

    @Test("an older snapshot without the field reads nil")
    func olderServer() throws {
        let snapshot = try decode(
            DashboardSnapshotBriefing.self,
            #"{"briefingState":"ready","medsToday":{"scheduledToday":2,"takenToday":0}}"#
        )
        #expect(snapshot.scheduledTodayAt == nil)
        #expect(try decode(DashboardSnapshotBriefing.self, #"{"briefingState":"ready"}"#).scheduledTodayAt == nil)
    }

    @Test("only the slots still ahead, each once, while a dose is open")
    func upcoming() {
        let open = ComplianceSnapshot(scheduledToday: 3, takenToday: 1)
        let slots = [Self.morning, Self.noon, Self.noon, Self.evening]
        let now = Self.morning.addingTimeInterval(3600)
        #expect(ComplianceRingCard.upcomingSlots(slots, snapshot: open, now: now) == [Self.noon, Self.evening])
        #expect(ComplianceRingCard.upcomingSlots(nil, snapshot: open, now: now).isEmpty)
        let done = ComplianceSnapshot(scheduledToday: 3, takenToday: 3)
        #expect(ComplianceRingCard.upcomingSlots(slots, snapshot: done, now: now).isEmpty)
        #expect(ComplianceRingCard.upcomingSlots(slots, snapshot: open, now: Self.evening).isEmpty)
    }

    @Test("one line, singular for one slot")
    @MainActor
    func line() {
        let time: (Date) -> String = { $0 == Self.noon ? "13:00" : "20:00" }
        #expect(ComplianceRingCard.nextDosesLine([], time: time) == nil)
        let one = ComplianceRingCard.nextDosesLine([Self.noon], time: time)
        let two = ComplianceRingCard.nextDosesLine([Self.noon, Self.evening], time: time)
        #expect(one?.contains("13:00") == true)
        #expect(two?.contains("13:00, 20:00") == true)
        #expect(one != two)
    }
}

// MARK: - #182 A2 nutrient targets

@Suite("#182 A2 nutrient targets")
struct NutrientTargetsContractTests {
    @Test("GET targets decodes, an unreadable entry is left out")
    func decodesTargets() throws {
        let value = try decode(
            NutrientTargetsDTO.self,
            #"{"targets":{"protein":{"value":120,"direction":"target"},"sodium":{"value":2000,"direction":"limit"},"fiber":{"value":30,"direction":"sideways"}}}"#
        )
        #expect(value.targets["protein"] == NutrientPersonalTarget(value: 120, direction: .target))
        #expect(value.targets["sodium"]?.direction == .limit)
        #expect(value.targets["fiber"] == nil)
    }

    @Test("PATCH names a set code and sends null to clear one")
    func patchBody() throws {
        let body = try encodeObject(NutrientTargetsPatchDTO(targets: [
            "protein": NutrientPersonalTarget(value: 110, direction: .target),
            "sodium": nil
        ]))
        let targets = try #require(body["targets"] as? [String: Any])
        let protein = try #require(targets["protein"] as? [String: Any])
        #expect(protein["value"] as? Double == 110)
        #expect(protein["direction"] as? String == "target")
        #expect(targets["sodium"] is NSNull)
        #expect(targets.count == 2)
    }

    @Test("daily carries personalTarget; an older server has none")
    func dailyPersonalTarget() throws {
        let base = #""nutrient":"protein","unit":"g","windowDays":30,"days":[{"day":"2026-11-20","amount":95}],"reference":null"#
        let with = try decode(NutrientDailySeriesDTO.self, "{\(base),\"personalTarget\":{\"value\":120,\"direction\":\"target\"}}")
        #expect(with.personalTarget == NutrientPersonalTarget(value: 120, direction: .target))
        let back = try JSONDecoder.hlDefault.decode(NutrientDailySeriesDTO.self, from: JSONEncoder.hlDefault.encode(with))
        #expect(back.personalTarget == with.personalTarget)
        #expect(try decode(NutrientDailySeriesDTO.self, "{\(base)}").personalTarget == nil)
    }

    @Test("the chart prefers the personal target over the reference")
    func chartLine() {
        let reference = NutrientReferenceDTO(kind: .pri, direction: .target, value: 57, source: "EFSA")
        #expect(NutrientTargetPresentation.chartLine(personalTarget: nil, reference: reference)?.lower == 57)
        let limit = NutrientPersonalTarget(value: 2000, direction: .limit)
        let line = NutrientTargetPresentation.chartLine(personalTarget: limit, reference: reference)
        #expect(line?.upper == 2000)
        #expect(line?.lower == nil)
        #expect(NutrientTargetPresentation.chartLine(personalTarget: nil, reference: nil) == nil)
    }

    @Test("the editor takes a positive amount in either decimal form")
    func editorParse() {
        #expect(NutrientTargetEditorSheet.target(direction: .limit, valueText: "2,5")?.value == 2.5
            || NutrientTargetEditorSheet.target(direction: .limit, valueText: "2.5")?.value == 2.5)
        #expect(NutrientTargetEditorSheet.target(direction: .target, valueText: "0") == nil)
        #expect(NutrientTargetEditorSheet.target(direction: .target, valueText: "") == nil)
        #expect(NutrientTargetEditorSheet.target(direction: .target, valueText: "-5") == nil)
    }

    @Test("targets are offered only where the server keeps them")
    func offered() {
        #expect(!NutrientTargetPresentation.offersTargets(supported: false, known: nil))
        #expect(NutrientTargetPresentation.offersTargets(supported: true, known: nil))
        #expect(NutrientTargetPresentation.offersTargets(
            supported: false,
            known: NutrientPersonalTarget(value: 1, direction: .target)
        ))
    }
}

@Suite("#182 A2 nutrient target store", .serialized, .mockURLSession)
@MainActor
struct NutrientTargetStoreTests {
    private func makeStore() throws -> NutrientStore {
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-abc", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.17.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        return try NutrientStore(repository: NutrientReadRepository(api: api, outbox: OutboxQueue(inMemory: true)))
    }

    private nonisolated static func respond(_ request: URLRequest, status: Int, _ body: String) -> (HTTPURLResponse, Data?) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    @Test("a read marks the server as keeping targets; a save takes the merged echo")
    func loadAndSave() async throws {
        let store = try makeStore()
        MockURLProtocol.install { request in
            if request.httpMethod == "PATCH" {
                return Self.respond(
                    request,
                    status: 200,
                    #"{"data":{"targets":{"protein":{"value":110,"direction":"target"}}},"error":null}"#
                )
            }
            return Self.respond(request, status: 200, #"{"data":{"targets":{}},"error":null}"#)
        }
        await store.loadTargets()
        #expect(store.targetsSupported)
        #expect(store.personalTarget(for: .protein) == nil)
        let saved = await store.setTarget(NutrientPersonalTarget(value: 110, direction: .target), for: .protein)
        #expect(saved)
        #expect(store.personalTarget(for: .protein)?.value == 110)
        #expect(store.savingTarget.isEmpty)
    }

    @Test("an older server (404) offers no targets and no error")
    func olderServer() async throws {
        let store = try makeStore()
        MockURLProtocol.install { request in
            Self.respond(request, status: 404, #"{"data":null,"error":"Not found"}"#)
        }
        await store.loadTargets()
        #expect(!store.targetsSupported)
        #expect(store.lastError == nil)
    }

    @Test("a refused value keeps the old target and reports")
    func refusal() async throws {
        let store = try makeStore()
        MockURLProtocol.install { request in
            Self.respond(request, status: 422, #"{"data":null,"error":"Invalid","meta":{"errorCode":"validation.failed"}}"#)
        }
        let saved = await store.setTarget(NutrientPersonalTarget(value: 999_999, direction: .limit), for: .sodium)
        #expect(!saved)
        #expect(store.lastError != nil)
        #expect(store.personalTarget(for: .sodium) == nil)
    }
}

// MARK: - #184 Coach codes and the Local model

@Suite("#184 Coach provider errors")
@MainActor
struct CoachProviderErrorCopyTests {
    @Test("timeout and unreachable get their own line")
    func ownLines() {
        let generic = AskCoachSheet.providerErrorCopy("coach.provider.somethingNew")
        let timeout = AskCoachSheet.providerErrorCopy("coach.provider.timeout")
        let unreachable = AskCoachSheet.providerErrorCopy("coach.provider.unreachable")
        #expect(timeout != generic)
        #expect(unreachable != generic)
        #expect(timeout != unreachable)
        #expect(!timeout.contains("coach.provider"))
        #expect(!unreachable.contains("coach.provider"))
    }
}

@Suite("#184 Local provider keeps its own model")
@MainActor
struct AIProviderLocalModelTests {
    private static func config(_ extra: String) throws -> AIProviderConfig {
        try decode(
            AIProviderConfig.self,
            #"{"hasAnthropicKey":false,"hasOpenaiKey":true,"hasLocalKey":true,"baseUrl":"http://ollama.local:11434"\#(extra)}"#
        )
    }

    @Test("the Local card reads localModel whichever provider is active")
    func localCard() throws {
        let openaiActive = try Self.config(#","provider":"OPENAI","model":"gpt-5","localModel":"llama3.3""#)
        #expect(openaiActive.localModel == "llama3.3")
        #expect(openaiActive.model(for: .local) == "llama3.3")
        #expect(openaiActive.model(for: .openai) == "gpt-5")
    }

    @Test("with Local active, model is Local's and the cloud card starts empty")
    func localActive() throws {
        let localActive = try Self.config(#","provider":"LOCAL","model":"llama3.3","localModel":"llama3.3""#)
        #expect(localActive.model(for: .local) == "llama3.3")
        #expect(localActive.model(for: .openai) == nil)
    }

    @Test("an older server without localModel keeps the shared column")
    func olderServer() throws {
        let old = try Self.config(#","provider":"LOCAL","model":"mistral""#)
        #expect(old.localModel == nil)
        #expect(old.model(for: .local) == "mistral")
        #expect(old.model(for: .openai) == "mistral")
        let oldCloud = try Self.config(#","provider":"OPENAI","model":"gpt-5""#)
        #expect(oldCloud.model(for: .local) == nil)
    }
}

// MARK: - #182 part B screener answers from Apple Health

@Suite("#182 B screener answers not shared")
struct MentalHealthAnswersTests {
    private static func detail(_ extra: String) throws -> MentalHealthAssessmentDetailDTO {
        try decode(
            MentalHealthAssessmentDetailDTO.self,
            #"{"id":"a1","instrument":"PHQ9","totalScore":7,"severityBand":"mild","item9Flagged":false\#(extra)}"#
        )
    }

    @Test("an Apple Health score without answers reads as not shared")
    func notShared() throws {
        let row = try Self.detail(#","items":null,"itemsUnavailable":true,"source":"APPLE_HEALTH""#)
        #expect(row.answers == .notShared)
        #expect(row.missingAnswersNote == String(localized: "mentalHealth.answers.notShared"))
    }

    @Test("the same pair on an in-app row reads as unreadable")
    func unreadable() throws {
        #expect(try Self.detail(#","items":null,"itemsUnavailable":true,"source":"IOS""#).answers == .unreadable)
        #expect(try Self.detail(#","items":null,"itemsUnavailable":true"#).answers == .unreadable)
    }

    @Test("answers that are there are shown, an unknown source decodes")
    func shown() throws {
        let row = try Self.detail(#","items":[1,1,1,1,1,0,0,1,1],"itemsUnavailable":false,"source":"WATCH""#)
        #expect(row.answers == .shown([1, 1, 1, 1, 1, 0, 0, 1, 1]))
        #expect(row.missingAnswersNote == nil)
        #expect(!row.isFromAppleHealth)
    }
}
