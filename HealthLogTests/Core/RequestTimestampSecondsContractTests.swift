import Foundation
@testable import HealthLog
import Testing

/// From server v1.43 every date-time in a request body or query must
/// carry seconds (`2026-10-15T06:15Z` is refused with 422, `2026-10-15T06:15:00Z`
/// is accepted on every server version).
///
/// The audit found no path that can drop seconds; this suite pins that, so a
/// future encoder, formatter or hand-built query cannot quietly regress it.
/// The edge that matters is a time on a whole minute: a formatter that elides
/// zero seconds would still pass a test that uses `06:15:42`.
@Suite("#140 request timestamps carry seconds")
struct RequestTimestampSecondsContractTests {
    /// 2026-10-15 06:15:00 UTC, exactly on the minute.
    private static let onTheMinute = Date(timeIntervalSince1970: 1_792_044_900)
    /// 2026-10-15 06:15:00.250 UTC.
    private static let withFraction = Date(timeIntervalSince1970: 1_792_044_900.25)

    /// `HH:mm:ss` followed by an optional fraction and a zone, with nothing
    /// shorter allowed.
    private static func hasSeconds(_ value: String) -> Bool {
        value.wholeMatch(of: #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})/#) != nil
    }

    private struct Body: Codable {
        let at: Date
    }

    private static func encoded(_ date: Date, with encoder: JSONEncoder) throws -> String {
        let data = try encoder.encode(Body(at: date))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["at"] as? String)
    }

    @Test("both request encoders write seconds, also on a whole minute", arguments: ["hlDefault", "hlBatch"])
    func requestEncodersWriteSeconds(name: String) throws {
        let encoder: JSONEncoder = name == "hlDefault" ? .hlDefault : .hlBatch
        for date in [Self.onTheMinute, Self.withFraction] {
            let wire = try Self.encoded(date, with: encoder)
            #expect(Self.hasSeconds(wire), "\(name) wrote \(wire)")
        }
        #expect(try Self.encoded(Self.onTheMinute, with: encoder) == "2026-10-15T06:15:00Z")
    }

    @Test("every APIRequest body builder defaults to the shared encoder")
    func requestBuildersWriteSeconds() throws {
        let requests: [APIRequest<EmptyPayload>] = try [
            .post("/x", body: Body(at: Self.onTheMinute)),
            .put("/x", body: Body(at: Self.onTheMinute)),
            .patch("/x", body: Body(at: Self.onTheMinute))
        ]
        for request in requests {
            let body = try #require(request.body)
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["at"] as? String == "2026-10-15T06:15:00Z")
        }
    }

    @Test("the shared formatters behind hand-built queries write seconds")
    func queryFormattersWriteSeconds() {
        let formatted = [
            ISO8601DateFormatter.plain.string(from: Self.onTheMinute),
            ISO8601DateFormatter.fractional.string(from: Self.onTheMinute),
            // `MedicationTherapyLogRepository` and the offline placeholders use a
            // default-configured formatter.
            ISO8601DateFormatter().string(from: Self.onTheMinute)
        ]
        for value in formatted {
            #expect(Self.hasSeconds(value), "formatter wrote \(value)")
        }
    }

    /// Outbox rows store the exact request bytes. A HealthKit batch is decoded
    /// and re-encoded through `.hlBatch` on replay, so a row an older build
    /// queued goes out with seconds whatever precision it was stored with.
    @Test("a queued HealthKit batch from an older build replays with seconds")
    func queuedBatchReplaysWithSeconds() throws {
        let stored = Data(#"""
        { "entries": [ { "hkIdentifier": "HKQuantityTypeIdentifierHeartRate", "value": 61, "unit": "count/min",
                         "startDate": "2026-10-15T06:15:00Z", "endDate": "2026-10-15T06:15:00.250Z",
                         "externalId": "a" } ] }
        """#.utf8)
        let payload = try JSONDecoder.hlDefault.decode(HealthKitBatchPayload.self, from: stored)
        let resent = try JSONEncoder.hlBatch.encode(payload)
        let object = try #require(try JSONSerialization.jsonObject(with: resent) as? [String: Any])
        let entry = try #require((object["entries"] as? [[String: Any]])?.first)
        for key in ["startDate", "endDate"] {
            let value = try #require(entry[key] as? String)
            #expect(Self.hasSeconds(value), "\(key) replayed as \(value)")
        }
    }

    /// No `DateFormatter` pattern in the app writes a date-time without
    /// seconds. Day keys (`yyyy-MM-dd`) are fine; a `'T'HH:mm` pattern without
    /// `:ss` is what the server refuses.
    @Test("no minute-precision date-time pattern in the app sources")
    func noMinutePrecisionPatterns() throws {
        let pattern = #/'T'HH:mm(?!:ss)/#
        var offenders: [String] = []
        for (path, contents) in try Self.appSources() where contents.contains("'T'HH:mm") {
            for line in contents.split(separator: "\n") where line.contains(pattern) {
                offenders.append("\(path): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "minute-precision date-time formats: \(offenders)")
    }

    private static func appSources(file: String = #filePath) throws -> [(String, String)] {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var result: [(String, String)] = []
        for folder in ["HealthLog", "HealthLogWidgets", "HealthLogWatch", "NotificationServiceExtension"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                try result.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), String(contentsOf: url, encoding: .utf8)))
            }
        }
        #expect(result.count > 100, "the source scan must actually see the app")
        return result
    }
}
