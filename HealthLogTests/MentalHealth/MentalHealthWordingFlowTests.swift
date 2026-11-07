import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **L10N-MH — the questionnaire text, the `englishOriginal` switch and the
/// `wording` record, against servers with and without the field.**
///
/// Real `APIClient` + `MockURLProtocol`. The interface language and the
/// remembered server version are injected per store, so nothing here depends
/// on the host app's language or on another suite's defaults.
@MainActor
@Suite("Mental-health wording: form, submit, result (L10N-MH)", .serialized, .mockURLSession)
struct MentalHealthWordingFlowTests {
    // MARK: - Fixtures

    private func makeStore(
        language: AppLanguage,
        locale: String,
        serverVersion: String?
    ) throws -> (MentalHealthStore, UserDefaults) {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let defaults = try #require(UserDefaults(suiteName: "MentalHealthWordingFlowTests.\(UUID().uuidString)"))
        if let serverVersion {
            KnownServerVersion.record(ServerVersionInfo(version: serverVersion), defaults: defaults)
        }
        let store = try MentalHealthStore(
            repository: MentalHealthRepository(api: api, outbox: OutboxQueue(inMemory: true)),
            presentedLocale: locale,
            language: language,
            serverDefaults: defaults
        )
        return (store, defaults)
    }

    private func envelope(instrument: String, wording: String?, item9Flagged: Bool = false) -> Data {
        let wordingField = wording.map { #","wording":"\#($0)""# } ?? ""
        return Data("""
        {"data":{"assessment":{"id":"w1","instrument":"\(instrument)","locale":"de-DE","version":"standard",
          "totalScore":12,"severityBand":"belowThreshold","item9Flagged":\(item9Flagged),
          "crisisShownAt":null,"takenAt":"2026-11-04T08:00:00.000Z",
          "createdAt":"2026-11-04T08:00:00.000Z"\(wordingField)},
         "actionThreshold":16,"crisis":null},"error":null}
        """.utf8)
    }

    private func answerAll(_ store: MentalHealthStore, value: Int = 1) {
        for index in 0 ..< store.activeInstrument.itemCount {
            store.setAnswer(value, at: index)
        }
    }

    private func submitCapturing(_ store: MentalHealthStore, response: Data) async throws -> [String: Any] {
        let probe = WordingRequestProbe()
        MockURLProtocol.install { req in
            probe.capture(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, response)
        }
        await store.submit()
        return try probe.bodyJSON()
    }

    // MARK: - Form text

    @Test("SCI in German shows the server translation, the note and the switch; the switch shows the original")
    func sciGermanTranslationAndSwitch() throws {
        let (store, _) = try makeStore(language: .de, locale: "de-DE", serverVersion: "1.46.6")
        store.begin(.sci)
        #expect(store.translationIsUnvalidated)
        #expect(store.activeWordingLanguage == .de)
        #expect(store.activeWording?.item(0) == "\u{2026} wie lange brauchen Sie, um einzuschlafen?")

        store.toggleEnglishOriginal()
        #expect(store.showsEnglishOriginal)
        #expect(store.activeWordingLanguage == .en)
        #expect(store.activeWording?.item(0) == "\u{2026} how long does it take you to fall asleep?")

        store.toggleEnglishOriginal()
        #expect(store.activeWording?.item(0) == "\u{2026} wie lange brauchen Sie, um einzuschlafen?")

        // A new administration starts in the reader's language again.
        store.toggleEnglishOriginal()
        store.begin(.sci)
        #expect(!store.showsEnglishOriginal)
    }

    @Test("Validated text offers no switch", arguments: [AppLanguage.de, .en, .nl], [MentalHealthInstrument.phq9, .gad7, .who5])
    func validatedTextHasNoSwitch(language: AppLanguage, instrument: MentalHealthInstrument) throws {
        let (store, _) = try makeStore(language: language, locale: language.rawValue, serverVersion: "1.46.6")
        store.begin(instrument)
        #expect(!store.translationIsUnvalidated)
        store.toggleEnglishOriginal()
        #expect(!store.showsEnglishOriginal)
        #expect(store.activeWording == instrument.wording(in: language))
    }

    @Test("English readers see the validated SCI original and no note")
    func englishSci() throws {
        let (store, _) = try makeStore(language: .en, locale: "en-US", serverVersion: "1.46.6")
        store.begin(.sci)
        #expect(!store.translationIsUnvalidated)
        #expect(store.activeWording?.validated == true)
    }

    // MARK: - englishOriginal on the wire (acceptance c)

    @Test("Switched to the original: englishOriginal goes to 1.46.0+, never to 1.45 or an unknown server", arguments: [
        ("1.46.0", true), ("1.46.6", true), ("1.47.0", true), ("1.45.9", false), (nil, false)
    ] as [(String?, Bool)])
    func englishOriginalFollowsServerVersion(serverVersion: String?, sent: Bool) async throws {
        let (store, _) = try makeStore(language: .de, locale: "de-DE", serverVersion: serverVersion)
        store.begin(.sci)
        store.toggleEnglishOriginal()
        answerAll(store)
        let json = try await submitCapturing(store, response: envelope(instrument: "SCI", wording: sent ? "original_en" : nil))
        if sent {
            #expect(json["englishOriginal"] as? Bool == true)
        } else {
            #expect(json.keys.contains("englishOriginal") == false)
        }
        #expect(json["locale"] as? String == "de-DE")
        #expect(json["instrument"] as? String == "SCI")
    }

    @Test("Answered in the translation: no englishOriginal field, whatever the server")
    func translationSendsNoFlag() async throws {
        let (store, _) = try makeStore(language: .nl, locale: "nl-BE", serverVersion: "1.46.6")
        store.begin(.sci)
        answerAll(store)
        let json = try await submitCapturing(store, response: envelope(instrument: "SCI", wording: "unvalidated_translation"))
        #expect(json.keys.contains("englishOriginal") == false)
        #expect(json["locale"] as? String == "nl-BE")
    }

    // MARK: - Result wording (acceptance d)

    @Test("A result the server records as unvalidated_translation carries that wording")
    func serverWordingDrivesResult() async throws {
        let (store, _) = try makeStore(language: .de, locale: "de-DE", serverVersion: "1.46.6")
        store.begin(.sci)
        answerAll(store)
        _ = try await submitCapturing(store, response: envelope(instrument: "SCI", wording: "unvalidated_translation"))
        #expect(store.result?.wording == .unvalidatedTranslation)
        #expect(store.result?.serverDerived == true)
    }

    @Test("An older server sends no wording: the result says what the form showed")
    func olderServerFallsBackToShownWording() async throws {
        let (store, _) = try makeStore(language: .de, locale: "de-DE", serverVersion: "1.45.0")
        store.begin(.sci)
        answerAll(store)
        _ = try await submitCapturing(store, response: envelope(instrument: "SCI", wording: nil))
        #expect(store.result?.wording == .unvalidatedTranslation)

        let (validated, _) = try makeStore(language: .de, locale: "de-DE", serverVersion: "1.45.0")
        validated.begin(.gad7)
        answerAll(validated)
        _ = try await submitCapturing(validated, response: envelope(instrument: "GAD7", wording: nil))
        #expect(validated.result?.wording == .validated)
    }

    @Test("Switched to the original offline: the provisional result is not called a translation")
    func offlineOriginal() throws {
        let (store, _) = try makeStore(language: .de, locale: "de-DE", serverVersion: nil)
        store.begin(.sci)
        store.toggleEnglishOriginal()
        store.applyOfflineResultForTesting(instrument: .sci, items: Array(repeating: 2, count: 8))
        #expect(store.result?.wording == .originalEn)
    }

    // MARK: - Crisis offline with the region tag (acceptance f)

    @Test("Offline with a positive item 9: the region's fallback set appears", arguments: [
        ("nl-BE", "1813"), ("nl-NL", "113"), ("de-AT", "142"), ("en-US", "988"), ("de-DE", "0800 111 0 111")
    ])
    func offlineCrisisFollowsRegion(locale: String, line: String) async throws {
        let (store, _) = try makeStore(language: AppLanguage.resolve(locale), locale: locale, serverVersion: "1.46.6")
        MockURLProtocol.install { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        store.begin(.phq9)
        for index in 0 ..< 9 {
            store.setAnswer(index == 8 ? 1 : 0, at: index)
        }
        await store.submit()
        let result = try #require(store.result)
        #expect(result.serverDerived == false)
        let crisis = try #require(result.crisis)
        #expect(crisis == CrisisResourceFallback.forLocale(locale))
        #expect(crisis.resources.flatMap(\.contacts).contains(line))
    }

    // MARK: - History rows (acceptance g)

    @Test("A 1.4 history row (locale de or en, no wording) decodes as before")
    func legacyRowDecodes() throws {
        let json = """
        {"assessments":[
          {"id":"a","instrument":"PHQ9","locale":"de","version":"1","totalScore":4,"severityBand":"minimal",
           "item9Flagged":true,"crisisShownAt":null,"takenAt":"2026-09-01T08:00:00Z","createdAt":"2026-09-01T08:00:00Z"},
          {"id":"b","instrument":"GAD7","locale":"en","version":"1","totalScore":3,"severityBand":"minimal",
           "item9Flagged":false,"crisisShownAt":null,"takenAt":"2026-09-02T08:00:00Z","createdAt":"2026-09-02T08:00:00Z"}
        ]}
        """
        let rows = try JSONDecoder().decode(MentalHealthHistoryResponse.self, from: Data(json.utf8)).assessments
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.wording == nil })
        let (store, _) = try makeStore(language: .de, locale: "de-DE", serverVersion: nil)
        // The flagged 1.4 row re-opens the same German-speaking set as in 1.4.
        #expect(store.crisisSet(forHistoryRow: rows[0]) == CrisisResourceFallback.forLocale("de"))
    }

    @Test("wording decodes known values, keeps the row on an unknown one", arguments: [
        (#""wording":"unvalidated_translation","#, AssessmentWording.unvalidatedTranslation),
        (#""wording":"original_en","#, AssessmentWording.originalEn),
        (#""wording":"validated","#, AssessmentWording.validated),
        (#""wording":null,"#, nil),
        (#""wording":"machine_translation","#, nil),
        (#""wording":7,"#, nil)
    ] as [(String, AssessmentWording?)])
    func wordingDecoding(fragment: String, expected: AssessmentWording?) throws {
        let json = """
        {"assessments":[{"id":"a","instrument":"SCI","locale":"nl-BE",\(fragment)"version":"1","totalScore":4,
          "severityBand":"belowThreshold","item9Flagged":false,"crisisShownAt":null,
          "takenAt":"2026-11-01T08:00:00Z","createdAt":"2026-11-01T08:00:00Z"}]}
        """
        let rows = try JSONDecoder().decode(MentalHealthHistoryResponse.self, from: Data(json.utf8)).assessments
        #expect(rows.count == 1)
        #expect(rows.first?.wording == expected)
    }
}

/// Records the POST body only (the store reloads the history after a 201).
private final class WordingRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var body: Data?

    func capture(_ req: URLRequest) {
        guard req.httpMethod == "POST" else { return }
        lock.lock()
        defer { lock.unlock() }
        if let data = req.httpBody {
            body = data
        } else if let stream = req.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        }
    }

    func bodyJSON() throws -> [String: Any] {
        lock.lock()
        let data = body
        lock.unlock()
        guard let data else { return [:] }
        return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
