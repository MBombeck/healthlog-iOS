import Foundation

public extension JSONDecoder {
    /// Default Decoder fuer alle Repos / Replay-Pfade / Cache-Reads.
    ///
    /// **Date strategy:** akzeptiert
    /// - ISO8601 mit fractional seconds (`2026-05-15T10:30:00.123Z`)
    /// - ISO8601 ohne fractional seconds (`2026-05-15T10:30:00Z`)
    /// - Day-keys im Format `YYYY-MM-DD` (Server-seitig fuer
    ///   `ComplianceDay.date` + andere date-only Felder, parsed als
    ///   Mitternacht UTC) — siehe A4-Audit §3 row 30.
    ///
    /// **Key strategy:** belaesst camelCase (Server schickt camelCase, kein
    /// snake-case-Conversion noetig). Vorher diverged der `OutboxReplayService`
    /// auf `.convertFromSnakeCase` + `.iso8601` ohne fractional — ein Footgun.
    static let hlDefault: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractionalOrDayKey
        return d
    }()
}

extension JSONDecoder.DateDecodingStrategy {
    /// Tolerantes Date-Decoding: ISO8601 mit/ohne fractional Seconds plus
    /// `YYYY-MM-DD` Day-Key. Day-Keys werden als 00:00 UTC interpretiert,
    /// passend zur Server-Konvention in `medications/intake?scope=compliance`.
    static var iso8601WithFractionalOrDayKey: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: raw) {
                return date
            }
            if let date = ISO8601DateFormatter.plain.date(from: raw) {
                return date
            }
            if let date = DateFormatter.hlDayKey.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date format: \(raw). Expected ISO8601 or YYYY-MM-DD."
            )
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// ISO8601 with or without fractional seconds — the strict variant without
    /// the `YYYY-MM-DD` day-key fallback above. Moved here verbatim from
    /// `Services/APIClient.swift` (v0.17 / CU-02) so both date strategies live
    /// side by side; no behaviour change.
    static var iso8601WithFractional: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: raw) {
                return date
            }
            if let date = ISO8601DateFormatter.plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(raw)")
        }
    }
}

extension ISO8601DateFormatter {
    /// ISO8601DateFormatter is documented as thread-safe for parsing/formatting once
    /// configured (only `formatOptions` mutation is unsafe — we set it once at init).
    /// Foundation hasn't marked the class Sendable, so we vouch for it under Swift 6
    /// strict concurrency with `nonisolated(unsafe)`.
    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

public extension DateFormatter {
    /// Day-Key Formatter (`YYYY-MM-DD`, UTC). Server emits this format for
    /// `ComplianceDay.date` and similar date-only fields.
    static let hlDayKey: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
