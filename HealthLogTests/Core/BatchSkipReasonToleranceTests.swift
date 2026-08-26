import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **CU-21 (4) — Skip-Reason-Toleranz der Batch-Response.**
///
/// Der Server weist seit v1.32.37 instabile `externalId`s ab; auf den
/// Batch-Routen kommt das als per-Entry `skipped` mit
/// `reason: "unstable_external_id"` zurück, während der Rest des Batches landet.
/// Zwei Dinge dürfen dabei NICHT passieren:
///
/// 1. der Batch als Ganzes scheitert (harte Decodierung an einem unbekannten
///    Wort), und
/// 2. der Eintrag läuft in eine Endlos-Wiederholung — der Grund ist
///    deterministisch, ein Retry wäre sinnlos.
///
/// Echter `APIClient` über `MockURLProtocol`, damit die Zusicherung am echten
/// Decoding-Pfad hängt und nicht an einem handgebauten `JSONDecoder`.
@Suite("CU-21 — Skip-Reason-Toleranz der Batch-Response", .serialized)
struct BatchSkipReasonToleranceTests {
    private static let env = AppEnvironment(
        baseURL: URL(string: "https://test.healthlog.local")!,
        bundleID: "dev.healthlog.app",
        appVersion: "0.1.0",
        buildNumber: "1"
    )

    private func makeUploader() -> MeasurementBatchUploader {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
        return MeasurementBatchUploader(
            api: api,
            throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0),
            syncTrigger: SyncTriggerContext()
        )
    }

    private static func entries(_ count: Int) -> [HealthKitBatchEntryDTO] {
        (0 ..< count).map { idx in
            .init(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                value: Double(idx),
                unit: "count",
                startDate: Date(timeIntervalSince1970: TimeInterval(idx)),
                endDate: Date(timeIntervalSince1970: TimeInterval(idx + 60)),
                externalId: "ext-\(idx)"
            )
        }
    }

    private func respond(_ json: String) {
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }

    // MARK: - Der Rest des Batches landet

    @Test("`unstable_external_id` scheitert nicht den ganzen Batch — der Rest landet")
    func unstableExternalIdKeepsTheRest() async throws {
        respond("""
        {"processed":3,"inserted":2,"duplicates":0,
         "skipped":[{"index":1,"reason":"unstable_external_id"}],
         "entries":[{"index":0,"status":"inserted"},
                    {"index":1,"status":"skipped","reason":"unstable_external_id"},
                    {"index":2,"status":"inserted"}]}
        """)
        let uploader = makeUploader()

        let outcomes = try await uploader.upload(Self.entries(3))

        let outcome = try #require(outcomes.first)
        #expect(outcome.response.inserted == 2)
        #expect(outcome.skipped.map(\.reason) == ["unstable_external_id"])
        // Die zwei akzeptierten Einträge sind da — der Skip hat sie nicht
        // mitgerissen.
        #expect(outcome.successfulExternalIds.contains("ext-0"))
        #expect(outcome.successfulExternalIds.contains("ext-2"))
    }

    @Test("Der übersprungene Eintrag ist cursor-advance-fähig — keine Endlos-Wiederholung")
    func skippedEntryAdvancesTheCursor() async throws {
        respond("""
        {"processed":3,"inserted":2,"duplicates":0,
         "skipped":[{"index":1,"reason":"unstable_external_id"}],
         "entries":[{"index":0,"status":"inserted"},
                    {"index":1,"status":"skipped","reason":"unstable_external_id"},
                    {"index":2,"status":"inserted"}]}
        """)
        let uploader = makeUploader()

        let outcome = try #require(try await uploader.upload(Self.entries(3)).first)

        #expect(outcome.consumedIndexes.sorted() == [0, 1, 2])
        #expect(outcome.successfulExternalIds.sorted() == ["ext-0", "ext-1", "ext-2"])
    }

    @Test("Auch wenn der Server den Skip NUR in `skipped[]` führt, advanced der Cursor")
    func skipOnlyInSkippedArrayStillAdvances() async throws {
        // Defensiv: ohne die Vereinigung aus `entries[]` und `skipped[]` bliebe
        // Index 1 ewig unverbraucht und derselbe Eintrag ginge bei jedem Wake
        // erneut raus — bei einem deterministischen Grund eine Endlosschleife.
        respond("""
        {"processed":3,"inserted":2,"duplicates":0,
         "skipped":[{"index":1,"reason":"unstable_external_id"}],
         "entries":[{"index":0,"status":"inserted"},{"index":2,"status":"inserted"}]}
        """)
        let uploader = makeUploader()

        let outcome = try #require(try await uploader.upload(Self.entries(3)).first)

        #expect(outcome.consumedIndexes.sorted() == [0, 1, 2])
    }

    // MARK: - Toleranz

    @Test("Ein völlig unbekannter Skip-Grund dekodiert als String — verbraucht aber keinen Anchor")
    func unknownReasonDecodesButFailsAcceptance() async throws {
        // **Phase 07 / 07-04 — Restatement.** Bis 07-04 verbrauchte JEDER
        // `skipped`-Index den Cursor, egal mit welchem Grund. Die eine Hälfte
        // dieser Zusicherung bleibt und ist der eigentliche Punkt der Suite: ein
        // unbekannter Grund dekodiert als String und kippt die Antwort nicht.
        // Die andere Hälfte kehrt sich um. `skipped` ist ab jetzt nur noch mit
        // einem Grund aus der dokumentierten Allowlist
        // (`MeasurementBatchAcceptance.Policy.deployedMeasurementRoute`) terminal:
        // "der Server hat den Eintrag nicht geschrieben und sagt nicht warum" ist
        // kein Beleg dafür, dass ein Retry sinnlos wäre.
        let json = """
        {"processed":1,"inserted":0,"duplicates":0,
         "skipped":[{"index":0,"reason":"a_reason_this_build_has_never_heard_of"}],
         "entries":[{"index":0,"status":"skipped","reason":"a_reason_this_build_has_never_heard_of"}]}
        """
        respond(json)
        let uploader = makeUploader()

        // Toleranz: das Decoding hält, der Grund kommt unverändert durch.
        let decoded = try JSONDecoder().decode(HealthKitBatchResponseDTO.self, from: Data(json.utf8))
        #expect(decoded.skipped.first?.reason == "a_reason_this_build_has_never_heard_of")
        #expect(decoded.entries.first?.status == .skipped)

        // Akzeptanz: nicht allowlistet ⟹ der Index hält.
        await #expect(throws: MeasurementBatchAcceptanceError.self) {
            _ = try await uploader.upload(Self.entries(1))
        }
    }

    @Test("Ein unbekanntes Statuswort dekodiert tolerant, verbraucht aber keinen Anchor")
    func unknownStatusDecodesButFailsAcceptance() async throws {
        let json = """
        {"processed":2,"inserted":1,"duplicates":0,"skipped":[],
         "entries":[{"index":0,"status":"inserted"},{"index":1,"status":"quarantined"}]}
        """
        respond(json)
        let uploader = makeUploader()

        let decoded = try JSONDecoder().decode(HealthKitBatchResponseDTO.self, from: Data(json.utf8))
        #expect(decoded.entries.map(\.status) == [.inserted, .unknown])

        await #expect(throws: MeasurementBatchAcceptanceError.self) {
            _ = try await uploader.upload(Self.entries(2))
        }
    }

    @Test("Fehlende Zählerfelder / Arrays kippen die Antwort nicht")
    func missingFieldsAreTolerated() async throws {
        respond(#"{"entries":[{"index":0,"status":"inserted"}]}"#)
        let uploader = makeUploader()

        let outcome = try #require(try await uploader.upload(Self.entries(1)).first)

        #expect(outcome.response.processed == 0)
        #expect(outcome.response.skipped.isEmpty)
        #expect(outcome.consumedIndexes == [0])
    }

    @Test("Ein Skip ohne `reason` bekommt einen Platzhalter statt einen Decoding-Fehler — und hält")
    func skipWithoutReason() async throws {
        // **Phase 07 / 07-04 — Restatement.** Der Platzhalter bleibt (kein
        // Decoding-Fehler), aber er ist kein Grund: ein grundloser Skip ist per
        // Konstruktion nicht allowlistet und hält damit den Cursor.
        let json = """
        {"processed":1,"inserted":0,"duplicates":0,
         "skipped":[{"index":0}],"entries":[{"index":0,"status":"skipped"}]}
        """
        respond(json)
        let uploader = makeUploader()

        let decoded = try JSONDecoder().decode(HealthKitBatchResponseDTO.self, from: Data(json.utf8))
        #expect(decoded.skipped.first?.reason == "unknown")

        await #expect(throws: MeasurementBatchAcceptanceError.self) {
            _ = try await uploader.upload(Self.entries(1))
        }
    }

    @Test("`unstable_external_id` ist als terminaler Grund benannt, nicht als transienter")
    func reasonIsClassifiedTerminal() {
        // `unmappable_identifier` ist der EINZIGE Grund, der den Anchor hält
        // (siehe `HealthKitService.uploadAndDecide`). Der neue Grund gehört
        // ausdrücklich nicht dazu.
        #expect(HealthKitServerSupportConfig.reasonUnstableExternalId == "unstable_external_id")
        #expect(
            HealthKitServerSupportConfig.reasonUnstableExternalId
                != HealthKitServerSupportConfig.reasonUnmappableIdentifier
        )
    }
}

// swiftlint:enable force_unwrapping
