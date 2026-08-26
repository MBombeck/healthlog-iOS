import Foundation

/// Pure client-side derivation of **pulse pressure** and **mean arterial
/// pressure** from a single blood-pressure reading — the iOS mirror of the
/// web v1.18.6 BP-detail "free derived context" caption
/// (`src/app/insights/blood-pressure/page.tsx`).
///
/// Both are arithmetic functions of the systolic / diastolic the app already
/// has — NOT a stored measurement, never written back. Rounded to whole
/// mmHg to match the web's `Math.round`.
///
/// - **Pulse pressure (PP):** `SYS − DIA` — the gap between the two readings.
/// - **Mean arterial pressure (MAP):** `DIA + (SYS − DIA)/3`, equivalently
///   `(SYS + 2·DIA)/3` — the average pressure the organs see. Both forms are
///   algebraically identical; the web uses `(SYS + 2·DIA)/3`.
public struct BPDerivedReadout: Equatable, Sendable {
    /// Pulse pressure in whole mmHg.
    public let pulsePressure: Int
    /// Mean arterial pressure in whole mmHg.
    public let meanArterialPressure: Int

    public init(pulsePressure: Int, meanArterialPressure: Int) {
        self.pulsePressure = pulsePressure
        self.meanArterialPressure = meanArterialPressure
    }

    /// Derive PP + MAP from a systolic/diastolic pair.
    ///
    /// Returns `nil` — the self-suppress signal — when either value is
    /// missing/non-finite or the reading is physiologically inverted
    /// (`sys <= dia`), matching the web guard (`sbp <= dbp → return null`).
    public static func derive(systolic: Double?, diastolic: Double?) -> BPDerivedReadout? {
        guard let sys = systolic, let dia = diastolic,
              sys.isFinite, dia.isFinite,
              sys > dia else { return nil }

        let pp = (sys - dia).rounded()
        // (SYS + 2·DIA)/3 — identical to DIA + (SYS − DIA)/3, web form.
        let map = ((sys + 2 * dia) / 3).rounded()
        return BPDerivedReadout(
            pulsePressure: Int(pp),
            meanArterialPressure: Int(map)
        )
    }
}
