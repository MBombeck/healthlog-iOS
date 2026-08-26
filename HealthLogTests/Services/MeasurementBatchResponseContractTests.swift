import Foundation
@testable import HealthLog
import Testing

/// Phase 07 Wave 0 — the deployed measurement-batch result contract.
///
/// The immutable `v1.37.3` baseline cannot express what the deployed server
/// (tag `v1.37.12`, revision `d21fe48`) actually returns: `updated` is a
/// terminal upsert of a `stats:<type>:<day>` row and `failed` is nonterminal.
/// The shipped client decodes both into `HealthKitEntryStatus.unknown`, so a
/// converged daily statistic looks like an unrecognised outcome and retries
/// forever while a genuine rejection is indistinguishable from it.
@Suite("Deployed measurement batch response contract")
struct MeasurementBatchResponseContractTests {
    // MARK: - Fixture access

    private static func repoRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
    }

    private static func overlay() throws -> [String: Any] {
        let url = repoRoot()
            .appendingPathComponent("HealthLogTests/Fixtures/Server/v1.37.12/measurement-batch.json")
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func provenance() throws -> [String: Any] {
        let url = repoRoot()
            .appendingPathComponent("HealthLogTests/Fixtures/Server/v1.37.12/provenance.json")
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func response(_ named: String) throws -> HealthKitBatchResponseDTO {
        let responses = try #require(overlay()["responses"] as? [String: Any])
        let document = try #require(responses[named] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: document)
        return try JSONDecoder().decode(HealthKitBatchResponseDTO.self, from: data)
    }

    private static func accepts(_ named: String, postedCount: Int) throws -> Bool {
        let decoded = try response(named)
        do {
            try MeasurementBatchAcceptance.validate(postedCount: postedCount, response: decoded)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Provenance and baseline immutability

    @Test("overlay pins the deployed release without relabelling the baseline")
    func overlayProvenanceIsPinnedAndAdditive() throws {
        let provenance = try Self.provenance()
        #expect(provenance["tag"] as? String == DeployedMeasurementContract.serverTag)
        #expect(provenance["revision"] as? String == DeployedMeasurementContract.serverRevision)
        #expect(provenance["extends"] as? String == "v1.37.3")
        #expect(provenance["supersedes"] is NSNull)

        let pinned = try #require(provenance["baselineMustRemainUnchanged"] as? [String: String])
        let baseline = Self.repoRoot().appendingPathComponent("HealthLogTests/Fixtures/Server/v1.37.3")
        let names = try FileManager.default.contentsOfDirectory(atPath: baseline.path).sorted()
        #expect(names == pinned.keys.sorted())
    }

    @Test("deployed vocabulary is exactly five statuses with one nonterminal member")
    func deployedVocabularyIsExact() throws {
        let provenance = try Self.provenance()
        let vocabulary = try #require(provenance["entryStatusVocabulary"] as? [String])
        #expect(vocabulary == DeployedMeasurementEntryStatus.allCases.map(\.rawValue))

        let nonterminal = DeployedMeasurementEntryStatus.allCases
            .filter { DeployedMeasurementContract.required(for: $0) == .nonterminal }
        #expect(nonterminal == [.failed])
    }

    @Test("baseline statuses keep their established terminal acceptance")
    func baselineStatusesStillAccept() throws {
        for name in ["inserted", "duplicate", "skipped"] {
            #expect(try Self.accepts(name, postedCount: 1), "baseline status \(name) must stay terminal")
        }
    }

    @Test("same-batch supersession names one stable stat identity")
    func supersessionUsesOneStableStatIdentity() throws {
        let request = try #require(Self.overlay()["request"] as? [String: Any])
        let entries = try #require(request["entries"] as? [[String: Any]])
        let statIdentities = entries
            .compactMap { $0["externalId"] as? String }
            .filter { $0.hasPrefix("stats:") }
        #expect(statIdentities.count == 1)
        #expect(statIdentities.first?.contains(":2026-08-14") == true)

        let superseded = try Self.response("superseded-in-batch")
        #expect(superseded.entries.map(\.index) == [0, 1])
        #expect(superseded.entries.first?.reason == DeployedMeasurementContract.supersededInBatchReason)
    }

    // MARK: - RED

    /// Every deployed status word must be classified exactly: `updated` is
    /// terminal (the stat row converged), `failed` holds the cursor, and a
    /// same-batch supersession of one stable stat id is a fully accepted batch.
    /// Today the shipped decoder cannot even name `updated` or `failed`.
    @Test("deployed statuses require explicit, exact acceptance")
    func deployedStatusesRequireExplicitAcceptance() throws {
        var violations: [String] = []

        for status in DeployedMeasurementEntryStatus.allCases {
            let classification = DeployedMeasurementContract
                .installedClientClassification(forRawStatus: status.rawValue)
            let expected = DeployedMeasurementContract.required(for: status)
            if classification == nil {
                violations.append("client cannot name deployed status \(status.rawValue)")
            } else if classification != expected {
                violations.append("client misclassifies \(status.rawValue)")
            }
        }

        if try !Self.accepts("updated", postedCount: 1) {
            violations.append("an updated stat row did not let the cursor advance")
        }
        if try Self.accepts("failed", postedCount: 1) {
            violations.append("a rejected row let the cursor advance")
        }
        if try !Self.accepts("superseded-in-batch", postedCount: 2) {
            violations.append("same-batch stat supersession did not count as complete acceptance")
        }

        #expect(
            violations.isEmpty,
            "EXPECTED_RED: deployed result vocabulary was not classified exactly"
        )
    }
}
