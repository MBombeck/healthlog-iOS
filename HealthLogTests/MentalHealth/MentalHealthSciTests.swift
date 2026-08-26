import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **CU-36 — Sleep Condition Indicator (SCI) on `POST /api/mental-health/assessments`.**
///
/// Two properties of this instrument are load-bearing and are pinned here rather
/// than left to review:
///
///  1. **The evaluation stays server-side.** The app collects eight answers and
///     renders the assessment the server resolved. The "consider talking to a
///     professional" nudge is driven by the `actionThreshold` the POST response
///     carries — NOT by the mirrored constant in ``MentalHealthInstrument``. The
///     tests below prove that by answering with a server threshold that
///     deliberately DISAGREES with the bundled mirror: the server wins.
///  2. **SCI's flag direction is inverted** relative to PHQ-9 / GAD-7 — a LOW
///     score is the notable side (`higherIsBetter == true`, threshold 16). A
///     comparison written the other way round would tell a good sleeper they
///     likely have insomnia and reassure a bad one, so both sides of 16 are
///     asserted explicitly.
///
/// Real `APIClient` + `MockURLProtocol` per PROJECT_GUIDE.md — never a mock server.
@MainActor
@Suite("SCI wire shape + server-evaluated result (CU-36)", .serialized)
struct MentalHealthSciWireTests {
    private func makeStore(locale: String, outbox: OutboxQueue) -> MentalHealthStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.34.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        return MentalHealthStore(
            repository: MentalHealthRepository(api: api, outbox: outbox),
            presentedLocale: locale
        )
    }

    /// A 201 envelope for one SCI administration with an explicit total + threshold.
    private func sciEnvelope(totalScore: Int, band: String, actionThreshold: Int) -> Data {
        Data("""
        {"data":{"assessment":{"id":"sciX","instrument":"SCI","locale":"de","version":"standard",
          "totalScore":\(totalScore),"severityBand":"\(band)","item9Flagged":false,
          "crisisShownAt":null,"takenAt":"2026-07-30T08:00:00.000Z",
          "createdAt":"2026-07-30T08:00:00.000Z"},
         "actionThreshold":\(actionThreshold),"crisis":null},"error":null}
        """.utf8)
    }

    private func answerAll(_ store: MentalHealthStore, _ values: [Int]) {
        for (index, value) in values.enumerated() {
            store.setAnswer(value, at: index)
        }
    }

    // MARK: - Request shape

    @Test("SCI submit POSTs { instrument: SCI, items: 8×0–4, locale, source, externalId } and no functionalDifficulty")
    func sciSubmitRequestShape() async throws {
        let probe = SciRequestProbe()
        MockURLProtocol.handler = { [envelope = sciEnvelope(totalScore: 20, band: "aboveThreshold", actionThreshold: 16)] req in
            probe.capture(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, envelope)
        }
        let store = try makeStore(locale: "de", outbox: OutboxQueue(inMemory: true))
        store.begin(.sci)
        let answers = [4, 3, 2, 1, 0, 4, 3, 3]
        answerAll(store, answers)
        #expect(store.isComplete)

        await store.submit()

        #expect(probe.method == "POST")
        #expect(probe.path == "/api/mental-health/assessments")
        let json = try probe.bodyJSON()
        #expect(json["instrument"] as? String == "SCI")
        #expect(json["items"] as? [Int] == answers)
        #expect((json["items"] as? [Int])?.count == MentalHealthInstrument.sci.itemCount)
        // Every answer rides the wire inside the instrument's own 0–4 scale.
        #expect((json["items"] as? [Int])?.allSatisfy { (0 ... MentalHealthInstrument.sci.itemMax).contains($0) } == true)
        #expect(json["locale"] as? String == "de")
        #expect(json["source"] as? String == "IOS")
        // Idempotency key is bound to the body's externalId (durable outbox dedup).
        let externalId = try #require(json["externalId"] as? String)
        #expect(probe.idempotencyKey == externalId)
        // SCI carries neither PHQ-9's unscored functional follow-up nor a userId.
        #expect(json["functionalDifficulty"] == nil)
        #expect(json["userId"] == nil)
    }

    @Test("SCI has no safety item, so a maximally-distressed answer set still returns no crisis card")
    func sciNeverRaisesCrisisCard() async throws {
        MockURLProtocol.handler = { [envelope = sciEnvelope(totalScore: 0, band: "belowThreshold", actionThreshold: 16)] req in
            (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, envelope)
        }
        let store = try makeStore(locale: "de", outbox: OutboxQueue(inMemory: true))
        store.begin(.sci)
        answerAll(store, Array(repeating: 0, count: 8))

        await store.submit()

        let result = try #require(store.result)
        #expect(result.item9Flagged == false)
        #expect(result.crisis == nil)
        #expect(MentalHealthInstrument.sci.safetyItemIndex == nil)
    }

    // MARK: - The server owns the evaluation

    @Test("The SERVER's actionThreshold drives the nudge, overriding the bundled mirror")
    func serverThresholdOverridesBundledMirror() async throws {
        // Server says 20; the bundled mirror says 16. A total of 18 is on the
        // notable side of the SERVER threshold (18 <= 20) but NOT of the mirror
        // (18 > 16). If the client were still consulting its own constant this
        // expectation would fail — that is the whole point of the fixture.
        #expect(MentalHealthInstrument.sci.actionThreshold == 16)
        MockURLProtocol.handler = { [envelope = sciEnvelope(totalScore: 18, band: "aboveThreshold", actionThreshold: 20)] req in
            (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, envelope)
        }
        let store = try makeStore(locale: "de", outbox: OutboxQueue(inMemory: true))
        store.begin(.sci)
        answerAll(store, Array(repeating: 2, count: 8))

        await store.submit()

        let result = try #require(store.result)
        #expect(result.serverDerived)
        #expect(result.actionThreshold == 20)
        #expect(result.showConsiderProfessional)
        // The band shown is the server's label, not a locally recomputed one.
        #expect(result.severityBand == "aboveThreshold")
        #expect(result.totalScore == 18)
    }

    @Test("SCI flags the LOW side of the threshold — the inverse of PHQ-9 / GAD-7", arguments: [
        (10, true), (16, true), (17, false), (32, false)
    ])
    func sciFlagsTheLowSide(total: Int, expectsNudge: Bool) async throws {
        let band = total <= 16 ? "belowThreshold" : "aboveThreshold"
        MockURLProtocol.handler = { [envelope = sciEnvelope(totalScore: total, band: band, actionThreshold: 16)] req in
            (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, envelope)
        }
        let store = try makeStore(locale: "de", outbox: OutboxQueue(inMemory: true))
        store.begin(.sci)
        answerAll(store, Array(repeating: 2, count: 8))

        await store.submit()

        let result = try #require(store.result)
        #expect(result.showConsiderProfessional == expectsNudge)
        // Contrast: on a distress scale the SAME number flags the opposite way.
        // Both directions are inclusive of the threshold itself, so the inversion
        // is strict only AWAY from the boundary — at total == 16 both flag.
        if total != 16 {
            #expect(MentalHealthInstrument.phq9.needsFollowUp(forTotal: total, threshold: 16) == !expectsNudge)
        }
    }

    @Test("The server's band label is rendered verbatim, even when it disagrees with the bundled bands")
    func serverBandLabelIsRenderedVerbatim() async throws {
        // A deliberately "wrong" pairing: the bundled bands would call 4
        // `belowThreshold`. The client must not second-guess the server.
        #expect(MentalHealthInstrument.sci.severityBand(forTotal: 4) == "belowThreshold")
        MockURLProtocol.handler = { [envelope = sciEnvelope(totalScore: 4, band: "aboveThreshold", actionThreshold: 16)] req in
            (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, envelope)
        }
        let store = try makeStore(locale: "de", outbox: OutboxQueue(inMemory: true))
        store.begin(.sci)
        answerAll(store, Array(repeating: 1, count: 8))

        await store.submit()

        #expect(try #require(store.result).severityBand == "aboveThreshold")
    }
}

/// **CU-36 — the localisation stance for a questionnaire validated in English only.**
///
/// The SCI's redistributed validated wording exists in English alone
/// (``MentalHealthInstrument/validatedItemLocales`` == `["en"]`). Re-wording a
/// validated instrument changes what it measures, so the eight items and their
/// three stems are shown in the ORIGINAL English in every language, with a
/// localised note explaining why. Everything AROUND the instrument — title,
/// description, bands, follow-up hint, buttons — is localised normally.
///
/// Pure catalog / source reads, no network → no `.serialized`.
@Suite("SCI localisation stance (CU-36)")
struct MentalHealthSciLocalisationTests {
    private static let itemKeys = (1 ... 8).map { "mentalHealth.items.sci.\($0)" }
    private static let stemKeys = [
        "mentalHealth.stems.sci.night",
        "mentalHealth.stems.sci.impact",
        "mentalHealth.stems.sci.finally"
    ]

    @Test("All eight SCI items and their three stems exist in both bundled languages")
    func allEightItemsArePresent() throws {
        let catalog = try ParityCatalog.load()
        #expect(Self.itemKeys.count == MentalHealthInstrument.sci.itemCount)
        for key in Self.itemKeys + Self.stemKeys {
            let entry = try #require(catalog.strings[key], "missing catalog entry \(key)")
            for language in ["de", "en"] {
                let value = ParityCatalog.value(entry, language: language)
                #expect(value?.isEmpty == false, "\(key) has no \(language) value")
            }
        }
    }

    @Test("Item wording is the English original in EVERY language — never freely translated")
    func itemWordingIsNotTranslated() throws {
        let catalog = try ParityCatalog.load()
        for key in Self.itemKeys + Self.stemKeys {
            let entry = try #require(catalog.strings[key])
            let de = try #require(ParityCatalog.value(entry, language: "de"))
            let en = try #require(ParityCatalog.value(entry, language: "en"))
            // Identical by design: a German rendering of a validated instrument
            // would change the measurement, so the original wording is shown.
            #expect(de == en, "\(key) was translated — the SCI wording must stay the English original")
        }
    }

    @Test("The explanatory note IS localised — the stance is explained, not silently applied")
    func explanatoryNoteIsLocalised() throws {
        let catalog = try ParityCatalog.load()
        let entry = try #require(catalog.strings["mentalHealth.validatedInEnglishNote"])
        let de = try #require(ParityCatalog.value(entry, language: "de"))
        let en = try #require(ParityCatalog.value(entry, language: "en"))
        #expect(de != en, "the note explaining the English wording must itself be translated")
        // It must state the two facts the server's own note states: the
        // questionnaire is validated in English, and that is why the questions
        // appear in the original wording.
        #expect(de.localizedCaseInsensitiveContains("englisch"))
        #expect(de.localizedCaseInsensitiveContains("validiert"))
        #expect(en.localizedCaseInsensitiveContains("english"))
        #expect(en.localizedCaseInsensitiveContains("validated"))
    }

    @Test("The note shows exactly where the wording is unvalidated, and nowhere else")
    func noteIsGatedOnTheUnvalidatedLocale() {
        let sci = MentalHealthInstrument.sci
        #expect(sci.validatedItemLocales == ["en"])
        #expect(sci.hasValidatedItems(locale: "en"))
        #expect(sci.hasValidatedItems(locale: "en-GB"))
        #expect(!sci.hasValidatedItems(locale: "de"))
        #expect(!sci.hasValidatedItems(locale: "de_DE"))
        // The instruments with validated German wording never show the note.
        for instrument in [MentalHealthInstrument.phq9, .gad7, .who5] {
            #expect(instrument.hasValidatedItems(locale: "de-DE"))
        }
    }

    @Test("The framing around the instrument IS localised — title, description, bands, follow-up hint")
    func framingIsLocalised() throws {
        let catalog = try ParityCatalog.load()
        let framingKeys = [
            "mentalHealth.instrument.sci",
            "mentalHealth.instrumentSub.sci",
            "mentalHealth.instrumentDescription.sci",
            "mentalHealth.followUpHint.sci",
            "mentalHealth.band.SCI.belowThreshold",
            "mentalHealth.band.SCI.aboveThreshold"
        ]
        for key in framingKeys {
            let entry = try #require(catalog.strings[key], "missing catalog entry \(key)")
            let de = try #require(ParityCatalog.value(entry, language: "de"), "\(key) has no de value")
            let en = try #require(ParityCatalog.value(entry, language: "en"), "\(key) has no en value")
            #expect(de != en, "\(key) is framing, not instrument wording — it must be translated")
        }
    }

    @Test("Every SCI response option exists for all four anchor scales, 0–4, in both languages")
    func allResponseOptionsArePresent() throws {
        let catalog = try ParityCatalog.load()
        let groups = try #require(MentalHealthInstrument.sci.optionGroups)
        for group in Set(groups) {
            for value in 0 ... MentalHealthInstrument.sci.itemMax {
                let key = "mentalHealth.sciOptions.\(group).\(value)"
                let entry = try #require(catalog.strings[key], "missing catalog entry \(key)")
                for language in ["de", "en"] {
                    #expect(
                        ParityCatalog.value(entry, language: language)?.isEmpty == false,
                        "\(key) has no \(language) value"
                    )
                }
            }
        }
    }

    // MARK: - No client-side threshold in the presentation layer

    @Test("The SCI item wording lives ONLY in the catalog — no Swift source carries it")
    func itemWordingIsNotHardcodedInSource() throws {
        let catalog = try ParityCatalog.load()
        let wording = try Self.itemKeys.map { key -> String in
            let entry = try #require(catalog.strings[key])
            return try #require(ParityCatalog.value(entry, language: "en"))
        }
        for source in try Self.mentalHealthSources() {
            let text = try String(contentsOf: source, encoding: .utf8)
            for phrase in wording {
                #expect(
                    !text.contains(phrase),
                    "\(source.lastPathComponent) hardcodes SCI wording — it belongs in Localizable.xcstrings"
                )
            }
        }
    }

    @Test("No mental-health screen re-derives a threshold — the view only reads the resolved flag")
    func screensCarryNoThresholdArithmetic() throws {
        for source in try Self.mentalHealthScreenSources() {
            let code = try Self.strippingComments(String(contentsOf: source, encoding: .utf8))
            #expect(
                !code.contains("actionThreshold"),
                "\(source.lastPathComponent) reaches for a threshold; the view must render showConsiderProfessional only"
            )
            #expect(
                !code.contains("needsFollowUp"),
                "\(source.lastPathComponent) re-evaluates the follow-up rule instead of rendering the resolved flag"
            )
        }
    }

    // MARK: - Source helpers

    private static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // MentalHealth
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // <repo>
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    private static func mentalHealthScreenSources() throws -> [URL] {
        let dir = repoRoot()
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("Screens")
            .appendingPathComponent("MentalHealth")
        let files = try swiftFiles(under: dir)
        #expect(!files.isEmpty, "expected the mental-health screen sources to be discoverable")
        return files
    }

    private static func mentalHealthSources() throws -> [URL] {
        let root = repoRoot().appendingPathComponent("HealthLog")
        return try mentalHealthScreenSources() + swiftFiles(
            under: root.appendingPathComponent("Models").appendingPathComponent("MentalHealth")
        ) + [root.appendingPathComponent("Stores").appendingPathComponent("MentalHealthStore.swift")]
    }

    /// Drops `//` line comments so a doc comment mentioning a symbol does not
    /// trip the source guards above (the guards are about executable code).
    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[line.startIndex ..< range.lowerBound]
            }
            .joined(separator: "\n")
    }
}

/// Captures the method / path / `Idempotency-Key` / body of the last stubbed
/// request. `httpBody` is nil for `URLSession` stream uploads, so the body is
/// read back from `httpBodyStream`.
private final class SciRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _method: String?
    private var _path: String?
    private var _key: String?
    private var _body: Data?

    /// Records the SUBMIT only. A successful `MentalHealthStore.submit()`
    /// refreshes the history right after the 201, so a probe that captured every
    /// request would report that trailing GET instead of the POST under test.
    func capture(_ req: URLRequest) {
        guard req.httpMethod == "POST" else { return }
        lock.lock()
        defer { lock.unlock() }
        _method = req.httpMethod
        _path = req.url?.path
        _key = req.value(forHTTPHeaderField: "Idempotency-Key")
        if let body = req.httpBody {
            _body = body
        } else if let stream = req.httpBodyStream {
            _body = Self.drain(stream)
        }
    }

    var method: String? {
        lock.lock()
        defer { lock.unlock() }
        return _method
    }

    var path: String? {
        lock.lock()
        defer { lock.unlock() }
        return _path
    }

    var idempotencyKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return _key
    }

    func bodyJSON() throws -> [String: Any] {
        lock.lock()
        let data = _body
        lock.unlock()
        guard let data, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
