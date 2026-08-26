import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.14.8 Phase C4 — the cycle capture sheet's pure write-body builder + the
/// opt-in → gate → importer lifecycle drive. The networking is exercised by
/// `CycleDataLayerTests`; here we lock the form → contract `CycleDayLogWrite`
/// mapping and the gated save no-op.
@MainActor
@Suite("CycleCaptureSheet — write body + gate", .serialized)
struct CycleCaptureSheetTests {
    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    // MARK: - Write-body builder

    @Test("buildWrite maps flow + symptoms + BBT to the contract body")
    func buildsRepresentativeBody() {
        let write = CycleCaptureSheet.buildWrite(
            date: date("2026-06-06"),
            flow: .medium,
            selectedSymptoms: ["cramps", "headache"],
            symptomSeverity: ["cramps": 3],
            hasBBT: true,
            bbt: 36.62,
            ovulationTest: .positiveLHSurge,
            cervicalMucus: .eggWhite,
            sexualActivity: true,
            protectedSex: true,
            note: "  hi  "
        )
        #expect(write.date == "2026-06-06")
        #expect(write.flow == .medium)
        #expect(write.basalBodyTempC == 36.62)
        #expect(write.ovulationTest == .positiveLHSurge)
        #expect(write.cervicalMucus == .eggWhite)
        #expect(write.sexualActivity == true)
        #expect(write.protectedSex == true)
        #expect(write.note == "hi") // trimmed
        #expect(write.source == "MANUAL")
        #expect(write.externalId == "cycle-manual:2026-06-06")
        // Symptoms sorted by key; severity carried only where set.
        #expect(write.symptoms?.count == 2)
        let cramps = write.symptoms?.first { $0.key == "cramps" }
        let headache = write.symptoms?.first { $0.key == "headache" }
        #expect(cramps?.severity == 3)
        #expect(headache?.severity == nil)
    }

    @Test("buildWrite omits optional fields when unset")
    func buildsMinimalBody() {
        let write = CycleCaptureSheet.buildWrite(
            date: date("2026-06-01"),
            flow: .none,
            selectedSymptoms: [],
            symptomSeverity: [:],
            hasBBT: false,
            bbt: 36.5,
            ovulationTest: nil,
            cervicalMucus: nil,
            sexualActivity: false,
            protectedSex: true, // ignored because sexualActivity is false
            note: "   "
        )
        #expect(write.flow == CycleFlowLevel.none)
        #expect(write.basalBodyTempC == nil)
        #expect(write.symptoms == nil)
        #expect(write.note == nil)
        #expect(write.sexualActivity == nil)
        #expect(write.protectedSex == nil) // not sent without sexualActivity
    }

    @Test("buildWrite carries bleeding, home tests, and NONE as a real contraceptive value")
    func buildsBuild5Fields() {
        let write = CycleCaptureSheet.buildWrite(
            date: date("2026-07-20"),
            flow: .spotting,
            selectedSymptoms: ["libido_high", "diarrhea"],
            symptomSeverity: ["diarrhea": 4],
            hasBBT: false,
            bbt: 36.5,
            ovulationTest: nil,
            cervicalMucus: nil,
            intermenstrualBleeding: true,
            pregnancyTest: .negative,
            progesteroneTest: .positive,
            contraceptive: CycleContraceptiveKind.none,
            sexualActivity: false,
            protectedSex: false,
            note: ""
        )
        #expect(write.intermenstrualBleeding == true)
        #expect(write.pregnancyTest == .negative)
        #expect(write.progesteroneTest == .positive)
        #expect(write.contraceptive == CycleContraceptiveKind.none)
        #expect(write.symptoms?.map(\.key) == ["diarrhea", "libido_high"])
    }

    // MARK: - Encoded body matches the contract (encodeIfPresent)

    @Test("Encoded minimal body never emits a null for an unset field")
    func encodedBodySkipsNulls() throws {
        let write = CycleCaptureSheet.buildWrite(
            date: date("2026-06-01"),
            flow: .light,
            selectedSymptoms: [],
            symptomSeverity: [:],
            hasBBT: false,
            bbt: 36.5,
            ovulationTest: nil,
            cervicalMucus: nil,
            sexualActivity: false,
            protectedSex: false,
            note: ""
        )
        let data = try JSONEncoder.hlDefault.encode(write)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(json.contains("\"flow\""))
        #expect(json.contains("\"externalId\""))
        #expect(!json.contains("\"basalBodyTempC\""))
        #expect(!json.contains("\"note\""))
        #expect(!json.contains("\"symptoms\""))
        #expect(!json.contains("\"protectedSex\""))
    }

    // MARK: - Gated save (no network while the gate is closed)

    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeSettings() -> SettingsStore {
        let repo = SettingsRepository(api: makeClient())
        let defaults = UserDefaults(suiteName: "CycleCaptureSheetTests.\(UUID().uuidString)")!
        return SettingsStore(repo: repo, defaults: defaults)
    }

    @Test("saveDayLog is a no-op while the gate is closed (flag OFF default)")
    func saveNoOpWhenGateClosed() async throws {
        let repo = try CycleRepository(api: makeClient(), outbox: OutboxQueue(inMemory: true))
        // No FeatureFlagsStore → cycleTracking defaults OFF → gate closed.
        let gate = CycleGate(settings: makeSettings())
        let store = CycleStore(repository: repo, gate: gate)
        #expect(gate.isCycleTrackingAvailable == false)
        let write = CycleCaptureSheet.buildWrite(
            date: date("2026-06-06"), flow: .light, selectedSymptoms: [], symptomSeverity: [:],
            hasBBT: false, bbt: 36.5, ovulationTest: nil, cervicalMucus: nil,
            sexualActivity: false, protectedSex: false, note: ""
        )
        let ok = await store.saveDayLog(write)
        #expect(ok == false)
        #expect(store.lastError == nil) // never hit the network
    }

    // MARK: - Period is a Save-committed pending choice (not instant)

    /// Build an OPEN-gate store (flag ON + female profile) plus a recording
    /// MockURLProtocol handler so we can assert which endpoints a Save touches.
    private final class HitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var paths: [String] = []
        func record(_ path: String) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    private func makeFlagsEnabled() async -> FeatureFlagsStore {
        let repo = FeatureFlagsRepository(api: makeClient())
        let store = FeatureFlagsStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"flags":{"cycle.tracking":true}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.refresh()
        return store
    }

    private func makeFemaleSettings() async -> SettingsStore {
        let settings = makeSettings()
        let profileJSON = """
        {"data":{"username":"u","displayName":"U","email":"u@example.com",\
        "avatarUrl":null,"dateOfBirth":null,"gender":"female","heightCm":170,\
        "locale":"de","timezone":"Europe/Berlin","moodReminderEnabled":false},"error":null}
        """
        let meJSON = #"{"data":{"id":"u1","username":"u","email":"u@example.com","avatarUrl":null},"error":null}"#
        let hkJSON = #"{"data":{"entries":[],"lastSyncedAt":null},"error":null}"#
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let body: String
            switch path {
            case "/api/user/profile": body = profileJSON
            case "/api/auth/me": body = meJSON
            case "/api/integrations/healthkit": body = hkJSON
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        await settings.load()
        return settings
    }

    /// Open-gate store + a recorder. The handler returns benign 2xx for every
    /// write/read endpoint and records the path so a test can assert hits.
    private func makeOpenStore() async throws -> (CycleStore, HitRecorder) {
        let flags = await makeFlagsEnabled()
        let settings = await makeFemaleSettings()
        let gate = CycleGate(settings: settings, featureFlags: flags)
        gate.refresh()
        #expect(gate.isCycleTrackingAvailable == true)
        let repo = try CycleRepository(api: makeClient(), outbox: OutboxQueue(inMemory: true))
        let store = CycleStore(repository: repo, gate: gate)
        let rec = HitRecorder()
        let calendarJSON = #"""
        {"data":{"profile":{"goal":"GENERAL_HEALTH","rawChartMode":false,"predictionEnabled":true,"cyclesObserved":0},
         "prediction":null,"days":[],"from":"2026-01-01","to":"2026-12-31"},"error":null}
        """#
        let cyclesJSON = #"{"data":{"cycles":[],"stats":null},"error":null}"#
        let profileJSON = #"{"data":{"goal":"GENERAL_HEALTH","rawChartMode":false,"predictionEnabled":true,"cyclesObserved":0},"error":null}"#
        // The prefs PATCH echoes back the merged profile with the chosen secondary
        // symptom (v1.16.15) so the store fold can be asserted.
        let prefsJSON = #"""
        {"data":{"goal":"GENERAL_HEALTH","cycleTrackingEnabled":true,"rawChartMode":false,
         "predictionEnabled":true,"discreetNotifications":false,"sensitiveCategoryEncryption":false,
         "secondarySymptom":"CERVIX","updatedAt":"2026-06-10T00:00:00.000Z"},"error":null}
        """#
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            rec.record(path)
            let body: String
            switch path {
            case "/api/auth/me/cycle-prefs": body = prefsJSON
            case "/api/cycle/period": body = #"{"data":null,"error":null}"#
            case "/api/cycle/day-logs":
                body = #"""
                {"data":{"id":"d1","date":"2026-06-06","cycleId":null,"flow":"LIGHT",
                 "intermenstrualBleeding":null,"basalBodyTempC":null,"ovulationTest":null,
                 "cervicalMucus":null,"sexualActivity":null,"protectedSex":null,
                 "pregnancyTest":null,"progesteroneTest":null,"contraceptive":null,
                 "symptoms":[],"note":null,"source":"MANUAL","externalId":"cycle-manual:2026-06-06",
                 "syncVersion":1,"updatedAt":"2026-06-06T08:00:00.000Z","deletedAt":null},"error":null}
                """#
            case "/api/cycle/calendar": body = calendarJSON
            case "/api/cycle/cycles": body = cyclesJSON
            case "/api/cycle/profile": body = profileJSON
            default:
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":null}"#.utf8)
                )
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        return (store, rec)
    }

    @Test("buildPeriodRequest: nil action → no request; a pick → stable externalId")
    func buildsPeriodRequest() {
        #expect(CycleCaptureSheet.buildPeriodRequest(action: nil, date: date("2026-06-06")) == nil)
        let start = CycleCaptureSheet.buildPeriodRequest(action: .start, date: date("2026-06-06"))
        #expect(start?.action == .start)
        #expect(start?.date == "2026-06-06")
        #expect(start?.externalId == "cycle-period:start:2026-06-06")
    }

    @Test("Picking period-start sets pending state without any network call")
    func periodPickIsPendingNoNetwork() async throws {
        let (_, rec) = try await makeOpenStore()
        // Selecting the pending action is pure view state — the only artifact is
        // a (non-network) CyclePeriodRequest built from it. No store call fires.
        let pending = CycleCaptureSheet.buildPeriodRequest(action: .start, date: date("2026-06-06"))
        #expect(pending != nil)
        // The cycle write endpoints were never touched by merely choosing.
        #expect(!rec.snapshot.contains("/api/cycle/period"))
        #expect(!rec.snapshot.contains("/api/cycle/day-logs"))
    }

    @Test("Save commits the period action AND the day-log together, then refreshes")
    func saveCommitsPeriodAndDayLogTogether() async throws {
        let (store, rec) = try await makeOpenStore()
        let write = CycleCaptureSheet.buildWrite(
            date: date("2026-06-06"), flow: .light, selectedSymptoms: [], symptomSeverity: [:],
            hasBBT: false, bbt: 36.5, ovulationTest: nil, cervicalMucus: nil,
            sexualActivity: false, protectedSex: false, note: ""
        )
        let period = CycleCaptureSheet.buildPeriodRequest(action: .start, date: date("2026-06-06"))
        let ok = await store.commitCapture(dayLog: write, period: period)
        #expect(ok == true)
        let hits = rec.snapshot
        // Both writes fired in the single Save…
        #expect(hits.contains("/api/cycle/period"))
        #expect(hits.contains("/api/cycle/day-logs"))
        // …and the calendar refresh was triggered afterward so the Cycle screen
        // reflects the change (operator: "Periode Ende ändert nichts").
        #expect(hits.contains("/api/cycle/calendar"))
    }

    @Test("Save with no period pick writes only the day-log (still refreshes)")
    func saveWithoutPeriodWritesDayLogOnly() async throws {
        let (store, rec) = try await makeOpenStore()
        let write = CycleCaptureSheet.buildWrite(
            date: date("2026-06-06"), flow: .light, selectedSymptoms: [], symptomSeverity: [:],
            hasBBT: false, bbt: 36.5, ovulationTest: nil, cervicalMucus: nil,
            sexualActivity: false, protectedSex: false, note: ""
        )
        let ok = await store.commitCapture(dayLog: write, period: nil)
        #expect(ok == true)
        let hits = rec.snapshot
        #expect(!hits.contains("/api/cycle/period"))
        #expect(hits.contains("/api/cycle/day-logs"))
        #expect(hits.contains("/api/cycle/calendar"))
    }

    // MARK: - v1.16.15 — capture round-trip + secondary-symptom pref

    @Test("v1.16.15 — buildWrite carries cervix + disturbed-temp into the body")
    func buildWriteCarriesV11615Fields() {
        let write = CycleCaptureSheet.buildWrite(
            date: date("2026-06-10"),
            flow: .none,
            selectedSymptoms: [],
            symptomSeverity: [:],
            hasBBT: true,
            bbt: 36.72,
            temperatureExcluded: true,
            ovulationTest: nil,
            cervicalMucus: nil,
            cervixPosition: .high,
            cervixFirmness: .soft,
            cervixOpening: .open,
            sexualActivity: false,
            protectedSex: false,
            note: ""
        )
        #expect(write.basalBodyTempC == 36.72)
        #expect(write.temperatureExcluded == true)
        #expect(write.cervixPosition == .high)
        #expect(write.cervixFirmness == .soft)
        #expect(write.cervixOpening == .open)
    }

    @Test("v1.16.15 — temperatureExcluded is dropped when there is no BBT reading")
    func temperatureExcludedNeedsBBT() {
        let write = CycleCaptureSheet.buildWrite(
            date: date("2026-06-10"),
            flow: .light,
            selectedSymptoms: [],
            symptomSeverity: [:],
            hasBBT: false, // no reading…
            bbt: 36.5,
            temperatureExcluded: true, // …so this must not be sent
            ovulationTest: nil,
            cervicalMucus: nil,
            sexualActivity: false,
            protectedSex: false,
            note: ""
        )
        #expect(write.basalBodyTempC == nil)
        #expect(write.temperatureExcluded == nil)
    }

    @Test("v1.16.15 — updateSecondarySymptom PATCHes prefs and persists the merged profile")
    func updateSecondarySymptomPersists() async throws {
        let (store, rec) = try await makeOpenStore()
        let ok = await store.updateSecondarySymptom(.cervix)
        #expect(ok == true)
        #expect(rec.snapshot.contains("/api/auth/me/cycle-prefs"))
        // The merged server profile is folded into the store.
        #expect(store.profile?.secondarySymptomValue == .cervix)
        #expect(store.lastError == nil)
    }

    @Test("v1.16.15 — updateSecondarySymptom is a no-op while the gate is closed")
    func updateSecondarySymptomGated() async throws {
        let repo = try CycleRepository(api: makeClient(), outbox: OutboxQueue(inMemory: true))
        let gate = CycleGate(settings: makeSettings())
        let store = CycleStore(repository: repo, gate: gate)
        #expect(gate.isCycleTrackingAvailable == false)
        let ok = await store.updateSecondarySymptom(.cervix)
        #expect(ok == false)
        #expect(store.lastError == nil) // never hit the network
    }
}
