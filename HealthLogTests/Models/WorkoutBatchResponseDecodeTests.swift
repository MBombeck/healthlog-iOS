import Foundation
@testable import HealthLog
import Testing

/// **GH #86** — pins the forward-compatible decode of the per-entry batch
/// response.
///
/// The reason this file exists: `enriched` does NOT exist on the server the day
/// this client ships. The status roster is explicitly additive, and we have
/// twice paid for modelling an additive server enum as a Swift `enum` — the
/// first unknown value throws `dataCorrupted` and takes the whole response
/// down, so a purely additive server change reads as a client outage. These
/// tests lock the opposite behaviour: an unknown status is data, not an error.
@Suite("Workouts — batch response decode (GH #86)")
struct WorkoutBatchResponseDecodeTests {
    private func decode(_ json: String) throws -> WorkoutBatchResponseDTO {
        try JSONDecoder().decode(WorkoutBatchResponseDTO.self, from: Data(json.utf8))
    }

    @Test("decodes the sums plus the per-entry array, incl. the new `enriched` status")
    func decodesEntries() throws {
        let dto = try decode(#"""
        {"processed":3,"inserted":1,"duplicates":2,
         "entries":[{"index":0,"status":"inserted"},
                    {"index":1,"status":"duplicate"},
                    {"index":2,"status":"enriched"}]}
        """#)
        #expect(dto.processed == 3)
        #expect(dto.inserted == 1)
        #expect(dto.duplicates == 2)
        #expect(dto.entries.count == 3)
        #expect(dto.entries[0].status == .inserted)
        #expect(dto.entries[1].status == .duplicate)
        #expect(dto.entries[2].status == .enriched)
        #expect(dto.entries[2].index == 2)
    }

    @Test("an UNKNOWN status value decodes as data — it never fails the response")
    func unknownStatusSurvives() throws {
        // The server may add statuses at any time (that is the whole point of
        // the additive contract). A future `deferred` must arrive as an
        // unrecognised value, next to the entries we DO understand.
        let dto = try decode(#"""
        {"processed":2,"inserted":0,"duplicates":1,
         "entries":[{"index":0,"status":"duplicate"},
                    {"index":1,"status":"deferred","reason":"queued"}]}
        """#)
        #expect(dto.entries.count == 2)
        #expect(dto.entries[1].status.rawValue == "deferred")
        #expect(dto.entries[1].reason == "queued")
        // Crucially: it matches NONE of the known cases and still decoded.
        #expect(dto.entries[1].status != .inserted)
        #expect(dto.entries[1].status != .duplicate)
        #expect(dto.entries[1].status != .skipped)
        #expect(dto.entries[1].status != .enriched)
    }

    @Test("a response WITHOUT the entries array still decodes (older server)")
    func missingEntriesDecodes() throws {
        let dto = try decode(#"{"processed":1,"inserted":1,"duplicates":0}"#)
        #expect(dto.processed == 1)
        #expect(dto.entries.isEmpty)
    }

    @Test("a malformed entries array degrades to empty — the sums stay usable")
    func malformedEntriesDegrade() throws {
        let dto = try decode(#"""
        {"processed":1,"inserted":0,"duplicates":1,"entries":"not-an-array"}
        """#)
        #expect(dto.duplicates == 1)
        #expect(dto.entries.isEmpty)
    }

    @Test("unknown top-level keys (skipped array, future fields) are ignored")
    func unknownTopLevelKeysIgnored() throws {
        let dto = try decode(#"""
        {"processed":1,"inserted":0,"duplicates":0,
         "skipped":[{"index":0,"reason":"bad"}],
         "someFutureField":{"a":1},
         "entries":[{"index":0,"status":"skipped","reason":"bad"}]}
        """#)
        #expect(dto.entries.first?.status == .skipped)
        #expect(dto.entries.first?.reason == "bad")
    }
}
