import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the wire-form for `POST /api/measurements/batch`. Server-Side-Schema
/// (`08-locked-contracts.md §2.1`) is authoritative — any drift bricht jeden
/// HK-Upload mit 422.
@Suite("HealthKitBatchEntryDTO wire-form")
struct HealthKitBatchDTOTests {
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test("Quantity entry encodes all required fields + omits optionals when absent")
    func quantityEntryEncoding() throws {
        let entry = HealthKitBatchEntryDTO(
            hkIdentifier: "HKQuantityTypeIdentifierBodyMass",
            value: 78.2,
            unit: "kg",
            startDate: Date(timeIntervalSince1970: 1_715_673_600),
            endDate: Date(timeIntervalSince1970: 1_715_673_600),
            externalId: "1F2A3B4C-5D6E-7F8A-9B0C-1D2E3F4A5B6C",
            deviceType: .scale
        )
        let data = try Self.encoder().encode(entry)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"hkIdentifier\":\"HKQuantityTypeIdentifierBodyMass\""))
        #expect(json.contains("\"value\":78.2"))
        #expect(json.contains("\"unit\":\"kg\""))
        #expect(json.contains("\"externalId\":\"1F2A3B4C-5D6E-7F8A-9B0C-1D2E3F4A5B6C\""))
        #expect(json.contains("\"deviceType\":\"scale\""))
        // Optional fields absent when nil — server schema is strict (no .passthrough)
        // but optional keys may simply be missing.
        #expect(!json.contains("\"sleepStage\""))
        #expect(!json.contains("\"externalSourceVersion\""))
    }

    @Test("Sleep entry includes sleepStage integer 0..20")
    func sleepEntryEncoding() throws {
        let entry = HealthKitBatchEntryDTO(
            hkIdentifier: "HKCategoryTypeIdentifierSleepAnalysis",
            value: 90.0,
            unit: "min",
            startDate: Date(timeIntervalSince1970: 1_715_673_600),
            endDate: Date(timeIntervalSince1970: 1_715_679_000),
            sleepStage: 5,
            externalId: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            deviceType: .watch
        )
        let data = try Self.encoder().encode(entry)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"sleepStage\":5"))
        #expect(json.contains("\"deviceType\":\"watch\""))
    }

    @Test("Batch payload wraps entries in `entries` array")
    func payloadEnvelope() throws {
        let payload = HealthKitBatchPayload(entries: [
            .init(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                value: 8420, unit: "count",
                startDate: Date(timeIntervalSince1970: 1_715_673_600),
                endDate: Date(timeIntervalSince1970: 1_715_716_800),
                externalId: "id-a"
            )
        ])
        let data = try Self.encoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"entries\":["))
        #expect(json.contains("\"hkIdentifier\":\"HKQuantityTypeIdentifierStepCount\""))
    }

    @Test("DeviceType enum round-trips all locked wire values")
    func deviceTypeRoundTrip() throws {
        for value in HealthKitDeviceType.allCases {
            let data = try JSONEncoder().encode(value)
            let raw = try #require(String(data: data, encoding: .utf8))
            #expect(raw == "\"\(value.rawValue)\"")
            let decoded = try JSONDecoder().decode(HealthKitDeviceType.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test("EntryStatus decodes inserted | duplicate | skipped")
    func entryStatusDecoding() throws {
        for raw in ["inserted", "duplicate", "skipped"] {
            let data = Data("\"\(raw)\"".utf8)
            let status = try JSONDecoder().decode(HealthKitEntryStatus.self, from: data)
            #expect(status.rawValue == raw)
        }
    }

    @Test("Response envelope decodes server's mixed-status payload")
    func batchResponseDecoding() throws {
        let json = """
        {
          "processed": 3,
          "inserted": 1,
          "duplicates": 1,
          "skipped": [{"index": 2, "reason": "unmappable_identifier"}],
          "entries": [
            {"index": 0, "status": "inserted"},
            {"index": 1, "status": "duplicate"},
            {"index": 2, "status": "skipped", "reason": "unmappable_identifier"}
          ]
        }
        """
        let response = try Self.decoder().decode(HealthKitBatchResponseDTO.self, from: Data(json.utf8))
        #expect(response.processed == 3)
        #expect(response.inserted == 1)
        #expect(response.duplicates == 1)
        #expect(response.skipped.count == 1)
        #expect(response.skipped[0].index == 2)
        #expect(response.skipped[0].reason == "unmappable_identifier")
        #expect(response.entries.count == 3)
        #expect(response.entries[0].status == .inserted)
        #expect(response.entries[1].status == .duplicate)
        #expect(response.entries[2].status == .skipped)
        #expect(response.entries[2].reason == "unmappable_identifier")
    }
}
