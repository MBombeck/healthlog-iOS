import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks `GET /api/meta/capabilities` against the **new** contract
/// (CU-01 / server v1.34.2, brief block A4):
///
/// - `fhir.readScope` (String) is gone → `fhir.scopeMintable: Bool`
/// - the share descriptor lost `sections` + `resourceTypes`
/// - it gained four required keys: `reportDownload`, `selectionVersion`,
///   `groups`, `leaves`
///
/// The route had **no iOS consumer at all** before CU-01, so there is no legacy
/// behaviour to preserve — only the new shape to pin, plus proof that neither
/// the absence of the removed keys nor the presence of a stale server's keys
/// breaks the decode.
///
/// `.serialized` because every case installs the process-global
/// ``MockURLProtocol/handler``.
@Suite("ServerCapabilitiesRepository — /api/meta/capabilities contract", .serialized)
struct ServerCapabilitiesRepositoryTests {
    private func makeRepo() -> ServerCapabilitiesRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return ServerCapabilitiesRepository(
            api: APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        )
    }

    private func respond(_ json: String, capturing path: @escaping @Sendable (String) -> Void = { _ in }) {
        MockURLProtocol.handler = { req in
            path(req.url?.path ?? "")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }
    }

    /// The current server response, trimmed to one entry per list. The leaf +
    /// group vocabularies here are FIXTURE data standing in for what the live
    /// server serves — the app carries no copy of them.
    private static let currentContract = #"""
    {"data":{
      "apiContractVersion":"1.34.2",
      "derivedMetricIds":["HEALTH_SCORE","SAME_TIME_BASELINE"],
      "vitalsBaselineTypes":["HEART_RATE"],
      "layoutTileIds":["trends"],
      "metricStatusIds":["bp"],
      "ingest":{
        "quantityTypes":[{"type":"WEIGHT","hk":"HKQuantityTypeIdentifierBodyMass","unit":"kg"}],
        "eventTypes":["IRREGULAR_RHYTHM"],
        "computedScores":["RECOVERY_SCORE"],
        "writeAllowlist":["APPLE_HEALTH","MANUAL"]
      },
      "fhir":{
        "atcSystem":"http://www.whocc.no/atc",
        "snomedRoute":"http://snomed.info/sct",
        "germanAtcDefaultLocales":["de"],
        "restBaseUrl":"/api/fhir",
        "scopeMintable":false,
        "resourceTypes":["Patient","Observation"],
        "operations":["Patient/$everything"],
        "searchParams":["_count","_offset"]
      },
      "share":{
        "supported":true,
        "maxDays":90,
        "reportDownload":["fhir","pdf"],
        "selectionVersion":2,
        "groups":["identity","vitals","sensitive"],
        "leaves":["PATIENT_IDENTITY","WEIGHT","MOOD","CYCLE"]
      }
    },"error":null}
    """#

    @Test("decodes the new contract end to end")
    func decodesNewContract() async throws {
        let repo = makeRepo()
        nonisolated(unsafe) var seenPath = ""
        respond(Self.currentContract) { seenPath = $0 }

        let caps = try await repo.fetch()

        #expect(seenPath == "/api/meta/capabilities")
        #expect(caps.apiContractVersion == "1.34.2")
        #expect(caps.derivedMetricIds.contains("SAME_TIME_BASELINE"))
        #expect(caps.ingest.quantityTypes.first?.hk == "HKQuantityTypeIdentifierBodyMass")
        #expect(caps.ingest.writeAllowlist == ["APPLE_HEALTH", "MANUAL"])
        #expect(caps.fhir.operations == ["Patient/$everything"])
    }

    @Test("fhir.scopeMintable replaces the removed readScope string")
    func fhirScopeMintable() async throws {
        let repo = makeRepo()
        respond(Self.currentContract)
        let caps = try await repo.fetch()
        // The Bool exists and is honoured…
        #expect(caps.fhir.scopeMintable == false)
        // …and the FHIR REST face descriptor around it is intact (its own
        // `resourceTypes` is NOT the one that was removed — that was the share
        // descriptor's).
        #expect(caps.fhir.resourceTypes == ["Patient", "Observation"])
        #expect(caps.fhir.restBaseUrl == "/api/fhir")
    }

    @Test("the four new required share keys decode")
    func shareSelectionVocabulary() async throws {
        let repo = makeRepo()
        respond(Self.currentContract)
        let share = try await repo.fetch().share

        #expect(share.supported)
        #expect(share.maxDays == 90)
        #expect(share.reportDownload == ["fhir", "pdf"])
        #expect(share.selectionVersion == ReportSelection.currentVersion)
        #expect(share.groups == ["identity", "vitals", "sensitive"])
        #expect(share.leaves == ["PATIENT_IDENTITY", "WEIGHT", "MOOD", "CYCLE"])
        #expect(share.hasSelectionVocabulary)
        #expect(share.leafVocabulary == ["PATIENT_IDENTITY", "WEIGHT", "MOOD", "CYCLE"])
    }

    @Test("v1.37.3 object groups preserve server-owned leaves and sensitivity")
    func currentObjectGroupsDecodeFromPinnedFixture() throws {
        let data = try Self.loadPinnedFixture()
        let envelope = try JSONDecoder.hlDefault.decode(APIEnvelope<ServerCapabilities>.self, from: data)
        let share = try #require(envelope.data?.share)

        #expect(share.groups == ["vitals", "sensitive"])
        #expect(share.groupDescriptors.map(\.id) == ["vitals", "sensitive"])
        #expect(share.groupDescriptors[0].leaves == ["BLOOD_PRESSURE_SYS", "PULSE"])
        #expect(share.groupDescriptors[0].declaredSensitive == nil)
        #expect(share.groupDescriptors[0].isSensitive, "missing sensitivity must fail closed")
        #expect(share.groupDescriptors[1].declaredSensitive == true)
        #expect(share.groupDescriptors[1].isSensitive)
    }

    @Test("legacy string groups remain compatible and fail closed on sensitivity")
    func legacyStringGroupsRemainCompatible() throws {
        let capabilities = try JSONDecoder.hlDefault.decode(ServerCapabilities.self, from: Data(#"""
        {"share":{"selectionVersion":2,"groups":["vitals","sensitive"],"leaves":["PULSE","MOOD"]}}
        """#.utf8))

        #expect(capabilities.share.groups == ["vitals", "sensitive"])
        #expect(capabilities.share.groupDescriptors.map(\.leaves) == [[], []])
        // swiftformat:disable:next preferKeyPath
        #expect(capabilities.share.groupDescriptors.allSatisfy { $0.isSensitive })
    }

    @Test("one malformed additive group cannot discard valid groups or sibling capabilities")
    func malformedNestedGroupIsIsolated() throws {
        let capabilities = try JSONDecoder.hlDefault.decode(ServerCapabilities.self, from: Data(#"""
        {
          "apiContractVersion":"1.37.4",
          "fhir":{"scopeMintable":"future-value"},
          "share":{
            "selectionVersion":2,
            "groups":[
              {"id":"vitals","leaves":["PULSE"],"sensitive":false},
              {"id":17,"leaves":"future-shape"},
              {"id":"future","leaves":["FUTURE"],"sensitive":"restricted"}
            ],
            "leaves":["PULSE","FUTURE"]
          }
        }
        """#.utf8))

        #expect(capabilities.apiContractVersion == "1.37.4")
        #expect(capabilities.fhir.scopeMintable == false)
        #expect(capabilities.share.groups == ["vitals", "future"])
        #expect(capabilities.share.groupDescriptors[0].isSensitive == false)
        #expect(capabilities.share.groupDescriptors[1].isSensitive, "unknown semantics must fail closed")
        #expect(capabilities.share.leaves == ["PULSE", "FUTURE"])
    }

    @Test("the live vocabulary is what validates a selection — no app-side list")
    func vocabularyDrivesSelectionValidation() async throws {
        let repo = makeRepo()
        respond(Self.currentContract)
        let vocabulary = try await repo.fetch().share.leafVocabulary

        #expect(ReportSelection(leaves: ["WEIGHT", "MOOD"]).isValid(against: vocabulary))
        #expect(
            ReportSelection(leaves: ["LAB_RESULTS"]).validate(against: vocabulary)
                == [.unknownLeaves(["LAB_RESULTS"])],
            "LAB_RESULTS is a real server leaf, absent from THIS response: trust the response"
        )
    }

    @Test("absence of the removed fields breaks nothing")
    func removedFieldsAbsenceIsFine() async throws {
        // Exactly the current contract: no `fhir.readScope`, no `share.sections`,
        // no `share.resourceTypes`. Already covered above — this case additionally
        // strips every key the server marks required but that CU-01 does not need,
        // proving the decode is tolerant rather than shape-locked.
        let repo = makeRepo()
        respond(#"""
        {"data":{"share":{"selectionVersion":2,"leaves":["WEIGHT"],"groups":["vitals"],
        "reportDownload":["pdf"]}},"error":null}
        """#)
        let caps = try await repo.fetch()

        #expect(caps.share.leaves == ["WEIGHT"])
        #expect(caps.share.hasSelectionVocabulary)
        // Everything the response omitted resolves to an honest empty/false —
        // never a fabricated default.
        #expect(caps.apiContractVersion.isEmpty)
        #expect(caps.fhir.scopeMintable == false)
        #expect(caps.fhir.resourceTypes.isEmpty)
        #expect(caps.ingest.quantityTypes.isEmpty)
        #expect(caps.share.supported == false)
    }

    @Test("a stale server still carrying readScope / sections / resourceTypes decodes")
    func legacyExtraFieldsAreIgnored() async throws {
        let repo = makeRepo()
        respond(#"""
        {"data":{
          "apiContractVersion":"1.32.8",
          "fhir":{"readScope":"fhir:read","atcSystem":"http://www.whocc.no/atc",
                  "resourceTypes":["Patient"]},
          "share":{"supported":true,"maxDays":90,"sections":["vitals"],
                   "resourceTypes":["Observation"]}
        },"error":null}
        """#)
        let caps = try await repo.fetch()

        #expect(caps.apiContractVersion == "1.32.8")
        #expect(caps.fhir.scopeMintable == false, "no scopeMintable on the wire → honest false")
        #expect(caps.fhir.atcSystem == "http://www.whocc.no/atc")
        // The old server serves no selection vocabulary — the caller must see
        // that and refuse to offer a selection UI, not invent one.
        #expect(caps.share.leaves.isEmpty)
        #expect(caps.share.selectionVersion == 0)
        #expect(caps.share.hasSelectionVocabulary == false)
    }

    @Test("a server speaking a different selection grammar is not treated as usable")
    func mismatchedSelectionVersionIsNotUsable() async throws {
        let repo = makeRepo()
        respond(#"""
        {"data":{"share":{"selectionVersion":3,"leaves":["WEIGHT"],"groups":[],
        "reportDownload":[]}},"error":null}
        """#)
        #expect(try await repo.fetch().share.hasSelectionVocabulary == false)
    }

    @Test("the brief's `shareLinks` spelling is tolerated as an alias for `share`")
    func shareLinksAliasDecodes() async throws {
        // The catch-up brief names the descriptor `capabilities.shareLinks`; the
        // route and the OpenAPI schema both emit `share`. We accept either so a
        // rename on the server cannot strand the decoder.
        let repo = makeRepo()
        respond(#"""
        {"data":{"shareLinks":{"supported":true,"maxDays":30,"reportDownload":["pdf"],
        "selectionVersion":2,"groups":["vitals"],"leaves":["WEIGHT"]}},"error":null}
        """#)
        let share = try await repo.fetch().share
        #expect(share.maxDays == 30)
        #expect(share.leaves == ["WEIGHT"])
    }

    private static func loadPinnedFixture(file: String = #filePath) throws -> Data {
        let repoRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Repositories
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
        return try Data(contentsOf: repoRoot.appendingPathComponent(
            "HealthLogTests/Fixtures/Server/v1.37.3/capabilities.json"
        ))
    }
}

// swiftlint:enable force_unwrapping
