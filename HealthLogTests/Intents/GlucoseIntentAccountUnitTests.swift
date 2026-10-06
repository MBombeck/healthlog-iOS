import AppIntents
import Foundation
@testable import HealthLog
import Testing

/// **#115 B5 — Siri and Shortcuts take glucose in the account's unit.**
///
/// `LogBloodGlucoseIntent` and the glucose arm of `LogMeasurementIntent` wrote
/// the spoken number verbatim as mg/dL. An mmol/L account saying "5.3" got a
/// refusal (below 10 mg/dL) — and from "10" up a reading eighteen times too
/// low. The intents now read the account unit, write canonical mg/dL (the same
/// arithmetic as the entry sheet) and speak back the unit the value was said in.
///
/// Each perform runs the real `MeasurementsRepository.create` against a stub
/// client that records the request bodies.
@Suite("#115 B5 — glucose intents in the account unit")
@MainActor
struct GlucoseIntentAccountUnitTests {
    private func install(unit: GlucoseUnit) throws -> BodyRecordingAPIClient {
        let keychain = InMemoryKeychain()
        try keychain.setString("test-bearer", forKey: KeychainKey.authToken)
        let api = BodyRecordingAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        IntentDependencies.testOverride = IntentDependencies.Resolved(
            keychain: keychain,
            api: api,
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            glucoseUnit: { unit }
        )
        return api
    }

    // MARK: - LogBloodGlucoseIntent

    @Test("an mmol/L account's spoken 5.3 is written as canonical mg/dL")
    func mmolAccountWritesCanonical() async throws {
        let api = try install(unit: .mmolL)
        defer { IntentDependencies.testOverride = nil }

        let intent = LogBloodGlucoseIntent()
        intent.value = 5.3
        intent.context = .fasting
        _ = try await intent.perform()

        let written = try #require(await api.postedValues.first)
        #expect(written == GlucoseUnit.mmolL.canonicalMgdL(fromDisplayed: 5.3))
        #expect(written == UnitPreferences(glucose: .mmolL).canonicalGlucose(fromDisplayed: 5.3))
        #expect(abs(written - 95.496) < 0.001)
    }

    @Test("an mmol/L account's 12 is 216 mg/dL, not 12 mg/dL")
    func mmolAccountTwelveIsNotTwelveMgdl() async throws {
        let api = try install(unit: .mmolL)
        defer { IntentDependencies.testOverride = nil }

        let intent = LogBloodGlucoseIntent()
        intent.value = 12
        intent.context = .unspecified
        _ = try await intent.perform()

        let written = try #require(await api.postedValues.first)
        #expect(abs(written - 216.2184) < 0.001)
    }

    @Test("an mg/dL account's value is written unchanged")
    func mgdlAccountWritesVerbatim() async throws {
        let api = try install(unit: .mgdL)
        defer { IntentDependencies.testOverride = nil }

        let intent = LogBloodGlucoseIntent()
        intent.value = 104
        intent.context = .afterMeal
        _ = try await intent.perform()

        #expect(await api.postedValues == [104])
    }

    @Test("an implausible value in the account unit is refused without a write")
    func implausibleValueIsRefused() async throws {
        let api = try install(unit: .mmolL)
        defer { IntentDependencies.testOverride = nil }

        let intent = LogBloodGlucoseIntent()
        intent.value = 0.4 // 7.2 mg/dL
        intent.context = .unspecified
        _ = try await intent.perform()

        #expect(await api.postedValues.isEmpty)
    }

    @Test("the plausibility band holds in both units", arguments: [
        (5.3, GlucoseUnit.mmolL, true),
        (0.5, GlucoseUnit.mmolL, false),
        (60.0, GlucoseUnit.mmolL, false),
        (9.0, GlucoseUnit.mgdL, false),
        (95.0, GlucoseUnit.mgdL, true),
        (1001.0, GlucoseUnit.mgdL, false)
    ])
    func canonicalBand(value: Double, unit: GlucoseUnit, accepted: Bool) {
        #expect((LogBloodGlucoseIntent.canonicalValue(value, unit: unit) != nil) == accepted)
    }

    // MARK: - LogMeasurementIntent

    @Test("the generic intent takes glucose in the account unit, other kinds unchanged")
    func genericIntentGlucoseArm() async throws {
        let api = try install(unit: .mmolL)
        defer { IntentDependencies.testOverride = nil }

        let glucose = LogMeasurementIntent()
        glucose.kind = .glucose
        glucose.value = 5.3
        _ = try await glucose.perform()

        let weight = LogMeasurementIntent()
        weight.kind = .weight
        weight.value = 72.4
        _ = try await weight.perform()

        let values = await api.postedValues
        #expect(values.count == 2)
        #expect(values.first == GlucoseUnit.mmolL.canonicalMgdL(fromDisplayed: 5.3))
        #expect(values.last == 72.4)
    }

    @Test("the generic intent speaks glucose back in the account unit")
    func genericIntentSpokenUnit() {
        #expect(MeasurableKindAppEnum.glucose.spokenUnit(units: UnitPreferences(glucose: .mmolL)).key == "intents.unit.mmoll")
        #expect(MeasurableKindAppEnum.glucose.spokenUnit(units: UnitPreferences(glucose: .mgdL)).key == "intents.unit.mgdl")
        #expect(MeasurableKindAppEnum.weight.spokenUnit(units: UnitPreferences(glucose: .mmolL)).key == "intents.unit.kg")
    }

    // MARK: - Where the unit comes from

    @Test("the account unit: shared mirror first, then the app mirror, then mg/dL")
    func accountUnitResolution() throws {
        let group = try #require(UserDefaults(suiteName: "b5.intent.group.\(UUID().uuidString)"))
        let app = try #require(UserDefaults(suiteName: "b5.intent.app.\(UUID().uuidString)"))
        let signedIn = SharedAccountPrefs(defaults: group, currentUserID: { "user-a" })

        #expect(IntentDependencies.accountGlucoseUnit(shared: signedIn, appDefaults: app) == .mgdL)

        app.set(GlucoseUnit.mmolL.rawValue, forKey: IntentDependencies.appGlucoseUnitMirrorKey)
        #expect(IntentDependencies.accountGlucoseUnit(shared: signedIn, appDefaults: app) == .mmolL)

        signedIn.setGlucoseUnit(.mgdL)
        #expect(IntentDependencies.accountGlucoseUnit(shared: signedIn, appDefaults: app) == .mgdL)

        // Another account's shared entry does not count.
        let otherAccount = SharedAccountPrefs(defaults: group, currentUserID: { "user-b" })
        #expect(IntentDependencies.accountGlucoseUnit(shared: otherAccount, appDefaults: app) == .mmolL)
    }

    @Test("the app mirror key is the settings store's")
    func appMirrorKeyMatchesSettingsStore() {
        #expect(IntentDependencies.appGlucoseUnitMirrorKey == SettingsStore.glucoseUnitDefaultsKey)
    }
}

// MARK: - Stub

/// Records the `value` of every measurement POST and answers with a canned
/// server row.
private actor BodyRecordingAPIClient: APIClientProtocol {
    private(set) var postedValues: [Double] = []

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        if let body = request.body,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let value = object["value"] as? Double
        {
            postedValues.append(value)
        }
        let json = """
        {"id":"srv-1","type":"BLOOD_GLUCOSE","value":95,"measuredAt":"2026-05-28T08:00:00Z","source":"MANUAL"}
        """
        return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("download not stubbed")
    }
}
