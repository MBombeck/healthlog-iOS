import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// The tolerant, exhaustive ``IntakeSource`` decode. The whole
/// point is that a `/api/sync/changes` intake row carrying `source:"APPLE_HEALTH"`
/// (or any other / absent value) NEVER fails to decode and drops the row.
@Suite("IntakeSource — tolerant decode (no drop)")
struct IntakeSourceTests {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test("APPLE_HEALTH decodes to .appleHealth (exact spelling)")
    func appleHealthDecodes() throws {
        let data = Data(#""APPLE_HEALTH""#.utf8)
        let source = try decoder().decode(IntakeSource.self, from: data)
        #expect(source == .appleHealth)
        #expect(source.isAppleHealth)
        #expect(source.wireValue == "APPLE_HEALTH")
    }

    @Test("MANUAL decodes to .manual")
    func manualDecodes() throws {
        let source = try decoder().decode(IntakeSource.self, from: Data(#""MANUAL""#.utf8))
        #expect(source == .manual)
        #expect(!source.isAppleHealth)
    }

    @Test("An unknown source never throws — it maps to .other verbatim")
    func unknownDecodesToOther() throws {
        let source = try decoder().decode(IntakeSource.self, from: Data(#""SOME_FUTURE_SOURCE""#.utf8))
        #expect(source == .other("SOME_FUTURE_SOURCE"))
        // Round-trips verbatim so a re-encode never loses the value.
        #expect(source.wireValue == "SOME_FUTURE_SOURCE")
    }
}

// swiftlint:enable force_unwrapping
