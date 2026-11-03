import Foundation

/// **1.4 / iOS 27 — how far back Apple Health lets this app read one type.**
///
/// iOS 27 lets a person grant an app a recent window of Health data instead of
/// the full history. Apple's rule for that case is the reason this type exists:
/// "Treat all data before that date as unknown, not an absence of data." Every
/// place that reads "not found in Apple Health" as "not there" (the server
/// mirror, the dose ledger) asks this value first.
///
/// Platform-free on purpose: the dose ledger and the medication importer are
/// HealthKit-free, and the boundary is just a date. The HealthKit side that
/// produces it is `HealthKitAuthorizedHistory`.
public enum HealthReadWindow: Sendable, Equatable {
    /// The whole history. Denied access looks the same (Apple keeps the two
    /// indistinguishable by design), and so does every system before iOS 27.
    case unlimited
    /// Only samples that end at or after this instant are readable. Anything
    /// older is unknown, not absent.
    case limited(from: Date)
    /// HealthKit could not answer. Nothing may be read as absent then.
    case unknown

    /// Whether an empty read proves nothing for a sample that ends at `end`.
    ///
    /// HealthKit checks the boundary against a sample's end date, so a sample
    /// that ends exactly on it is still readable.
    public func hidesAbsence(endingAt end: Date) -> Bool {
        switch self {
        case .unlimited: false
        case let .limited(from): end < from
        case .unknown: true
        }
    }

    /// The start a query should use: the later of the intended start and the
    /// readable boundary, as Apple recommends for limited access. `nil` (no
    /// bound) becomes the boundary itself.
    public func clamp(_ start: Date?) -> Date? {
        guard case let .limited(from) = self else { return start }
        guard let start else { return from }
        return max(start, from)
    }

    /// **B5 (1.4, R4 2.1)** — where a statistics read (day or hour totals)
    /// starts so that its first bucket lies wholly inside the readable window.
    /// The bucket the boundary falls into would only sum its readable part and
    /// overwrite the server's full total with less, so it is skipped: the read
    /// starts at the next whole `bucket`, or at the boundary when it is one.
    /// Full access and an unknown window keep `anchor` (an unknown window has
    /// no boundary to align to; the read stays what it was before 1.4).
    public func wholeBucketStart(_ anchor: Date, bucket: Calendar.Component, calendar: Calendar) -> Date {
        guard case let .limited(from) = self, from > anchor else { return anchor }
        guard let interval = calendar.dateInterval(of: bucket, for: from) else { return from }
        return interval.start == from ? from : interval.end
    }
}
