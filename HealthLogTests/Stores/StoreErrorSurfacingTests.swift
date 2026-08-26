import Foundation
@testable import HealthLog
import Testing

/// Audit-v021 C5 regression coverage: bestaetigt, dass jeder der vier
/// vorher betroffenen Stores Server-Fehler **tatsaechlich** in
/// `error: HLError?` ablegt — und beim erneuten erfolgreichen Load wieder
/// auf nil zuruecksetzt. Der ErrorBanner im Screen blendet sich anhand
/// dieses Werts ein/aus, also ist der Property-Round-Trip die
/// API-Garantie, die wir hier festziehen.
@MainActor
@Suite("Store error surfacing — C5 regression")
struct StoreErrorSurfacingTests {
    // MARK: - ChartsStore

    @Test("ChartsStore.load() persistiert HLError bei Server-500 + clears bei Erfolg")
    func chartsStoreSurfacesServerError() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        let store = ChartsStore(repo: repo)

        // Erste Load: Server wirft 500. Erwartung: error gesetzt + series nil.
        await api.setHandler { _ in throw HLError.server(status: 500, code: "INTERNAL", message: "boom") }
        await store.load(kind: .weight, days: 30)
        #expect(store.error != nil, "error muss nach Server-500 gesetzt sein (audit C5)")
        #expect(store.series == nil)
        if case let .server(status, _, _) = store.error {
            #expect(status == 500)
        } else {
            Issue.record("erwartet HLError.server, war \(String(describing: store.error))")
        }

        // Zweiter Load: Erfolg. Erwartung: error wieder nil — banner blendet sich aus.
        let series = MeasurementSeries(
            kind: .weight,
            points: [],
            stats: SeriesStats(mean: 0, min: 0, max: 0, stdDev: 0, count: 0)
        )
        await api.setHandler { _ in series }
        await store.load(kind: .weight, days: 30)
        #expect(store.error == nil, "error muss nach Erfolg auf nil gehen (banner soll auto-dismissen)")
    }

    @Test("ChartsStore.load() persistiert HLError bei Network-Offline")
    func chartsStoreSurfacesNetworkError() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        let store = ChartsStore(repo: repo)

        await api.setHandler { _ in throw HLError.offline }
        await store.load(kind: .weight, days: 30)
        #expect(store.error == .offline)
    }

    // MARK: - AchievementsStore

    @Test("AchievementsStore.load() persistiert HLError bei 422 + clears bei Erfolg")
    func achievementsStoreSurfacesError() async {
        let api = StubAPIClient()
        let repo = AchievementsRepository(api: api)
        let store = AchievementsStore(repo: repo)

        await api.setHandler { _ in throw HLError.server(status: 422, code: "BAD_REQUEST", message: "schema mismatch") }
        await store.load()
        #expect(store.error != nil)
        #expect(store.achievements.isEmpty)
        if case let .server(status, _, _) = store.error {
            #expect(status == 422)
        } else {
            Issue.record("erwartet HLError.server(422)")
        }

        let payload: [Achievement] = [
            Achievement(id: "a1", key: "first_log", title: "Start", description: "first measurement", unlocked: true)
        ]
        await api.setHandler { _ in payload }
        await store.load()
        #expect(store.error == nil)
        #expect(store.achievements.count == 1)
    }

    // MARK: - MoodStore

    @Test("MoodStore.load() persistiert HLError + clears bei Erfolg")
    func moodStoreSurfacesError() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)
        let store = MoodStore(repo: repo)

        await api.setHandler { _ in throw HLError.server(status: 500, code: nil, message: "down") }
        await store.load()
        #expect(store.error != nil)
        #expect(store.entries.isEmpty)

        let payload = MoodListResponse(entries: [], meta: nil)
        await api.setHandler { _ in payload }
        await store.load()
        #expect(store.error == nil)
    }

    // MARK: - MedicationsStore

    @Test("MedicationsStore.load() persistiert HLError + clears bei Erfolg")
    func medicationsStoreSurfacesError() async throws {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        await api.setHandler { _ in throw HLError.network(.timeout) }
        await store.load()
        #expect(store.error != nil)
        #expect(store.medications.isEmpty)

        // Erfolgs-Pfad: list / today / compliance werden parallel via async let geladen
        // — ein Handler reicht weil der Stub typenbasiert dispatcht.
        await api.setHandler { request in
            switch request {
            case is APIRequest<[MedicationWireDTO]>:
                return [MedicationWireDTO]()
            case is APIRequest<[MedicationIntake]>:
                return [MedicationIntake]()
            case is APIRequest<[ComplianceDay]>:
                return [ComplianceDay]()
            default:
                throw HLError.unknown("unexpected request")
            }
        }
        await store.load()
        #expect(store.error == nil)
    }
}

// MARK: - HLError + ErrorBanner copy

@Suite("HLError userFacingDescription")
struct HLErrorUserFacingTests {
    @Test("4xx exponiert die Server-message verbatim")
    func server4xxMessage() {
        let err: HLError = .server(status: 422, code: "INVALID_INPUT", message: "Wert ist nicht gueltig.")
        #expect(err.userFacingDescription == "Wert ist nicht gueltig.")
    }

    @Test("5xx unterdrueckt die technische Server-message")
    func server5xxMessage() {
        // 5xx Server-message ist oft technisch ("Database connection lost").
        // Wir zeigen stattdessen eine ruhige Standard-Copy.
        let err: HLError = .server(status: 500, code: "INTERNAL", message: "Datenbank temporaer offline")
        #expect(err.userFacingDescription != "Datenbank temporaer offline")
        #expect(err.userFacingDescription.contains("Server"))
    }

    @Test("offline ist sprechbar fuer den User")
    func offlineCopy() {
        let copy = HLError.offline.userFacingDescription
        #expect(copy.contains("Offline"))
    }

    @Test("unauthorized weist auf Re-Login hin")
    func unauthorizedCopy() {
        #expect(HLError.unauthorized.userFacingDescription.contains("anmelden"))
    }

    @Test("network timeout hat eigene Copy")
    func networkTimeoutCopy() {
        let copy = HLError.network(.timeout).userFacingDescription
        #expect(copy.contains("zu lange") || copy.contains("too long"))
    }

    @Test("Decoding-Fehler darf NIEMALS rohen DecodingError-Text leaken")
    func decodingNeverLeaksRawText() {
        // Pre-v0.4.0 user-report #5: "Type Mismatch Expected" surfaced verbatim.
        // The translation layer must swallow the raw text and replace it
        // with friendly copy. The raw text is logged separately via HLLog.
        let raw = #"typeMismatch(Swift.Array<...>, Swift.DecodingError.Context(codingPath: [...], debugDescription: "Expected to decode Array<...> but found ..."))"#
        let err: HLError = .decoding(raw)
        let copy = err.userFacingDescription
        // Forbidden technical fragments:
        #expect(!copy.contains("typeMismatch"))
        #expect(!copy.contains("Type mismatch"))
        #expect(!copy.contains("DecodingError"))
        #expect(!copy.contains("keyNotFound"))
        #expect(!copy.contains("Key not found"))
        #expect(!copy.contains("codingPath"))
        #expect(!copy.contains("debugDescription"))
        // Required friendly copy:
        #expect(copy.contains("Daten") || copy.contains("data") || copy.contains("Erneut") || copy.contains("again"))
    }

    @Test("Rate-limit hat eigene Copy")
    func rateLimitCopy() {
        let copy = HLError.rateLimited(retryAfter: 30).userFacingDescription
        #expect(copy.contains("Anfragen") || copy.contains("requests"))
    }

    @Test("canceled rendert leeren String (silent)")
    func canceledIsSilent() {
        #expect(HLError.canceled.userFacingDescription == "")
    }

    @Test("unknown faellt auf neutrale Fallback-Copy")
    func unknownFallback() {
        let copy = HLError.unknown("backend exploded internal-detail-do-not-show").userFacingDescription
        // The internal string must NOT be exposed; show neutral copy.
        #expect(!copy.contains("backend exploded internal-detail-do-not-show"))
        #expect(copy.contains("schiefgegangen") || copy.contains("wrong"))
    }
}
