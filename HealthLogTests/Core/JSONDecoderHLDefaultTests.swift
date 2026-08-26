import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the unified `JSONDecoder.hlDefault` against the three date shapes
/// the server emits across v1.4.x:
/// - ISO8601 with fractional seconds
/// - ISO8601 plain (no fractional)
/// - YYYY-MM-DD day-keys (compliance + similar date-only fields)
///
/// Pre-v0.4.0, the OutboxReplayService had its own diverged decoder
/// (`.iso8601` plain + `.convertFromSnakeCase`) — a latent footgun. A4-Audit §6.
@Suite("JSONDecoder.hlDefault")
struct JSONDecoderHLDefaultTests {
    private struct DateOnly: Codable, Equatable {
        let when: Date
    }

    @Test("Decodes ISO8601 with fractional seconds")
    func decodesFractional() throws {
        let json = Data(#"{"when":"2026-05-15T10:30:00.123Z"}"#.utf8)
        let value = try JSONDecoder.hlDefault.decode(DateOnly.self, from: json)
        let calendar = Calendar(identifier: .iso8601)
        let components = try calendar.dateComponents(
            in: #require(TimeZone(identifier: "UTC")),
            from: value.when
        )
        #expect(components.year == 2026)
        #expect(components.month == 5)
        #expect(components.day == 15)
        #expect(components.hour == 10)
        #expect(components.minute == 30)
    }

    @Test("Decodes ISO8601 without fractional seconds")
    func decodesPlain() throws {
        let json = Data(#"{"when":"2026-05-15T10:30:00Z"}"#.utf8)
        let value = try JSONDecoder.hlDefault.decode(DateOnly.self, from: json)
        let components = try Calendar(identifier: .iso8601).dateComponents(
            in: #require(TimeZone(identifier: "UTC")),
            from: value.when
        )
        #expect(components.year == 2026)
        #expect(components.day == 15)
        #expect(components.hour == 10)
    }

    @Test("Decodes YYYY-MM-DD day-key as midnight UTC")
    func decodesDayKey() throws {
        let json = Data(#"{"when":"2026-05-15"}"#.utf8)
        let value = try JSONDecoder.hlDefault.decode(DateOnly.self, from: json)
        let components = try Calendar(identifier: .iso8601).dateComponents(
            in: #require(TimeZone(identifier: "UTC")),
            from: value.when
        )
        #expect(components.year == 2026)
        #expect(components.month == 5)
        #expect(components.day == 15)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
    }

    @Test("Rejects malformed date strings with a clear error")
    func rejectsGarbage() {
        let json = Data(#"{"when":"definitely-not-a-date"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.hlDefault.decode(DateOnly.self, from: json)
        }
    }

    @Test("Does NOT apply snake_case key conversion")
    func keepCamelCase() throws {
        struct CamelOnly: Codable {
            let userId: String
        }
        // Server emits camelCase already — if we converted from snake_case,
        // a snake_case key would also decode (and silently round-trip the
        // wrong field). Lock the opposite: snake_case keys do NOT decode.
        let snake = Data(#"{"user_id":"abc"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.hlDefault.decode(CamelOnly.self, from: snake)
        }
        // camelCase decodes cleanly.
        let camel = Data(#"{"userId":"abc"}"#.utf8)
        let value = try JSONDecoder.hlDefault.decode(CamelOnly.self, from: camel)
        #expect(value.userId == "abc")
    }
}
