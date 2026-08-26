import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// CU-16 (A6) — tolerance against server enums that grew after v1.32.8.
///
/// The shared rule every suite here locks: **a value we do not know must never
/// be fatal.** Either it decodes into a typed case we added, or it lands in a
/// defined fallback that says nothing — never a thrown decode that costs the
/// row, and never an invented finding.
///
/// Each enum gets two tests: one with the real new literal, one with an
/// invented literal that the server will never send, to prove the fallback is
/// a fallback and not a lookup table with one more entry.
///
/// Deliberately NOT covered here (owned by other units so two agents never
/// touch one file): `gender` (CU-17), `SyncHealth.verdict` (CU-21),
/// health-score pillars + `deltaReason` (CU-31), derived-metric IDs +
/// `PriorityItem.kind` (CU-30), `glucoseContext` / `GlucoseContext` (CU-18).
private func makeCU16API() -> APIClient {
    let env = AppEnvironment(
        baseURL: URL(string: "https://test.healthlog.local")!,
        bundleID: "dev.healthlog.app",
        appVersion: "0.15.0",
        buildNumber: "1"
    )
    return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
}

private func respondCU16(_ json: String, status: Int = 200) {
    let body = Data(json.utf8)
    MockURLProtocol.handler = { req in
        (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
    }
}

// MARK: - Workout sportType

/// `sportType` is a raw `String?` on the wire, so decoding was never the risk —
/// the risk was a row landing on the generic fallback title/glyph forever.
@Suite("CU-16 — workout sportType grew `badminton`", .serialized)
struct CU16WorkoutSportTypeTests {
    private func makeRepo() throws -> WorkoutsRepository {
        try WorkoutsRepository(api: makeCU16API(), outbox: OutboxQueue(inMemory: true), cacheTTL: 60)
    }

    private func listJSON(sportType: String) -> String {
        """
        {"data":{
          "workouts":[{
            "id":"w-cu16","sportType":"\(sportType)",
            "startedAt":"2026-07-01T17:00:00Z","endedAt":"2026-07-01T18:00:00Z",
            "durationSec":3600,"distanceM":null,"activeEnergyKcal":540,
            "avgHr":138,"maxHr":171,"source":"APPLE_HEALTH","externalId":"hk:cu16"
          }],
          "meta":{"total":1,"limit":50,"offset":0,"droppedDuplicates":0}
        },"error":null}
        """
    }

    @Test("the new `badminton` literal decodes and renders as itself")
    func badmintonDecodesAndRenders() async throws {
        let repo = try makeRepo()
        respondCU16(listJSON(sportType: "badminton"))
        let response = try await repo.list()
        #expect(response.workouts.count == 1, "a badminton row must never be dropped")
        #expect(response.workouts[0].sportType == "badminton")

        // Before CU-16 this fell through to the capitalized raw token plus the
        // generic cardio glyph. Now it is a real title + a real sport symbol.
        #expect(WorkoutFormatter.sportTitle("badminton") == "Badminton")
        #expect(WorkoutFormatter.sportSymbol("badminton") == "figure.badminton")
        // The HK-identifier spelling normalises onto the same entry.
        #expect(WorkoutFormatter.sportSymbol("HKWorkoutActivityTypeBadminton") == "figure.badminton")
    }

    @Test("an invented sport literal decodes and degrades, it never throws")
    func unknownSportIsTolerated() async throws {
        let repo = try makeRepo()
        // Invented on purpose — the server has no such sport and never will.
        respondCU16(listJSON(sportType: "underwater_basket_weaving"))
        let response = try await repo.list()
        #expect(response.workouts.count == 1, "an unknown sport must never cost the row")
        #expect(response.workouts[0].sportType == "underwater_basket_weaving")

        // Fallback: the raw token, title-cased — the user sees the server's
        // word rather than a blank cell, and the icon degrades to generic
        // cardio. Never a throw, never an empty row.
        #expect(WorkoutFormatter.sportTitle("underwater_basket_weaving") == "Underwater_Basket_Weaving")
        #expect(WorkoutFormatter.sportSymbol("underwater_basket_weaving") == "figure.mixed.cardio")
    }
}

// MARK: - AI provider

/// `AIProvider.fromWire` returns `nil` for anything it does not know, and
/// `AIProviderConfig.resolvedProvider` folds that onto `.unconfigured`. That is
/// tolerant, but for a provider the server IS actually serving with it is also
/// a lie ("Nicht konfiguriert" over a working Coach) — hence the typed case.
@Suite("CU-16 — AI provider grew `OPENAI_COMPATIBLE`", .serialized)
struct CU16AIProviderTests {
    private func configJSON(provider: String) -> String {
        """
        {"data":{"provider":"\(provider)","model":null,"baseUrl":"https://llm.example.org/v1",
         "hasAnthropicKey":false,"anthropicKeyPreview":null,
         "hasOpenaiKey":false,"openaiKeyPreview":null,"hasLocalKey":false,
         "aiAvailable":true,"managedBy":"user"},"error":null}
        """
    }

    @Test("the new `OPENAI_COMPATIBLE` literal resolves to its own case, not to unconfigured")
    func openaiCompatibleResolves() async throws {
        let repo = AIProviderRepository(api: makeCU16API())
        respondCU16(configJSON(provider: "OPENAI_COMPATIBLE"))
        let config = try await repo.config()

        #expect(config.resolvedProvider == .openaiCompatible)
        #expect(AIProvider.fromWire("OPENAI_COMPATIBLE") == .openaiCompatible)
        #expect(AIProvider.openaiCompatible.wireValue == "OPENAI_COMPATIBLE")
        // The server selected it, so it is configured — server-side. iOS has no
        // `hasOpenaiCompatibleKey` flag, so claiming "not configured" would
        // assert a defect we cannot see.
        #expect(config.isFullyConfigured)
        // …but it stays out of the picker: there is no iOS field for an
        // operator-owned base URL + key (AC18 — no selectable stubs).
        #expect(!AIProvider.configurableCases.contains(.openaiCompatible))
        #expect(!AIProvider.openaiCompatible.supportsBaseUrl)
        // And it must not borrow OpenAI's key preview — that is a different key.
        let withOpenAIKey = AIProviderConfig(
            provider: "OPENAI_COMPATIBLE",
            hasOpenaiKey: true,
            openaiKeyPreview: "...WRONG"
        )
        #expect(withOpenAIKey.activeKeyPreview == nil)
    }

    @Test("an available future provider stays opaque without being treated as unavailable")
    func unknownProviderIsTolerated() async throws {
        let repo = AIProviderRepository(api: makeCU16API())
        // Invented on purpose.
        respondCU16(configJSON(provider: "QUANTUM_ORACLE_9000"))
        let config = try await repo.config()

        #expect(config.provider == "QUANTUM_ORACLE_9000", "the raw value survives for diagnostics")
        #expect(config.resolvedProvider == .unconfigured, "unknown → the neutral sentinel, never a crash")
        #expect(AIProvider.fromWire("QUANTUM_ORACLE_9000") == nil)
        #expect(config.aiConsentTarget == .providerOpaque)
        #expect(config.isFullyConfigured, "the server's explicit availability remains authoritative")
    }

    @Test("the picker vocabulary stays at three; both wire-only providers are excluded")
    func configurableCasesUnchanged() {
        let cases = AIProvider.configurableCases
        #expect(cases.count == 3)
        #expect(!cases.contains(.openaiCompatible))
    }
}

// MARK: - ECG / rhythm classification

/// `RhythmClassification` has SIX values in Prisma; the ECG OpenAPI publishes
/// three. `GET /api/insights/rhythm-events` passes all six through, and the
/// column is shared with the ECG rows.
@Suite("CU-16 — RhythmClassification has six values, not three", .serialized)
struct CU16EcgClassificationTests {
    private func listJSON(classification: String) -> String {
        """
        {"data":{"recordings":[
          {"id":"ecg-cu16","recordedAt":"2026-07-02T09:00:00.000Z","durationSeconds":30,
           "samplingFrequency":300,"sampleCount":9000,"averageHeartRate":64,"lead":"I",
           "classification":"\(classification)","source":"APPLE_HEALTH","hasWaveform":true}
        ],"hasRecordings":true},"error":null}
        """
    }

    @Test(
        "all six Prisma literals decode into their own case",
        arguments: [
            ("IRREGULAR", EcgClassification.irregular),
            ("NOT_DETECTED", .notDetected),
            ("INCONCLUSIVE", .inconclusive),
            ("LOW", .low),
            ("VERY_LOW", .veryLow),
            ("FIRED", .fired)
        ]
    )
    func allSixLiteralsDecode(raw: String, expected: EcgClassification) async throws {
        let repo = EcgRepository(api: makeCU16API())
        respondCU16(listJSON(classification: raw))
        let dto = try #require(try await repo.fetchList())
        #expect(dto.recordings.count == 1, "no classification may cost the recording")
        #expect(dto.recordings[0].classification == raw, "the raw literal survives verbatim")
        #expect(dto.recordings[0].verdict == expected)
    }

    @Test("an invented classification decodes into .unknown, verbatim, and is not lost")
    func unknownClassificationIsTolerated() async throws {
        let repo = EcgRepository(api: makeCU16API())
        // Invented on purpose — a literal Prisma does not have.
        respondCU16(listJSON(classification: "BIGEMINY_SUSPECTED"))
        let dto = try #require(try await repo.fetchList())
        #expect(dto.recordings.count == 1)
        #expect(dto.recordings[0].verdict == .unknown("BIGEMINY_SUSPECTED"))
        // Verbatim display — we render the device's word, never a guess at it.
        #expect(EcgPresentation.resultLabel(for: .unknown("BIGEMINY_SUSPECTED")) == "BIGEMINY_SUSPECTED")
    }

    /// The fallback that is a clinical judgement call, pinned.
    ///
    /// `LOW` / `VERY_LOW` / `FIRED` are EVENT verdicts (walking-steadiness
    /// severity, "the device raised this notification") leaking through the
    /// shared enum. None of them is a cardiac finding on the strip being shown.
    /// Routing them to "discuss this with a clinician" would be HealthLog
    /// inventing a finding the device never made — so they stay silent, exactly
    /// like an unrecognised literal. Silence claims nothing; a wrong escalation
    /// claims something false.
    @Test("only the two genuinely non-normal CARDIAC verdicts reach the clinician note")
    func clinicianNoteRoutingAcrossAllSix() {
        #expect(EcgClassification(raw: "IRREGULAR").isNonNormalDeviceResult)
        #expect(EcgClassification(raw: "INCONCLUSIVE").isNonNormalDeviceResult)
        #expect(!EcgClassification(raw: "NOT_DETECTED").isNonNormalDeviceResult)
        #expect(!EcgClassification(raw: "LOW").isNonNormalDeviceResult)
        #expect(!EcgClassification(raw: "VERY_LOW").isNonNormalDeviceResult)
        #expect(!EcgClassification(raw: "FIRED").isNonNormalDeviceResult)
        #expect(!EcgClassification(raw: nil).isNonNormalDeviceResult)
        #expect(!EcgClassification(raw: "BIGEMINY_SUSPECTED").isNonNormalDeviceResult)
    }

    @Test("the three EVENT verdicts render localized copy that asserts no rhythm finding")
    func eventVerdictCopyIsHonest() {
        for verdict in [EcgClassification.low, .veryLow, .fired] {
            let label = EcgPresentation.resultLabel(for: verdict)
            #expect(!label.isEmpty)
            // Never the raw wire token — that would be an untranslated artefact.
            #expect(!["LOW", "VERY_LOW", "FIRED"].contains(label))
            // Locale-resolved EN source or its DE translation; both spell out
            // that this is not a rhythm finding.
            #expect(
                label.contains("no rhythm finding") || label.contains("kein Rhythmusbefund"),
                "EVENT verdict copy must disclaim a rhythm finding, got: \(label)"
            )
        }
    }
}

// MARK: - Rhythm events surface

/// The same six values on the surface that actually receives all of them.
@Suite("CU-16 — rhythm-events passes all six classifications through", .serialized)
struct CU16RhythmEventsTests {
    private func eventsJSON(classification: String) -> String {
        """
        {"data":{"events":[
          {"id":"evt-cu16","type":"IRREGULAR_RHYTHM_NOTIFICATION",
           "classification":"\(classification)","occurredAt":"2026-07-03T06:15:00Z",
           "source":"APPLE_HEALTH","deviceType":"Apple Watch"}
        ],"hasEvents":true},"error":null}
        """
    }

    @Test(
        "every Prisma literal decodes and carries a verdict line",
        arguments: ["IRREGULAR", "NOT_DETECTED", "INCONCLUSIVE", "LOW", "VERY_LOW", "FIRED"]
    )
    func allSixDecodeWithCopy(raw: String) async throws {
        let repo = RhythmEventsRepository(api: makeCU16API())
        respondCU16(eventsJSON(classification: raw))
        let dto = try #require(try await repo.fetch())
        #expect(dto.events.count == 1, "no classification may cost the event row")
        #expect(dto.events[0].classification == raw)
        let verdict = InsightsRhythmEventsCard.verdictLabel(for: raw)
        #expect(verdict != nil, "\(raw) must resolve to the device-attributed copy")
        #expect(verdict?.isEmpty == false)
    }

    @Test("an invented classification keeps the row and simply carries no verdict line")
    func unknownClassificationKeepsRow() async throws {
        let repo = RhythmEventsRepository(api: makeCU16API())
        // Invented on purpose.
        respondCU16(eventsJSON(classification: "COSMIC_RAY_INTERFERENCE"))
        let dto = try #require(try await repo.fetch())
        #expect(dto.events.count == 1, "an unknown verdict must never cost the event")
        #expect(dto.events[0].classification == "COSMIC_RAY_INTERFERENCE")
        // Defined fallback: no verdict line at all. The row still shows WHAT
        // happened and WHEN; it just does not put words in the device's mouth.
        #expect(InsightsRhythmEventsCard.verdictLabel(for: "COSMIC_RAY_INTERFERENCE") == nil)
    }
}

// MARK: - Mood-tag catalogue (data rows, not an enum)

/// `caffeine` / `nicotine` are catalogue ROWS, not enum members. This suite is
/// the verification the plan asked for: the catalogue is rendered server-side
/// and nothing about a tag key is hardcoded on the client, so new rows appear
/// with no iOS release.
@Suite("CU-16 — mood-tag catalogue is server-rendered, not hardcoded", .serialized)
struct CU16MoodTagCatalogTests {
    private func catalogJSON(tagKey: String, labelKey: String, icon: String) -> String {
        """
        {"data":{"categories":[
          {"key":"substances","labelKey":"mood.tagCategory.substances","icon":"Coffee","tags":[
            {"key":"\(tagKey)","labelKey":"\(labelKey)","icon":"\(icon)"}
          ]}
        ]},"error":null}
        """
    }

    @Test(
        "brand-new catalogue rows arrive with no client change",
        arguments: [
            ("caffeine", "mood.tag.caffeine", "Coffee"),
            ("nicotine", "mood.tag.nicotine", "Cigarette")
        ]
    )
    func newCatalogueRowsArrive(tagKey: String, labelKey: String, icon: String) async throws {
        let repo = MoodTagCatalogRepository(api: makeCU16API())
        respondCU16(catalogJSON(tagKey: tagKey, labelKey: labelKey, icon: icon))
        let catalog = await repo.catalog()

        #expect(catalog.containsTag(tagKey), "a new server row must simply appear")
        let label = try #require(catalog.label(forTagKey: tagKey))
        #expect(!label.isEmpty)
        // Resolved through the catalogue, never echoed as the raw i18n key.
        #expect(label != labelKey)
    }

    @Test("an invented tag key and an invented icon both render rather than break")
    func unknownTagAndIconDegrade() async throws {
        let repo = MoodTagCatalogRepository(api: makeCU16API())
        // Both invented on purpose: a key with no `mood.tag.*` entry and an
        // icon absent from the Lucide→SF-Symbol table.
        respondCU16(catalogJSON(tagKey: "petrichor", labelKey: "mood.tag.petrichor", icon: "Wormhole"))
        let catalog = await repo.catalog()

        #expect(catalog.containsTag("petrichor"), "an unknown row must never be filtered out")
        // Defined fallback: the key's last path component, humanized — words,
        // never `mood.tag.petrichor` and never blank.
        let label = try #require(catalog.label(forTagKey: "petrichor"))
        #expect(label == "Petrichor")
        // Icon fallback is the neutral tag glyph, never a blank tile.
        let tag = try #require(catalog.categories.first?.tags.first)
        #expect(!tag.sfSymbol.isEmpty)
    }
}

// MARK: - Catalogue presence for the copy this unit added

@Suite("CU-16 — new catalogue keys resolve in DE and EN")
struct CU16LocalizationKeyTests {
    private static let addedKeys = [
        "insights.ecg.result.low",
        "insights.ecg.result.veryLow",
        "insights.ecg.result.fired",
        "insight.provider.openaiCompatible",
        "mood.tag.caffeine",
        "mood.tag.nicotine"
    ]

    @Test("every key CU-16 added resolves to real copy in both locales", arguments: addedKeys)
    func keyResolvesInBothLocales(key: String) throws {
        for language in ["de", "en"] {
            let lprojPath = try #require(
                Bundle.main.path(forResource: language, ofType: "lproj"),
                "\(language).lproj missing from the host bundle"
            )
            let table = try #require(Bundle(path: lprojPath))
            let value = table.localizedString(forKey: key, value: "MISSING", table: nil)
            #expect(value != "MISSING", "\(key) is missing from the \(language) catalogue")
            #expect(value != key, "\(key) falls back to the key itself in \(language)")
            #expect(!value.isEmpty)
        }
    }
}

// swiftlint:enable force_unwrapping
