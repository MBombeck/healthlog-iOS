import Foundation

/// #110 — how long a `429` asked the client to wait, in seconds from `now`.
///
/// From server v1.39.0 every limiter refusal carries `Retry-After` (whole
/// seconds, never below 1) next to `X-RateLimit-Reset` (an ISO-8601 instant);
/// `api-handler.ts` attaches them to any 429 a limiter produced. A few routes
/// also mirror the instant into `meta.retryAt`. The shared single-record write
/// ceiling (`meta.errorCode == "record_write.rate_limited"`, 300 writes per 60 s
/// per account) tells the client to back off on `Retry-After` rather than guess.
///
/// Read in this order:
/// 1. `Retry-After` as delta-seconds. It is relative, so a device clock that is
///    off cannot stretch or shrink it.
/// 2. `Retry-After` as an HTTP date (IMF-fixdate, RFC 9110 §10.2.3).
/// 3. `X-RateLimit-Reset` (ISO-8601).
/// 4. The body: `meta.retryAt` (ISO-8601) or `meta.retryAfter` (seconds).
///
/// `nil` when none of them is readable; the caller then picks its own bounded
/// back-off. Never negative.
enum RateLimitDelay {
    static func seconds(from response: HTTPURLResponse, body: Data?, now: Date = Date()) -> TimeInterval? {
        if let raw = response.value(forHTTPHeaderField: "Retry-After") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let seconds = TimeInterval(trimmed), seconds.isFinite, seconds >= 0 {
                return seconds
            }
            if let date = httpDate(trimmed) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        if let raw = response.value(forHTTPHeaderField: "X-RateLimit-Reset"), let reset = isoDate(raw) {
            return max(0, reset.timeIntervalSince(now))
        }
        return metaDelay(in: body, now: now)
    }

    /// `Sun, 06 Nov 1994 08:49:37 GMT` — the only form RFC 9110 lets a sender
    /// emit. Built per call: this runs on a 429 only.
    static func httpDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: raw)
    }

    private static func isoDate(_ raw: String) -> Date? {
        ISO8601DateFormatter.fractional.date(from: raw) ?? ISO8601DateFormatter.plain.date(from: raw)
    }

    private static func metaDelay(in body: Data?, now: Date) -> TimeInterval? {
        guard let body, !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let meta = object["meta"] as? [String: Any] else { return nil }
        if let at = meta["retryAt"] as? String, let date = isoDate(at) {
            return max(0, date.timeIntervalSince(now))
        }
        if let seconds = meta["retryAfter"] as? Double, seconds.isFinite, seconds >= 0 {
            return seconds
        }
        return nil
    }
}
