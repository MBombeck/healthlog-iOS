import Foundation
@testable import HealthLog
import Testing

/// Small decode gaps closed in 1.3.0. Display of these fields
/// is later work; what is pinned here is that the server's values arrive.
@Suite("#126 P2 decode gaps")
struct ContractP2DecodeGapTests {
    /// v1.40.3: a health-status deviation says what its band describes.
    @Test("a deviation carries its basis; absent and unknown words are tolerated")
    func deviationBasis() throws {
        let json = Data(#"""
        { "present": true,
          "deviations": [
            { "type": "BLOOD_GLUCOSE", "value": 7.9, "center": 5.6, "low": 4.8, "high": 6.9,
              "direction": "above", "basis": "sameHours" },
            { "type": "PULSE", "value": 92, "center": 64, "low": 56, "high": 74, "direction": "above" },
            { "type": "WEIGHT", "value": 80, "center": 78, "low": 77, "high": 79, "direction": "above",
              "basis": 3 }
          ],
          "shifts": [] }
        """#.utf8)
        let status = try JSONDecoder.hlDefault.decode(InsightsHealthStatusDTO.self, from: json)
        #expect(status.deviations.map(\.basis) == ["sameHours", nil, nil])
    }
}
