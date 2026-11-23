import Foundation

/// The allowed range a `422` names (server 1.49.0).
///
/// Every route that validates against a schema answers a refused field with
/// `details.issues[]`; since 1.49.0 a size issue (`too_small`, `too_big`)
/// carries the bound the schema declares: `minimum` or `maximum`, whether it
/// is `inclusive`, and what it measures (`origin`: `number`, `string`,
/// `array`, …). All four are optional, and they come from the schema, never
/// from the request. Where the field declares both ends, the issue carries
/// both (`minimum` and `maximum`) with `minimumInclusive` and
/// `maximumInclusive`; `inclusive` stays the broken bound's. Without the two
/// flags the single bound is read as before.
///
/// ``APIClient`` turns such a refusal into a sentence that names the range
/// ("Erlaubt: höchstens 5.000."), so every surface that shows the server's
/// 4xx message (the nutrient target editor, any form's field error) tells the
/// person what is allowed instead of a bare "Validation failed". An answer
/// without a bound (an older server, an issue that is not about a size) keeps
/// the message it had.
struct APIValidationBounds: Equatable, Sendable {
    /// What the bound measures; anything else reads as a number.
    enum Origin: Equatable, Sendable {
        case number
        case string
        case array

        init(raw: String?) {
            switch raw {
            case "string": self = .string
            case "array", "set": self = .array
            default: self = .number
            }
        }
    }

    struct Bound: Equatable, Sendable {
        let value: Double
        let inclusive: Bool
    }

    let minimum: Bound?
    let maximum: Bound?
    let origin: Origin

    /// The bounds of the first refused field that names one, with the
    /// minimum and maximum of that field joined when two issues carry them.
    /// `nil` when the body names no bound. A date bound (`origin: "date"`,
    /// epoch milliseconds) is not a range a person reads, so it is skipped.
    static func from(body: Data) -> Self? {
        guard let issues = (try? JSONDecoder().decode(Body.self, from: body))?.details?.issues else { return nil }
        let bounded = issues.filter { ($0.minimum != nil || $0.maximum != nil) && $0.origin != "date" }
        guard let first = bounded.first else { return nil }
        let sameField = bounded.filter { $0.path == first.path }
        let minimum = sameField.lazy.compactMap { issue in
            issue.minimum.map { Bound(value: $0, inclusive: issue.minimumInclusive ?? issue.inclusive ?? true) }
        }.first
        let maximum = sameField.lazy.compactMap { issue in
            issue.maximum.map { Bound(value: $0, inclusive: issue.maximumInclusive ?? issue.inclusive ?? true) }
        }.first
        return Self(minimum: minimum, maximum: maximum, origin: Origin(raw: first.origin))
    }

    /// The server's generic sentence of a schema refusal
    /// (`returnAllZodIssues`). A route that composed its own sentence keeps
    /// it: some callers match on that text.
    static let genericMessage = "Validation failed"

    /// The message an `HLError.server` carries for this refusal: the range,
    /// in the app's language. `nil` (keep the server's message) for any
    /// status but 422, a sentence the route composed itself, or a body
    /// without a bound.
    static func message(status: Int, serverMessage: String?, body: Data) -> String? {
        guard status == 422, serverMessage == nil || serverMessage == genericMessage,
              let bounds = from(body: body) else { return nil }
        return bounds.sentence
    }

    /// "Der Wert liegt außerhalb des erlaubten Bereichs. Erlaubt: höchstens
    /// 5.000."
    var sentence: String {
        String(localized: "error.bounds.sentence \(rangeText)")
    }

    /// The range alone: "1 bis 10", "höchstens 5.000", "über 0",
    /// "höchstens 128 Zeichen".
    var rangeText: String {
        let unit: (Double) -> String = { value in
            let number = Self.number(value)
            switch origin {
            case .number: return number
            case .string: return String(localized: "error.bounds.characters \(number)")
            case .array: return String(localized: "error.bounds.entries \(number)")
            }
        }
        switch (minimum, maximum) {
        case let (lower?, upper?) where lower.inclusive && upper.inclusive:
            return String(localized: "error.bounds.between \(Self.number(lower.value)) \(unit(upper.value))")
        case let (_, upper?) where upper.inclusive:
            return String(localized: "error.bounds.atMost \(unit(upper.value))")
        case let (_, upper?):
            return String(localized: "error.bounds.below \(unit(upper.value))")
        case let (lower?, nil) where lower.inclusive:
            return String(localized: "error.bounds.atLeast \(unit(lower.value))")
        case let (lower?, nil):
            return String(localized: "error.bounds.above \(unit(lower.value))")
        case (nil, nil):
            return ""
        }
    }

    private static func number(_ value: Double) -> String {
        // Inline, not `HLValueFormat`: this file is part of the shared core
        // the widget extension compiles, which has no DesignSystem.
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    private struct Body: Decodable {
        struct Details: Decodable {
            let issues: [Issue]?
        }

        struct Issue: Decodable {
            let path: String?
            let minimum: Double?
            let maximum: Double?
            let inclusive: Bool?
            /// Present only when the issue carries both ends (1.49.0).
            let minimumInclusive: Bool?
            let maximumInclusive: Bool?
            let origin: String?

            private enum CodingKeys: String, CodingKey {
                case path, minimum, maximum, inclusive, minimumInclusive, maximumInclusive, origin
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                path = try? c.decodeIfPresent(String.self, forKey: .path)
                minimum = (try? c.decodeIfPresent(Double.self, forKey: .minimum)).flatMap { $0.isFinite ? $0 : nil }
                maximum = (try? c.decodeIfPresent(Double.self, forKey: .maximum)).flatMap { $0.isFinite ? $0 : nil }
                inclusive = try? c.decodeIfPresent(Bool.self, forKey: .inclusive)
                minimumInclusive = try? c.decodeIfPresent(Bool.self, forKey: .minimumInclusive)
                maximumInclusive = try? c.decodeIfPresent(Bool.self, forKey: .maximumInclusive)
                origin = try? c.decodeIfPresent(String.self, forKey: .origin)
            }
        }

        let details: Details?
    }
}
