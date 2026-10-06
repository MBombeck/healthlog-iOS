import Foundation

// #115 · 1.7 — the ONE tolerant decoder for server-owned string enums.
//
// A synthesized `Decodable` on a `String`-raw enum throws `dataCorrupted` for
// any value this build does not list. Inside a synthesized parent that throw
// fails the parent; inside a `try?` it silently turns the parent into `nil`
// (the comprehensive digest vanished exactly that way when the server sent a
// fourth trend token). The server grows its vocabularies between app releases,
// so every enum whose values the SERVER owns adopts this protocol instead:
// an unrecognised value lands on the enum's own fallback case, the first
// sighting is logged once, and the rest of the payload decodes untouched.
//
// Rules for adopters:
// - The fallback is a case that asserts nothing (`.unknown`, or a documented
//   "not yet ready" state like `.partial`). Never a case that claims a fact —
//   an unknown trend is not `.up`, an unknown severity is not `.info`.
// - UI switching over the enum renders the fallback neutrally.
// - An enum that is also ENCODED back to the server must not send the
//   fallback as if it were a value — keep the raw wire string alongside (see
//   `HealthKitSyncEntry`) or refuse to encode it.

/// A `String`-raw enum whose values the server owns. Decoding an unknown
/// string yields ``unknownFallback`` instead of throwing.
public protocol TolerantServerEnum: RawRepresentable, Decodable, Sendable where RawValue == String {
    /// The case an unrecognised wire value decodes to.
    static var unknownFallback: Self { get }
    /// Name used in the one-time "unknown value" log line.
    static var wireVocabulary: StaticString { get }
    /// Optional spelling normalisation tried after the verbatim match
    /// (e.g. lowercasing). Default: none.
    static func normalizedWireValue(_ raw: String) -> String?
}

public extension TolerantServerEnum {
    static var wireVocabulary: StaticString {
        "server enum"
    }

    static func normalizedWireValue(_: String) -> String? {
        nil
    }

    /// An unknown STRING is a new server value and lands on the fallback. A
    /// value that is not a string at all is schema drift, not growth, and
    /// still throws — lossy lists contain that to the one row.
    init(from decoder: Decoder) throws {
        self = try Self(wireValue: decoder.singleValueContainer().decode(String.self))
    }

    /// Resolves a raw wire token without a decoder — for parents that read the
    /// field as a plain `String` first.
    init(wireValue raw: String) {
        if let known = Self(rawValue: raw) {
            self = known
        } else if let normalized = Self.normalizedWireValue(raw), let known = Self(rawValue: normalized) {
            self = known
        } else {
            UnknownServerEnumLog.noteFirstSighting(
                of: raw, vocabulary: Self.wireVocabulary, consequence: "decoded as the neutral fallback case"
            )
            self = Self.unknownFallback
        }
    }
}

// MARK: - Lossy arrays

public extension KeyedDecodingContainer {
    /// Decodes an array element by element and SKIPS any element that fails,
    /// so one malformed row never fails the whole list. Absent key or `null`
    /// yields `[]`; a value that is not an array at all still throws.
    func decodeLossyArray<T: Decodable>(_: T.Type, forKey key: Key) throws -> [T] {
        guard contains(key), try decodeNil(forKey: key) == false else { return [] }
        var unkeyed = try nestedUnkeyedContainer(forKey: key)
        var result: [T] = []
        while !unkeyed.isAtEnd {
            if let element = try? unkeyed.decode(T.self) {
                result.append(element)
            } else {
                // Consume the rejected element so the loop advances.
                _ = try? unkeyed.decode(SkippedJSONValue.self)
            }
        }
        return result
    }

    /// Like ``decodeLossyArray(_:forKey:)`` but keeps "absent" distinct from
    /// "empty": returns `nil` when the key is missing or `null`.
    func decodeLossyArrayIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T]? {
        guard contains(key), try decodeNil(forKey: key) == false else { return nil }
        return try decodeLossyArray(type, forKey: key)
    }
}

/// Swallows exactly one JSON value so a lossy loop can step past an element
/// its target type rejected.
struct SkippedJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}
