import AppIntents
import Foundation
@testable import HealthLog
import Testing

/// **W-B187 QOL-1** — coverage for the per-medication READ intent
/// ("Did I take Lisinopril?").
///
/// Two layers:
///   - ``DidITakeMedicationCopy/verdict(for:in:)`` — the pure
///     (id, today-intakes) → taken / not-yet / nothing-scheduled mapping.
///     No perform, no I/O.
///   - ``DidITakeMedicationIntent/perform()`` — the sign-in gate + the
///     server-first `todayIntakes()` read via a stub `APIClient`, asserting
///     it hits the right path and degrades softly on offline.
@Suite("Did-I-take medication intent")
@MainActor
struct DidITakeMedicationIntentTests {
    // MARK: - Pure verdict mapping

    private func intake(med: String, status: IntakeStatus, takenAt: Date? = nil) -> MedicationIntake {
        MedicationIntake(
            id: UUID().uuidString,
            medicationId: med,
            scheduledAt: .now,
            takenAt: takenAt,
            status: status
        )
    }

    @Test("A taken slot reads as taken and carries the latest takenAt")
    func takenVerdict() {
        let early = Date(timeIntervalSince1970: 1000)
        let late = Date(timeIntervalSince1970: 2000)
        let verdict = DidITakeMedicationCopy.verdict(
            for: "med-a",
            in: [
                intake(med: "med-a", status: .taken, takenAt: early),
                intake(med: "med-a", status: .taken, takenAt: late),
                intake(med: "med-b", status: .taken, takenAt: late)
            ]
        )
        #expect(verdict == .taken(at: late))
    }

    @Test("A scheduled-but-pending med reads as not-yet")
    func notYetVerdict() {
        let verdict = DidITakeMedicationCopy.verdict(
            for: "med-a",
            in: [intake(med: "med-a", status: .pending)]
        )
        #expect(verdict == .notYet)
    }

    @Test("A snoozed/skipped slot with no taken slot still reads as not-yet")
    func snoozedReadsNotYet() {
        let verdict = DidITakeMedicationCopy.verdict(
            for: "med-a",
            in: [intake(med: "med-a", status: .snoozed), intake(med: "med-a", status: .skipped)]
        )
        #expect(verdict == .notYet)
    }

    @Test("A med with no row today reads as nothing-scheduled")
    func noneScheduledVerdict() {
        let verdict = DidITakeMedicationCopy.verdict(
            for: "med-a",
            in: [intake(med: "med-b", status: .taken, takenAt: .now)]
        )
        #expect(verdict == .noneScheduled)
    }

    // MARK: - Copy rendering (forced locale for determinism)

    private func rendered(name: String, verdict: DidITakeMedicationCopy.Verdict, locale: Locale = Locale(identifier: "en")) -> String {
        var resource = DidITakeMedicationCopy.resource(name: name, verdict: verdict)
        resource.locale = locale
        return String(localized: resource)
    }

    @Test("Not-yet copy names the medication")
    func notYetCopy() {
        #expect(rendered(name: "Lisinopril", verdict: .notYet) == "No — you haven't taken Lisinopril yet today.")
    }

    @Test("Nothing-scheduled copy names the medication")
    func noneScheduledCopy() {
        #expect(rendered(name: "Lisinopril", verdict: .noneScheduled) == "Lisinopril isn't scheduled for today.")
    }

    // MARK: - perform()

    @Test("Signed-out surfaces the sign-in dialog, no fetch")
    func signedOutGate() async throws {
        let api = try installOverride(signedIn: false, behaviour: .succeed)
        defer { IntentDependencies.testOverride = nil }

        let intent = DidITakeMedicationIntent()
        intent.medication = MedicationEntity(id: "med-a", name: "Lisinopril")
        _ = try await intent.perform()
        #expect(await api.sentPaths.isEmpty)
    }

    @Test("Signed-in reads today's intake list server-first")
    func readsTodayIntakes() async throws {
        let api = try installOverride(signedIn: true, behaviour: .succeed)
        defer { IntentDependencies.testOverride = nil }

        let intent = DidITakeMedicationIntent()
        intent.medication = MedicationEntity(id: "med-a", name: "Lisinopril")
        _ = try await intent.perform()
        #expect(await api.sentPaths == ["/api/medications/intake"])
    }

    @Test("Offline degrades to a soft dialog, never throws")
    func offlineSoftFails() async throws {
        _ = try installOverride(signedIn: true, behaviour: .offline)
        defer { IntentDependencies.testOverride = nil }

        let intent = DidITakeMedicationIntent()
        intent.medication = MedicationEntity(id: "med-a", name: "Lisinopril")
        // Must not throw — a read intent degrades to a dialog.
        _ = try await intent.perform()
    }

    // MARK: - Harness

    private func installOverride(signedIn: Bool, behaviour: DidITakeStubAPIClient.Behaviour) throws -> DidITakeStubAPIClient {
        let keychain = InMemoryKeychain()
        if signedIn {
            try keychain.setString("test-bearer", forKey: KeychainKey.authToken)
        }
        let api = DidITakeStubAPIClient(behaviour: behaviour)
        let outbox = try OutboxQueue(inMemory: true)
        IntentDependencies.testOverride = IntentDependencies.Resolved(
            keychain: keychain,
            api: api,
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox)
        )
        return api
    }
}

/// Stub that records sent paths and answers `/api/medications/intake`
/// (today scope) with a single taken slot for `med-a`.
private actor DidITakeStubAPIClient: APIClientProtocol {
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
            let iso = ISO8601DateFormatter().string(from: .now)
            let json = """
            [{"id":"i1","medicationId":"med-a","scheduledAt":"\(iso)","takenAt":"\(iso)","status":"taken"}]
            """
            return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
        }
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        sentPaths.append(request.path)
        if case .offline = behaviour { throw HLError.offline }
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("download not stubbed")
    }
}
