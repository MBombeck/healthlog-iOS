import AppIntents
import Foundation
@testable import HealthLog
import Testing

/// **v0.7.1 W-APPINTENTS** — perform-logic coverage for the three Siri /
/// Shortcuts intents.
///
/// The intents resolve dependencies via `IntentDependencies.resolve()`,
/// which we override with a stub `APIClient` + in-memory Outbox so each
/// `perform()` runs the **real** repository write path
/// (`MeasurementsRepository.create` / `MedicationsRepository.recordFromReminder`)
/// without touching the network or the live Keychain.
///
/// The load-bearing assertions:
///   - signed-out → no write, sign-in dialog;
///   - happy path → the POST hit the documented endpoint;
///   - network failure → the write lands on the Outbox with a non-empty
///     idempotency key (server-first + optimistic + outbox contract).
@Suite("HealthLog App Intents — perform routing")
@MainActor
struct HealthLogIntentsTests {
    // MARK: - Harness

    /// Builds a `Resolved` bundle backed by a stub API + in-memory Outbox
    /// and installs it as the test override. The `signedIn` flag seeds
    /// the keychain auth token so the intent gate passes/fails as needed.
    private func installOverride(
        signedIn: Bool,
        apiBehaviour: IntentStubAPIClient.Behaviour
    ) throws -> (api: IntentStubAPIClient, outbox: OutboxQueue) {
        let keychain = InMemoryKeychain()
        if signedIn {
            try keychain.setString("test-bearer", forKey: KeychainKey.authToken)
        }
        let api = IntentStubAPIClient(behaviour: apiBehaviour)
        let outbox = try OutboxQueue(inMemory: true)
        IntentDependencies.testOverride = IntentDependencies.Resolved(
            keychain: keychain,
            api: api,
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox)
        )
        return (api, outbox)
    }

    private func clearOverride() {
        IntentDependencies.testOverride = nil
    }

    // MARK: - Log blood glucose

    @Test("LogBloodGlucose happy path POSTs to /api/measurements")
    func glucoseHappyPath() async throws {
        let (api, outbox) = try installOverride(signedIn: true, apiBehaviour: .succeed)
        defer { clearOverride() }

        let intent = LogBloodGlucoseIntent()
        intent.value = 95
        intent.context = .fasting
        _ = try await intent.perform()

        let paths = await api.sentPaths
        #expect(paths == ["/api/measurements"])
        // Happy path → nothing queued.
        let queued = await outbox.snapshot
        #expect(queued.isEmpty)
    }

    @Test("LogBloodGlucose network failure enqueues on the Outbox with an idempotency key")
    func glucoseQueuesOnFailure() async throws {
        let (_, outbox) = try installOverride(signedIn: true, apiBehaviour: .offline)
        defer { clearOverride() }

        let intent = LogBloodGlucoseIntent()
        intent.value = 110
        intent.context = .afterMeal
        _ = try await intent.perform()

        let queued = await outbox.snapshot
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .createMeasurement)
        #expect(queued.first?.idempotencyKey.isEmpty == false)
    }

    @Test("LogBloodGlucose signed out → no write")
    func glucoseSignedOut() async throws {
        let (api, outbox) = try installOverride(signedIn: false, apiBehaviour: .succeed)
        defer { clearOverride() }

        let intent = LogBloodGlucoseIntent()
        intent.value = 100
        intent.context = .unspecified
        _ = try await intent.perform()

        #expect(await api.sentPaths.isEmpty)
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - Log blood pressure

    @Test("LogBloodPressure happy path POSTs to /api/measurements")
    func bloodPressureHappyPath() async throws {
        let (api, outbox) = try installOverride(signedIn: true, apiBehaviour: .succeed)
        defer { clearOverride() }

        let intent = LogBloodPressureIntent()
        intent.systolic = 128
        intent.diastolic = 82
        _ = try await intent.perform()

        // BP splits into two server wire-rows (sys + dia) sharing one
        // idempotency key — both POST to /api/measurements.
        let paths = await api.sentPaths
        #expect(paths == ["/api/measurements", "/api/measurements"])
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("LogBloodPressure network failure enqueues on the Outbox with an idempotency key")
    func bloodPressureQueuesOnFailure() async throws {
        let (_, outbox) = try installOverride(signedIn: true, apiBehaviour: .offline)
        defer { clearOverride() }

        let intent = LogBloodPressureIntent()
        intent.systolic = 135
        intent.diastolic = 88
        _ = try await intent.perform()

        let queued = await outbox.snapshot
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .createMeasurement)
        #expect(queued.first?.idempotencyKey.isEmpty == false)
    }

    @Test("LogBloodPressure rejects transposed systolic/diastolic without a write")
    func bloodPressureRejectsTransposed() async throws {
        let (api, outbox) = try installOverride(signedIn: true, apiBehaviour: .succeed)
        defer { clearOverride() }

        let intent = LogBloodPressureIntent()
        intent.systolic = 70 // lower than diastolic → invalid
        intent.diastolic = 110
        _ = try await intent.perform()

        #expect(await api.sentPaths.isEmpty)
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - Log a measurement (v0.15 W-SIRI generic intent)

    @Test("LogMeasurement happy path routes a scalar to /api/measurements")
    func logMeasurementHappyPath() async throws {
        let (api, outbox) = try installOverride(signedIn: true, apiBehaviour: .succeed)
        defer { clearOverride() }

        let intent = LogMeasurementIntent()
        intent.kind = .weight
        intent.value = 72.4
        _ = try await intent.perform()

        // Routes through the same create path as the manual sheet — one POST.
        #expect(await api.sentPaths == ["/api/measurements"])
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("LogMeasurement network failure enqueues createMeasurement with an idempotency key")
    func logMeasurementQueuesOnFailure() async throws {
        let (_, outbox) = try installOverride(signedIn: true, apiBehaviour: .offline)
        defer { clearOverride() }

        let intent = LogMeasurementIntent()
        intent.kind = .pulse
        intent.value = 64
        _ = try await intent.perform()

        let queued = await outbox.snapshot
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .createMeasurement)
        #expect(queued.first?.idempotencyKey.isEmpty == false)
    }

    @Test("LogMeasurement signed out → no write")
    func logMeasurementSignedOut() async throws {
        let (api, outbox) = try installOverride(signedIn: false, apiBehaviour: .succeed)
        defer { clearOverride() }

        let intent = LogMeasurementIntent()
        intent.kind = .weight
        intent.value = 70
        _ = try await intent.perform()

        #expect(await api.sentPaths.isEmpty)
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("LogMeasurement rejects an out-of-range value without a write")
    func logMeasurementRejectsOutOfRange() async throws {
        let (api, outbox) = try installOverride(signedIn: true, apiBehaviour: .succeed)
        defer { clearOverride() }

        let intent = LogMeasurementIntent()
        intent.kind = .spo2
        intent.value = 5 // SpO₂ 5% — implausible
        _ = try await intent.perform()

        #expect(await api.sentPaths.isEmpty)
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("MeasurableKindAppEnum maps each case onto the domain MetricKind")
    func measurableKindMapsToDomain() {
        #expect(MeasurableKindAppEnum.weight.domainKind == .weight)
        #expect(MeasurableKindAppEnum.pulse.domainKind == .pulse)
        #expect(MeasurableKindAppEnum.glucose.domainKind == .glucose)
        #expect(MeasurableKindAppEnum.bodyTemperature.domainKind == .bodyTemperature)
        #expect(MeasurableKindAppEnum.spo2.domainKind == .spo2)
        #expect(MeasurableKindAppEnum.respiratoryRate.domainKind == .respiratoryRate)
        #expect(MeasurableKindAppEnum.bodyFat.domainKind == .bodyFat)
    }

    @Test("MeasurableKindAppEnum plausibility bounds reject transposed / nonsense values")
    func measurableKindPlausibility() {
        #expect(MeasurableKindAppEnum.weight.isPlausible(72) == true)
        #expect(MeasurableKindAppEnum.weight.isPlausible(0) == false)
        #expect(MeasurableKindAppEnum.bodyTemperature.isPlausible(37) == true)
        #expect(MeasurableKindAppEnum.bodyTemperature.isPlausible(120) == false)
        #expect(MeasurableKindAppEnum.spo2.isPlausible(98) == true)
        #expect(MeasurableKindAppEnum.spo2.isPlausible(5) == false)
        #expect(MeasurableKindAppEnum.pulse.isPlausible(.nan) == false)
    }

    // MARK: - Mark medication taken

    @Test("MarkMedicationTaken happy path POSTs to the bulk-intake endpoint")
    func medicationHappyPath() async throws {
        let (api, outbox) = try installOverride(signedIn: true, apiBehaviour: .succeed)
        defer { clearOverride() }

        let intent = MarkMedicationTakenIntent()
        intent.medication = MedicationEntity(id: "med-1", name: "Trulicity")
        _ = try await intent.perform()

        #expect(await api.sentPaths == ["/api/medications/intake/bulk"])
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("MarkMedicationTaken network failure enqueues takeMedication with an idempotency key")
    func medicationQueuesOnFailure() async throws {
        let (_, outbox) = try installOverride(signedIn: true, apiBehaviour: .offline)
        defer { clearOverride() }

        let intent = MarkMedicationTakenIntent()
        intent.medication = MedicationEntity(id: "med-2", name: "Metformin")
        _ = try await intent.perform()

        let queued = await outbox.snapshot
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .takeMedication)
        #expect(queued.first?.idempotencyKey.isEmpty == false)
    }

    @Test("MarkMedicationTaken records against the supplied slot epoch, not now")
    func medicationSlotInstantOverride() {
        // Widget path: an explicit slot epoch → that exact instant.
        let slot = Date(timeIntervalSince1970: 1_799_999_000)
        let resolved = MarkMedicationTakenIntent.resolveScheduledFor(
            epoch: slot.timeIntervalSince1970,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(resolved == slot)
    }

    @Test("MarkMedicationTaken with no slot epoch falls back to now (Siri semantics)")
    func medicationNilEpochUsesNow() {
        // Siri / Shortcuts leave the epoch nil → "I took it now".
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resolved = MarkMedicationTakenIntent.resolveScheduledFor(epoch: nil, now: now)
        #expect(resolved == now)
    }

    @Test("MarkMedicationTaken signed out → no write")
    func medicationSignedOut() async throws {
        let (api, outbox) = try installOverride(signedIn: false, apiBehaviour: .succeed)
        defer { clearOverride() }

        let intent = MarkMedicationTakenIntent()
        intent.medication = MedicationEntity(id: "med-3", name: "Lisinopril")
        _ = try await intent.perform()

        #expect(await api.sentPaths.isEmpty)
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - Log mood (v0.10.0 W-Mood-B)

    @Test("MoodLevelAppEnum maps each case onto the domain ServerMoodLevel score 1…5")
    func moodEnumMapsToScore() {
        #expect(MoodLevelAppEnum.lousy.score == 1)
        #expect(MoodLevelAppEnum.bad.score == 2)
        #expect(MoodLevelAppEnum.okay.score == 3)
        #expect(MoodLevelAppEnum.good.score == 4)
        #expect(MoodLevelAppEnum.great.score == 5)
        #expect(MoodLevelAppEnum.great.serverLevel == .great)
        #expect(MoodLevelAppEnum.lousy.serverLevel == .lousy)
    }

    @Test("LogMood happy path POSTs to /api/mood-entries")
    func moodHappyPath() async throws {
        let (api, outbox) = try installOverride(signedIn: true, apiBehaviour: .succeed)
        defer { clearOverride() }

        let intent = LogMoodIntent()
        intent.level = .good
        _ = try await intent.perform()

        #expect(await api.sentPaths == ["/api/mood-entries"])
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("LogMood network failure enqueues logMood with an idempotency key")
    func moodQueuesOnFailure() async throws {
        let (_, outbox) = try installOverride(signedIn: true, apiBehaviour: .offline)
        defer { clearOverride() }

        let intent = LogMoodIntent()
        intent.level = .okay
        _ = try await intent.perform()

        let queued = await outbox.snapshot
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .logMood)
        #expect(queued.first?.idempotencyKey.isEmpty == false)
    }

    @Test("LogMood signed out → no write")
    func moodSignedOut() async throws {
        let (api, outbox) = try installOverride(signedIn: false, apiBehaviour: .succeed)
        defer { clearOverride() }

        let intent = LogMoodIntent()
        intent.level = .great
        _ = try await intent.perform()

        #expect(await api.sentPaths.isEmpty)
        #expect(await outbox.snapshot.isEmpty)
    }

    // MARK: - Mark dose from Live Activity (v0.10 W-LiveActivity-POLISH)

    #if canImport(ActivityKit)
        /// The Live-Activity "Genommen" intent carries the SCHEDULED instant
        /// (not "now") so the recorded row de-dupes onto the in-app card's row.
        /// `perform()` no-ops without a running Activity (none exists in a unit
        /// test), so we pin the load-bearing de-dupe contract on the intent's
        /// parameters + its `LiveActivityIntent` shape.
        @Test("MarkDoseFromLiveActivity carries the scheduled instant for de-dupe")
        func liveActivityIntentCarriesScheduledInstant() {
            let scheduled = Date(timeIntervalSince1970: 1_800_000_000)
            let intent = MarkDoseFromLiveActivityIntent(
                medicationId: "med-7",
                scheduledFor: scheduled
            )
            // The row keys on (medicationId, scheduledFor) — the intent must
            // hand the scheduled instant, never `Date()`.
            #expect(intent.medicationId == "med-7")
            #expect(intent.scheduledFor == scheduled)
            // Never opens the app — the whole point is an in-place confirm.
            #expect(MarkDoseFromLiveActivityIntent.openAppWhenRun == false)
        }

        /// Without a running Activity the intent is a pure no-op (the
        /// `confirmedState()` guard short-circuits before any record), so a
        /// stray invocation never POSTs nor enqueues.
        @Test("MarkDoseFromLiveActivity no-ops when no Activity is running")
        func liveActivityIntentNoOpsWithoutActivity() async throws {
            let (api, outbox) = try installOverride(signedIn: true, apiBehaviour: .succeed)
            defer { clearOverride() }

            let intent = MarkDoseFromLiveActivityIntent(
                medicationId: "med-8",
                scheduledFor: Date(timeIntervalSince1970: 1_800_000_000)
            )
            _ = try await intent.perform()

            #expect(await api.sentPaths.isEmpty)
            #expect(await outbox.snapshot.isEmpty)
        }
    #endif
}

// MARK: - Stub APIClient

/// Records the paths it was asked to POST + replays a canned outcome. The
/// `.offline` behaviour throws a retriable `HLError` so the repo routes
/// the write to the Outbox — exactly the path the intents rely on.
private actor IntentStubAPIClient: APIClientProtocol {
    enum Behaviour {
        case succeed
        case offline
    }

    private let behaviour: Behaviour
    private(set) var sentPaths: [String] = []

    init(behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        sentPaths.append(request.path)
        switch behaviour {
        case .offline:
            throw HLError.offline
        case .succeed:
            return try Self.cannedResponse(for: request)
        }
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        sentPaths.append(request.path)
        if case .offline = behaviour { throw HLError.offline }
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("download not stubbed")
    }

    /// Returns a wire-shaped success payload for the two endpoints the
    /// intents POST to. Decodes the canned JSON into the expected `T`.
    private static func cannedResponse<T: Decodable>(for request: APIRequest<T>) throws -> T {
        let json = if request.path == "/api/medications/intake/bulk" {
            """
            {"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"taken","id":"i-1","reason":null}]}
            """
        } else if request.path == "/api/mood-entries" {
            // Mood create echoes a single server `MoodEntry`.
            """
            {"id":"mood-1","mood":"GUT","tags":[],"moodLoggedAt":"2026-05-31T20:00:00Z","source":"MANUAL","note":null}
            """
        } else {
            // Measurement create echoes a single server wire row
            // (`MeasurementWireDTO`).
            """
            {"id":"srv-1","type":"BLOOD_GLUCOSE","value":95,"measuredAt":"2026-05-28T08:00:00Z","source":"MANUAL"}
            """
        }
        let decoder = JSONDecoder.hlDefault
        return try decoder.decode(T.self, from: Data(json.utf8))
    }
}
