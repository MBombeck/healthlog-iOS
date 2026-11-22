import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// The seizure diary (server v1.48.0, #182 A4): the wire contract of
/// `GET /api/seizures`, the module gate (offered only when the server says
/// on), the quick-log timer, and the writes against a stubbed transport.
@Suite("Seizure diary", .serialized, .mockURLSession)
@MainActor
struct SeizureDiaryTests {
    nonisolated static let diaryJSON = #"""
    {"data":{
      "types":[
        {"id":"t1","label":"Der Große","ilaeType":"GENERALIZED_TC","usualDurationSec":90,
         "rescuePlan":"Buccolam 7,5 mg in die Wangentasche, Notruf nach 5 Minuten.","rescueMedicationId":"m1",
         "rescueMedicationName":"Buccolam","rescueDoseAmount":7.5,"rescueDoseUnit":"mg","rescueRoute":"BUCCAL",
         "sortOrder":0,"archived":false,"alert":{"seconds":210,"source":"usualPlusTwo"}},
        {"id":"t2","label":"Absence","ilaeType":"ABSENCE_TYPICAL","usualDurationSec":null,"rescuePlan":null,
         "rescueMedicationId":null,"rescueMedicationName":null,"rescueDoseAmount":null,"rescueDoseUnit":null,
         "rescueRoute":null,"sortOrder":1,"archived":false,"alert":{"seconds":600,"source":"t1"}},
        {"id":"t3","label":null,"ilaeType":"SOMETHING_NEW","sortOrder":2,"archived":true,"alert":{"seconds":300,"source":"generic"}}
      ],
      "settings":{"rule":{"count":2,"windowHours":24},"niceRule":{"count":3,"windowHours":24}},
      "events":[
        {"id":"e1","typeProfileId":"t2","ilaeType":null,"effectiveIlaeType":"ABSENCE_TYPICAL","onsetAt":"2026-11-10T07:00:00.000Z",
         "onsetPrecision":"APPROX","durationSec":null,"durationSource":"UNKNOWN","count":6,"certainty":"CONFIRMED",
         "sleepState":"AWAKE","observableManifestations":null,"responsiveness":null,"recall":null,
         "semiology":["STARING","NEW_SIGN"],"semiologyNote":null,"aura":null,"triggers":["SLEEP_DEPRIVATION"],
         "postictalMinutes":null,"postictal":[],"injuries":[],"incontinence":null,"emergency":"NONE",
         "witnessed":true,"witnessRole":"PARENT","witnessNote":null,"loggedBy":"delegate","loggedByViewer":false,
         "loggedByName":"Robin","source":"MANUAL","note":null,"rescueDoses":[],"flags":{"overT1":null,"prolonged":null},
         "createdAt":"2026-11-10T07:10:00.000Z","updatedAt":"2026-11-10T07:10:00.000Z"},
        {"id":"e2","typeProfileId":"t1","ilaeType":null,"effectiveIlaeType":"GENERALIZED_TC","onsetAt":"2026-11-18T21:04:00.000Z",
         "onsetPrecision":"EXACT","durationSec":250,"durationSource":"TIMED","count":1,"certainty":"CONFIRMED",
         "sleepState":"ASLEEP","semiology":["TONIC","CLONIC"],"triggers":[],"postictal":["SLEEP"],"injuries":["TONGUE_BITE"],
         "emergency":"EMS_CALLED","witnessed":true,"witnessRole":"PARENT","loggedBy":"owner","loggedByViewer":true,
         "loggedByName":null,"source":"MANUAL","note":"Nachts","flags":{"overT1":false,"prolonged":true},
         "rescueDoses":[{"id":"d1","eventId":"e2","medicationId":"m1","medicationName":"Buccolam","doseAmount":7.5,
           "doseUnit":"mg","route":"BUCCAL","givenAt":"2026-11-18T21:08:00.000Z","givenBy":"PARENT","effect":"STOPPED",
           "seizureEndedAt":null,"intakeEventId":"i1"}],
         "createdAt":"2026-11-18T21:09:00.000Z","updatedAt":"2026-11-18T21:09:00.000Z"},
        {"typeProfileId":"t1","onsetAt":"broken, no id"}
      ],
      "summary":{"from":"2026-08-23T00:00:00.000Z","to":"2026-11-21T00:00:00.000Z","days":90,"seizures":7,"suspected":1,
        "seizureDays":2,"seizureFreeDays":88,"per28Days":2.2,"convulsive":1,"fromSleep":1,"rescueDoses":1,
        "emergencies":{"emsCalled":1,"edVisits":0,"admissions":0},
        "streak":{"daysSinceLast":2,"lastAt":"2026-11-18T21:04:00.000Z","longestFreeDays":61},
        "clusters":[{"startAt":"2026-11-10T07:00:00.000Z","endAt":"2026-11-10T07:00:00.000Z","seizureCount":6,"eventIds":["e1"]}],
        "niceClusterCount":1,"monthly":{"months":[],"rows":[],"total":{"typeProfileId":null,"counts":{},"days":{},"total":7}}},
      "truncated":false
    },"error":null}
    """#

    private struct Envelope: Decodable {
        let data: SeizureDiaryDTO
    }

    nonisolated static func diary() throws -> SeizureDiaryDTO {
        try JSONDecoder.hlDefault.decode(Envelope.self, from: Data(diaryJSON.utf8)).data
    }

    // MARK: - Wire

    @Test("The diary decodes; a broken event costs that event, an unknown word reads unrecognized")
    func decodesDiary() throws {
        let diary = try Self.diary()
        #expect(diary.types.count == 3)
        #expect(diary.types[2].ilaeType == .unrecognized)
        #expect(diary.events.map(\.id) == ["e2", "e1"], "newest first, the broken row left out")
        let absence = try #require(diary.events.last)
        #expect(absence.semiology == [.staring], "an unknown semiology word is left out")
        #expect(absence.count == 6)
        #expect(absence.loggedBy == .delegate)
        let tonic = try #require(diary.events.first)
        #expect(tonic.rescueDoses.first?.effect == .stopped)
        #expect(tonic.flags.prolonged == true)
        #expect(diary.summary?.clusteredEventIDs == ["e1"])
        #expect(diary.summary?.streak.longestFreeDays == 61)
        #expect(diary.activeTypes.map(\.id) == ["t1", "t2"], "the archived type stays out of the quick log")
        #expect(diary.types[0].alert == SeizureAlertThreshold(seconds: 210, source: .usualPlusTwo))
    }

    @Test("The ILAE table groups the 21 types into their classes, the parent entry first")
    func ilaeTable() {
        #expect(SeizureIlaeType.allCases.count - 1 == 22)
        #expect(SeizureIlaeType.types(in: .focal).first == .focalUndetermined)
        #expect(SeizureIlaeType.types(in: .generalized).contains(.absenceTypical))
        #expect(SeizureIlaeType.types(in: .unclassified) == [.unclassified])
        #expect(SeizureIlaeType.generalizedTc.isConvulsive)
        #expect(!SeizureIlaeType.absenceTypical.isConvulsive)
        #expect(SeizureIlaeClass.choices.count == 4)
    }

    // MARK: - Module gate

    @Test("Offered only when the server's map says seizures is on")
    func moduleGate() {
        #expect(SeizuresModule.isAvailable(modules: ["seizures": true]))
        #expect(!SeizuresModule.isAvailable(modules: ["seizures": false]), "module off")
        #expect(!SeizuresModule.isAvailable(modules: ["illness": true]), "a map without the key: an older server")
        #expect(!SeizuresModule.isAvailable(modules: nil), "no map at all")
        let off = SidebarDestination.enabled(isModuleEnabled: { _ in true }, isCycleTrackingAvailable: true, isSeizuresAvailable: false)
        #expect(!off.contains(.seizures))
        let on = SidebarDestination.enabled(isModuleEnabled: { _ in true }, isCycleTrackingAvailable: true, isSeizuresAvailable: true)
        #expect(on.contains(.seizures))
        #expect(SidebarDestination.seizures.section == .diary)
    }

    @Test("The sidebar lists the diary after the illness journal; More pushes its route")
    func sidebarPlacement() throws {
        let diary = SidebarSection.diary.destinations
        let illness = try #require(diary.firstIndex(of: .illness))
        #expect(diary.firstIndex(of: .seizures) == illness + 1)
        let item = AuthenticatedShell.sidebarItem(for: .seizures)
        #expect(item.titleKey == "seizures.title")
        #expect(item.systemImage == SeizureSymbols.module)
        #expect(MoreScreen.Layout.clinicalRows.contains { $0.id == "seizures" })
    }

    @Test("A SEIZURE_CLUSTER tap (/seizures) and the scheme link open the diary")
    func deepLinks() throws {
        #expect(DeepLinkRoute.fromPushPath("/seizures") == .seizures)
        #expect(try DeepLinkRoute(url: #require(URL(string: "healthlog://seizures"))) == .seizures)
        #expect(DeepLinkRoute.fromPushPath("/seizures/e1") == .dashboard, "no native page per seizure path")
        // Server 1.49.0: a non-guardian delivery names the seizure.
        #expect(DeepLinkRoute.fromPushPath("/seizures?event=cmabc123") == .seizureEvent(id: "cmabc123"))
        #expect(DeepLinkRoute.fromPushPath("/seizures?event=../x") == .seizures, "a tampered id opens the diary")
        #expect(DeepLinkRoute.fromPushPath("/seizures?other=1") == .seizures)
        // A guardian delivery carries `/` and opens home.
        #expect(DeepLinkRoute.fromPushPath("/") == .dashboard)
    }

    @Test("A seizure push opens the diary with that seizure on the diary's stack")
    func pushOpensSeizure() {
        let router = AppRouter()
        router.applyMoreStackRoute(.seizureEvent(id: "e1"))
        #expect(router.selectedTab == .more)
        #expect(router.morePath.count == 2, "the diary's row, then the seizure")
        let wide = AppRouter()
        wide.applyShellLayout(ShellLayout(sizeClass: .regular, enabledSections: Set(SidebarDestination.allCases)))
        wide.applyMoreStackRoute(.seizureEvent(id: "e1"))
        #expect(wide.selectedTab == .section(.seizures))
        #expect(wide.sectionPath(.seizures).count == 1)
    }

    // MARK: - Writes

    private static func json(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(value)) as? [String: Any])
    }

    @Test("A stopped timer sends the exact start, a timed duration, witnessed and the stamped doses")
    func timerWrite() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = try #require(try Self.diary().types.first)
        var timer = SeizureTimerState(startedAt: start, typeProfileId: "t1")
        timer.rescue.append(.fromPlan(plan, givenAt: start.addingTimeInterval(120)))
        let body = try Self.json(timer.write(stoppedAt: start.addingTimeInterval(250.4)))
        #expect(body["onsetPrecision"] as? String == "EXACT")
        #expect(body["durationSec"] as? Int == 250)
        #expect(body["durationSource"] as? String == "TIMED")
        #expect(body["witnessed"] as? Bool == true)
        #expect(body["typeProfileId"] as? String == "t1")
        let doses = try #require(body["rescueDoses"] as? [[String: Any]])
        #expect(doses.first?["medicationId"] as? String == "m1")
        #expect(doses.first?["route"] as? String == "BUCCAL")
        #expect(body["note"] == nil, "an empty note is left out on a create")
        #expect(timer.write(stoppedAt: start).durationSec == 1, "a stop at once still counts one second")
    }

    @Test("Create leaves out what is empty; update sends a cleared field as null")
    func createAndUpdateBodies() throws {
        let create = try Self.json(SeizureEventWrite(mode: .create, onsetAt: "2026-11-20T10:00:00.000Z"))
        #expect(create["durationSec"] == nil)
        #expect(create["typeProfileId"] == nil)
        #expect(create["durationSource"] as? String == "UNKNOWN", "no duration is an unknown one")
        let update = try Self.json(SeizureEventWrite(mode: .update, onsetAt: "2026-11-20T10:00:00.000Z", note: " "))
        #expect(update["durationSec"] is NSNull)
        #expect(update["typeProfileId"] is NSNull)
        #expect(update["witnessed"] is NSNull)
        #expect((update["note"] as? String)?.isEmpty == true, "an empty note clears it")
        #expect(update["rescueDoses"] == nil, "doses are only written with a new seizure")
        let estimated = SeizureEventWrite(mode: .create, onsetAt: "x", durationSec: 30, durationSource: .unknown)
        #expect(estimated.resolvedDurationSource == .estimated, "a typed duration is never UNKNOWN")
    }

    @Test("A type write never touches the plan; the rule is clamped to the server's bounds")
    func typeAndRuleBodies() throws {
        let type = try Self.json(SeizureTypeWrite(label: " Der Kleine ", ilaeType: .focalImpaired, usualDurationSec: .clear))
        #expect(type["label"] as? String == "Der Kleine")
        #expect(type["usualDurationSec"] is NSNull)
        #expect(type["rescuePlan"] == nil)
        #expect(type["rescueMedicationId"] == nil)
        let rule = SeizureSettingsPatch(rule: SeizureClusterRule(count: 40, windowHours: 0))
        #expect(rule.clusterCount == 20)
        #expect(rule.clusterWindowHours == 1)
    }

    @Test("The form's duration fields read minutes and seconds")
    func durationFields() {
        #expect(SeizurePresentation.seconds(minutes: "4", seconds: "7") == 247)
        #expect(SeizurePresentation.seconds(minutes: "", seconds: "") == nil)
        #expect(SeizurePresentation.seconds(minutes: "x", seconds: "") == nil)
        #expect(SeizurePresentation.seconds(minutes: "1441", seconds: "0") == nil, "longer than a day")
        #expect(SeizurePresentation.split(247) == ("4", "7"))
        #expect(SeizureDateFormat.clock(247) == "4:07")
        #expect(SeizureDateFormat.clock(3727) == "1:02:07")
    }

    @Test("The plan panel stands only while a timer runs past the threshold")
    func thresholdPanel() {
        let alert = SeizureAlertThreshold(seconds: 210, source: .usualPlusTwo)
        #expect(!SeizurePresentation.isOverThreshold(elapsed: 209, alert: alert, isRunning: true))
        #expect(SeizurePresentation.isOverThreshold(elapsed: 210, alert: alert, isRunning: true))
        #expect(!SeizurePresentation.isOverThreshold(elapsed: 999, alert: alert, isRunning: false))
        #expect(SeizurePresentation.isOverThreshold(elapsed: 300, alert: nil, isRunning: true), "five minutes without a type")
        #expect(SeizurePresentation.thresholdLine(alert).contains("3:30"))
    }

    @Test("A row names the type, else the ILAE name, else no type; one quiet status")
    func rowWording() throws {
        let diary = try Self.diary()
        let absence = try #require(diary.events.last)
        #expect(SeizurePresentation.typeName(of: absence, in: diary) == "Absence")
        let untyped = SeizureEventDTO(id: "x", onsetAt: "2026-11-20T10:00:00.000Z")
        #expect(SeizurePresentation.typeName(of: untyped, in: diary) == String(localized: "seizures.untyped"))
        #expect(SeizurePresentation.status(absence, clustered: true) == String(localized: "seizures.list.cluster"))
        let suspected = SeizureEventDTO(id: "y", onsetAt: "2026-11-20T10:00:00.000Z", certainty: .suspected)
        #expect(SeizurePresentation.status(suspected, clustered: true) == SeizureCertainty.suspected.label)
        #expect(SeizurePresentation.loggedBy(absence)?.contains("Robin") == true)
    }

    @Test("The emergency number follows the region, not the language; an unknown region gets none")
    func emergencyNumber() {
        #expect(SeizurePresentation.emergencyNumber(locale: Locale(identifier: "de_DE")) == "112")
        #expect(SeizurePresentation.emergencyNumber(locale: Locale(identifier: "es_MX")) == "911", "not Spain's 112")
        #expect(SeizurePresentation.emergencyNumber(locale: Locale(identifier: "es_AR")) == "107")
        #expect(SeizurePresentation.emergencyNumber(locale: Locale(identifier: "es_ES")) == "112")
        #expect(SeizurePresentation.emergencyNumber(locale: Locale(identifier: "es_DE")) == "112", "a Spanish phone in Germany")
        #expect(SeizurePresentation.emergencyNumber(locale: Locale(identifier: "en_GB")) == "999")
        #expect(SeizurePresentation.emergencyNumber(locale: Locale(identifier: "ko_KR")) == "119")
        #expect(SeizurePresentation.emergencyNumber(locale: Locale(identifier: "es_419")) == nil, "a continent is no region")
        #expect(SeizurePresentation.emergencyNumber(locale: Locale(identifier: "es")) == nil, "no region: no number")
        #expect(SeizurePresentation.emergencyNumber(locale: Locale(identifier: "en_TV")) == nil, "unknown: no guess")
        #expect(SeizurePresentation.callURL("1 1 2")?.absoluteString == "tel:112")
        #expect(SeizurePresentation.callURL("") == nil)
    }

    // MARK: - Store against a stub

    private nonisolated static func reply(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    func makeStore(timerFile: URL? = nil) -> SeizuresStore {
        let file = timerFile ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("seizure-timer-\(UUID().uuidString).json")
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return SeizuresStore(repository: SeizuresRepository(api: api), timerStore: SeizureTimerStore(url: file))
    }

    @Test("A failed stop keeps the timer and its key; the retry sends the same key once")
    func stopRetriesUnderOneKey() async throws {
        let keys = SeizureKeySpy()
        let fail = SeizureFlag(true)
        MockURLProtocol.install { request in
            if request.url?.path == "/api/seizures/events" {
                keys.record(request.value(forHTTPHeaderField: "Idempotency-Key"))
                if fail.value {
                    return Self.reply(request, #"{"data":null,"error":"boom"}"#, status: 500)
                }
                let event = #"{"data":{"id":"new","onsetAt":"2026-11-20T10:00:00.000Z","durationSec":42,"durationSource":"TIMED"},"error":null}"#
                return Self.reply(request, event, status: 201)
            }
            return Self.reply(request, Self.diaryJSON)
        }
        let store = makeStore()
        await store.load()
        store.startTimer(at: Date().addingTimeInterval(-42))
        let key = try #require(store.timer?.idempotencyKey)
        #expect(await store.stopTimer() == nil)
        #expect(store.timer?.idempotencyKey == key, "the timer survives a failed stop")
        fail.value = false
        let recorded = await store.stopTimer()
        #expect(recorded?.id == "new")
        #expect(store.timer == nil)
        #expect(store.lastRecorded?.id == "new")
        #expect(Set(keys.values) == [key.raw], "every attempt under the timer's key")
    }

    @Test("seizures.disabled turns the page into the switched-off note, not an error")
    func disabledModule() async {
        MockURLProtocol.install { request in
            Self.reply(
                request,
                #"{"data":null,"error":"Seizure diary is off","meta":{"errorCode":"seizures.disabled","module":"seizures"}}"#,
                status: 403
            )
        }
        let store = makeStore()
        await store.load()
        #expect(store.isDisabled)
        #expect(store.lastError == nil)
        #expect(store.diary == nil)
    }

    @Test("The quick log picks the type of the newest seizure and stamps the plan's drug")
    func quickLogPicksAndStamps() throws {
        let store = makeStore()
        try store.seedForTesting(Self.diary())
        #expect(store.pickedTypeId == "t1", "the newest seizure was of type t1")
        store.startTimer()
        store.stampRescue()
        #expect(store.timer?.rescue.first?.medicationName == "Buccolam")
        store.pick(typeId: "t2")
        store.stampRescue()
        #expect(store.timer?.rescue.count == 1, "a type without a plan drug stamps nothing")
        store.clearOnLogout()
        #expect(store.timer == nil)
        #expect(store.diary == nil)
    }
}

/// The quick-log timer through a failed stop and a restart.
extension SeizureDiaryTests {
    nonisolated static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    @Test("The first stop freezes the end: the retry sends the same duration, the clock and the plan stop")
    func stopFreezesTheEnd() async throws {
        let bodies = SeizureBodySpy()
        let fail = SeizureFlag(true)
        MockURLProtocol.install { request in
            if request.url?.path == "/api/seizures/events" {
                bodies.record(Self.body(request), key: request.value(forHTTPHeaderField: "Idempotency-Key"))
                if fail.value {
                    return Self.reply(request, #"{"data":null,"error":"boom"}"#, status: 500)
                }
                let event = #"{"data":{"id":"new","onsetAt":"2026-11-20T10:00:00.000Z","durationSec":42,"durationSource":"TIMED"},"error":null}"#
                return Self.reply(request, event, status: 201)
            }
            return Self.reply(request, Self.diaryJSON)
        }
        let store = makeStore()
        await store.load()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        store.startTimer(at: start)
        #expect(await store.stopTimer(at: start.addingTimeInterval(42)) == nil)
        let stopped = try #require(store.timer)
        #expect(!stopped.isRunning)
        #expect(stopped.elapsed(at: start.addingTimeInterval(900)) == 42, "the clock stays at the stop")
        #expect(!SeizurePresentation.isOverThreshold(elapsed: 900, alert: nil, isRunning: stopped.isRunning))
        store.pick(typeId: "t2")
        store.stampRescue(at: start.addingTimeInterval(300))
        #expect(store.timer == stopped, "a stopped timer keeps the body its stop froze")

        fail.value = false
        #expect(await store.stopTimer(at: start.addingTimeInterval(900))?.id == "new")
        let sent = bodies.values
        // The failed stop (with the client's own retries) and the one that landed.
        #expect(sent.count >= 2)
        #expect(Set(sent.map(\.key)).count == 1, "one key")
        let parsed = sent.compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? NSDictionary }
        #expect(parsed.count == sent.count)
        #expect(Set(parsed).count == 1, "every attempt is the first attempt")
        #expect(parsed.last?["durationSec"] as? Int == 42)
    }

    @Test("A running timer outlives the store: it is on disk with every change and gone after discard or sign-out")
    func timerSurvivesARestart() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("seizure-timer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = makeStore(timerFile: file)
        try first.seedForTesting(Self.diary())
        first.startTimer(at: Date(timeIntervalSince1970: 1_790_000_000))
        first.stampRescue(at: Date(timeIntervalSince1970: 1_790_000_060))
        let running = try #require(first.timer)
        #expect(running.rescue.count == 1)

        let relaunched = makeStore(timerFile: file)
        #expect(relaunched.timer == running, "start, type, doses and key come back")
        relaunched.discardTimer()
        #expect(makeStore(timerFile: file).timer == nil)

        let again = makeStore(timerFile: file)
        again.startTimer()
        #expect(makeStore(timerFile: file).timer != nil)
        again.clearOnLogout()
        #expect(!FileManager.default.fileExists(atPath: file.path), "sign-out leaves no timer behind")
    }
}

private final class SeizureKeySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []

    func record(_ key: String?) {
        lock.withLock { keys.append(key ?? "") }
    }

    var values: [String] {
        lock.withLock { keys }
    }
}

private final class SeizureBodySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(body: Data, key: String)] = []

    func record(_ body: Data, key: String?) {
        lock.withLock { sent.append((body, key ?? "")) }
    }

    var values: [(body: Data, key: String)] {
        lock.withLock { sent }
    }
}

private final class SeizureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool

    init(_ value: Bool) {
        flag = value
    }

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

// swiftlint:enable force_unwrapping
