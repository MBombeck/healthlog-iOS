import Foundation

/// Pure, view-free helpers behind the intraday-pulse day curve (P7).
///
/// Everything here is deterministic value math over ``IntradayPulseDTO`` so the
/// honesty rules the surface depends on — never interpolate across a gap, never
/// re-derive a bucket's wall time, never step the navigator past today — are
/// unit-testable without a view, a store or a network.
enum IntradayPulseMath {
    // MARK: - Wall-clock labels

    /// `HH:mm` for a minute-of-local-day. Pure wall time: the server already
    /// localised the bucket, so there is deliberately NO `Date`/`TimeZone`
    /// round-trip here (web parity: `intraday-pulse-chart.tsx:46-50`).
    ///
    /// `1440` (the right axis edge) reads `24:00`, matching the web tick set.
    static func minuteLabel(_ minute: Int) -> String {
        let clamped = Swift.max(0, minute)
        let hour = clamped / 60
        let rest = clamped % 60
        return String(format: "%02d:%02d", hour, rest)
    }

    /// The X-axis ticks: midnight, 06:00, noon, 18:00, midnight.
    static let axisTicks: [Int] = [0, 360, 720, 1080, 1440]

    // MARK: - Gap-aware run splitting

    /// Splits a day's buckets into CONTIGUOUS runs.
    ///
    /// Two buckets belong to the same run only when they are exactly
    /// `bucketMinutes` apart. Anything wider is a REAL data gap — no reading
    /// was trustworthy in between — and starts a new run, so the chart draws
    /// separate line segments instead of inventing a slope across the silence.
    /// (Web enforces the same with `connectNulls={false}` over a full
    /// 0…1440 null-padded grid; a run split is the Swift Charts equivalent and
    /// avoids feeding `LineMark` a nil-bearing series.)
    ///
    /// The input is sorted defensively — the route sorts ascending, but the
    /// honesty rule must not depend on that.
    static func runs(_ series: [IntradayPulseDTO.Bucket], bucketMinutes: Int) -> [[IntradayPulseDTO.Bucket]] {
        guard !series.isEmpty else { return [] }
        let width = Swift.max(1, bucketMinutes)
        let sorted = series.sorted { $0.startMinute < $1.startMinute }
        var result: [[IntradayPulseDTO.Bucket]] = []
        var current: [IntradayPulseDTO.Bucket] = [sorted[0]]
        for bucket in sorted.dropFirst() {
            if let previous = current.last, bucket.startMinute - previous.startMinute == width {
                current.append(bucket)
            } else {
                result.append(current)
                current = [bucket]
            }
        }
        result.append(current)
        return result
    }

    // MARK: - Coverage disclosure

    /// How much of the day the curve actually rests on.
    struct Coverage: Equatable {
        /// Raw readings summed across the present buckets.
        let readingCount: Int
        /// Whole hours from the first bucket's start to the last bucket's end.
        let hours: Int
    }

    /// The coverage disclosure, or `nil` when the day is contiguous.
    ///
    /// It fires ONLY when the series contains a real break — a gap-free day
    /// already reads honestly and does not need a caveat (web
    /// `intraday-pulse-chart.tsx:143-160`). Hours are whole (rounded, floored
    /// at 1) so the copy stays simple across locales.
    static func coverage(_ series: [IntradayPulseDTO.Bucket], bucketMinutes: Int) -> Coverage? {
        guard series.count >= 2 else { return nil }
        let width = Swift.max(1, bucketMinutes)
        let sorted = series.sorted { $0.startMinute < $1.startMinute }
        let hasGap = zip(sorted, sorted.dropFirst()).contains { previous, next in
            next.startMinute - previous.startMinute > width
        }
        guard hasGap else { return nil }
        let readings = sorted.reduce(0) { $0 + $1.count }
        let first = sorted[0].startMinute
        let last = (sorted.last?.startMinute ?? first) + width
        let hours = Swift.max(1, Int((Double(last - first) / 60).rounded()))
        return Coverage(readingCount: readings, hours: hours)
    }

    // MARK: - Day navigator (profile-timezone arithmetic)

    /// A `yyyy-MM-dd` calendar for `zone`. POSIX locale + Gregorian so the key
    /// never picks up a device calendar/locale quirk.
    private static func formatter(for zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// The `yyyy-MM-dd` day key for `date` in the PROFILE timezone.
    ///
    /// The profile zone (not the device zone) is the doctrine: the server
    /// resolves "today" from the same profile zone, so a travelling operator
    /// sees one consistent day on both surfaces rather than two.
    static func dayKey(for date: Date = .now, in zone: TimeZone) -> String {
        formatter(for: zone).string(from: date)
    }

    /// Shifts a day key by whole days in the profile-timezone calendar.
    ///
    /// Calendar arithmetic (not `± 86_400`), so a DST boundary shifts by ONE
    /// day rather than landing 23 or 25 hours away on the neighbouring date.
    /// Returns `nil` for an unparsable key (never a fabricated day).
    static func shift(dayKey: String, by days: Int, in zone: TimeZone) -> String? {
        let formatter = formatter(for: zone)
        guard let date = formatter.date(from: dayKey) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return formatter.string(from: shifted)
    }

    /// The key one day AFTER `dayKey`, capped at `todayKey`.
    ///
    /// Defence in depth alongside the disabled "next" chevron: the navigator
    /// can never step into the future however the call is reached (web
    /// `intraday-pulse-chart.tsx:99-105`).
    static func nextDayKey(after dayKey: String, todayKey: String, in zone: TimeZone) -> String? {
        guard let next = shift(dayKey: dayKey, by: 1, in: zone), next <= todayKey else { return nil }
        return next
    }
}
