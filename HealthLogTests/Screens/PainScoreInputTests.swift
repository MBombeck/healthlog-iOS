@testable import HealthLog
import Testing

/// v0158 — the 0–10 NRS pain picker clamp/validation contract. The server
/// accepts any 0–10 float (`PAIN_NRS`), so pinning the INTEGER band is a
/// client responsibility. App-target-only suite (mirrors `MeasureRecentKinds`)
/// because `PainScoreInput` lives in the MeasureSheet (app target), not Core.
@Suite("PainScoreInput — 0–10 NRS clamp")
struct PainScoreInputTests {
    @Test("clamp pins values into 0…10", arguments: [
        (-5, 0), (-1, 0), (0, 0), (3, 3), (10, 10), (11, 10), (99, 10)
    ])
    func clamp(pair: (Int, Int)) {
        #expect(PainScoreInput.clamp(pair.0) == pair.1)
    }

    @Test("isValid only accepts 0…10")
    func isValid() {
        #expect(PainScoreInput.isValid(0))
        #expect(PainScoreInput.isValid(10))
        #expect(!PainScoreInput.isValid(-1))
        #expect(!PainScoreInput.isValid(11))
    }

    @Test("the picker range is exactly 0…10 (11 integer rows)")
    func rangeIsZeroToTen() {
        #expect(PainScoreInput.range == 0 ... 10)
        #expect(PainScoreInput.range.count == 11)
    }
}
