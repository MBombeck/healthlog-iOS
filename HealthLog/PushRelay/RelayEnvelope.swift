import CryptoKit
import Foundation

// **#190 — the push relay envelope, v1 (opening side).**
//
// HPKE (RFC 9180) in auth mode, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
// ChaCha20-Poly1305, through CryptoKit. The wire frame is
// `header(3) || enc(32) || ciphertext(bucket + 16)`; the header is version,
// suite and class, with no key ids. The AAD binds the header to the APNs token
// (`header || tokenTag`), so an envelope sealed for one install cannot be
// replayed to another. The plaintext is a two-byte length, the JSON, and zero
// padding up to the class bucket.
//
// Foundation and CryptoKit only: compiled into the app and the Notification
// Service Extension. The device never seals; the server does.

/// The two classes an envelope is sealed for. The class byte `0x03`
/// (`liveactivity`) is reserved: v1 never seals it, the relay refuses an
/// envelope on a Live Activity item, and the device has no path that opens one,
/// so a `0x03` envelope fails as `classMismatch` on either path.
public enum RelayPushClass: String, Sendable, CaseIterable, Codable {
    case alert
    case silent

    /// The envelope class byte.
    public var classByte: UInt8 {
        switch self {
        case .alert: 0x01
        case .silent: 0x02
        }
    }

    /// The padded plaintext size of the class.
    public var bucket: Int {
        switch self {
        case .alert, .silent: 1024
        }
    }

    /// The longest lifetime (`exp - iat`) the device accepts, in seconds.
    public var maxLifetime: Int64 {
        switch self {
        case .alert: 6 * 3600
        case .silent: 3600
        }
    }

    /// The exact wire length of an envelope of this class.
    public var envelopeLength: Int {
        RelayEnvelope.headerLength + RelayEnvelope.encLength + bucket + RelayEnvelope.tagLength
    }
}

/// Why an envelope was refused. The raw values are the spec's error codes.
public enum RelayEnvelopeError: String, Error, Sendable, Equatable, CaseIterable {
    case malformed
    case unsupportedVersion
    case classMismatch
    case authFailure
    case lifetimeTooLong
    case notYetValid
    case expired
    case replayed
    case replayStoreFull
}

/// A JSON value from an opened plaintext, kept `Sendable` and comparable.
public indirect enum RelayJSON: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([RelayJSON])
    case object([String: RelayJSON])

    init?(any value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case is NSNull:
            self = .null
        case let array as [Any]:
            var items: [RelayJSON] = []
            for element in array {
                guard let item = RelayJSON(any: element) else { return nil }
                items.append(item)
            }
            self = .array(items)
        case let object as [String: Any]:
            var fields: [String: RelayJSON] = [:]
            for (key, element) in object {
                guard let item = RelayJSON(any: element) else { return nil }
                fields[key] = item
            }
            self = .object(fields)
        default:
            return nil
        }
    }

    public subscript(key: String) -> RelayJSON? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    /// The value as a property-list object, for `userInfo`.
    var propertyListValue: Any {
        switch self {
        case let .string(value): value
        case let .number(value): value
        case let .bool(value): value
        case .null: NSNull()
        case let .array(items): items.map(\.propertyListValue)
        case let .object(fields): fields.mapValues(\.propertyListValue)
        }
    }
}

/// An opened envelope: the schema fields the spec fixes, the rest as JSON.
public struct RelayPlaintext: Sendable, Equatable {
    public let version: Int
    /// The fixed template name (`MEDICATION_INTAKE_RECORDED`, `SYNC`, ...).
    public let type: String
    /// ULID, unique per envelope; the replay store keys on it.
    public let id: String
    public let issuedAt: Int64
    public let expiresAt: Int64
    /// The whole plaintext object, including `d`, `n` and `ui`.
    public let json: RelayJSON

    public var data: RelayJSON? {
        json["d"]
    }

    public var title: String? {
        json["n"]?["title"]?.stringValue
    }

    public var body: String? {
        json["n"]?["body"]?.stringValue
    }

    public var category: String? {
        json["ui"]?["category"]?.stringValue
    }

    public var thread: String? {
        json["ui"]?["thread"]?.stringValue
    }

    public var level: String? {
        json["ui"]?["level"]?.stringValue
    }
}

public enum RelayEnvelope {
    public static let version: UInt8 = 0x01
    public static let suite: UInt8 = 0x01
    public static let info = Data("HealthLog push envelope v1".utf8)
    public static let headerLength = 3
    public static let encLength = 32
    public static let tagLength = 16
    public static let clockSkew: Int64 = 300
    static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    /// `SHA-256("hl-push-token" || token)[0..<16]`: the value the AAD binds
    /// and the binding statements name.
    public static func tokenTag(of token: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("hl-push-token".utf8))
        hasher.update(data: token)
        return Data(hasher.finalize().prefix(16))
    }

    /// `SHA-256("hl-push-key" || publicKey)[0..<8]`: the key id the API (not
    /// the envelope) carries next to a device key.
    public static func keyId(of publicKey: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("hl-push-key".utf8))
        hasher.update(data: publicKey)
        return Data(hasher.finalize().prefix(8))
    }

    /// Opens `envelope` in the order the spec checks: frame, then every pair
    /// of device key and trusted sender (at most two of each), then the
    /// plaintext schema, the lifetime, the clock, and last the replay store.
    public static func open(
        _ envelope: Data,
        recipientKeys: [Curve25519.KeyAgreement.PrivateKey],
        trustedSenders: [Curve25519.KeyAgreement.PublicKey],
        apnsToken: Data,
        expectedClass: RelayPushClass,
        now: Int64,
        replayStore: RelayReplayStoring? = nil
    ) throws(RelayEnvelopeError) -> RelayPlaintext {
        let bytes = [UInt8](envelope)
        guard bytes.count >= headerLength + encLength + tagLength + 2 else { throw .malformed }
        guard bytes[0] == version, bytes[1] == suite else { throw .unsupportedVersion }
        guard bytes[2] == expectedClass.classByte else { throw .classMismatch }
        guard bytes.count == expectedClass.envelopeLength else { throw .malformed }

        let header = Data(bytes[0 ..< headerLength])
        let enc = Data(bytes[headerLength ..< headerLength + encLength])
        let ciphertext = Data(bytes[(headerLength + encLength)...])
        let aad = header + tokenTag(of: apnsToken)

        guard let padded = decrypt(
            enc: enc,
            ciphertext: ciphertext,
            aad: aad,
            recipientKeys: recipientKeys.prefix(2),
            trustedSenders: trustedSenders.prefix(RelayKeyring.maxSenders)
        ) else { throw .authFailure }

        let plaintext = try parse(padded)
        let lifetime = plaintext.expiresAt - plaintext.issuedAt
        guard lifetime > 0, lifetime <= expectedClass.maxLifetime else { throw .lifetimeTooLong }
        guard plaintext.issuedAt <= now + clockSkew else { throw .notYetValid }
        guard now <= plaintext.expiresAt + clockSkew else { throw .expired }
        try replayStore?.checkAndRecord(id: plaintext.id, expiresAt: plaintext.expiresAt, now: now)
        return plaintext
    }

    private static func decrypt(
        enc: Data,
        ciphertext: Data,
        aad: Data,
        recipientKeys: ArraySlice<Curve25519.KeyAgreement.PrivateKey>,
        trustedSenders: ArraySlice<Curve25519.KeyAgreement.PublicKey>
    ) -> Data? {
        for recipientKey in recipientKeys {
            for sender in trustedSenders {
                guard var recipient = try? HPKE.Recipient(
                    privateKey: recipientKey,
                    ciphersuite: ciphersuite,
                    info: info,
                    encapsulatedKey: enc,
                    authenticatedBy: sender
                ) else { continue }
                if let opened = try? recipient.open(ciphertext, authenticating: aad) { return opened }
            }
        }
        return nil
    }

    /// Crockford base32, 26 characters: the ULID alphabet without I, L, O, U.
    private static let idAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func isEnvelopeId(_ candidate: String) -> Bool {
        candidate.count == 26 && candidate.allSatisfy { idAlphabet.contains($0) }
    }

    /// Length prefix, zero padding, strict UTF-8 and the schema fields.
    static func parse(_ padded: Data) throws(RelayEnvelopeError) -> RelayPlaintext {
        let bytes = [UInt8](padded)
        guard bytes.count >= 2 else { throw .malformed }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0, length + 2 <= bytes.count else { throw .malformed }
        guard bytes[(2 + length)...].allSatisfy({ $0 == 0 }) else { throw .malformed }
        let body = Data(bytes[2 ..< 2 + length])
        guard String(data: body, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let json = RelayJSON(any: object) else { throw .malformed }
        guard let version = integer(object["v"]), version == 1,
              let type = object["t"] as? String, !type.isEmpty,
              let id = object["id"] as? String, isEnvelopeId(id),
              let issuedAt = integer(object["iat"]),
              let expiresAt = integer(object["exp"]) else { throw .malformed }
        return RelayPlaintext(
            version: Int(version),
            type: type,
            id: id,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            json: json
        )
    }

    /// A JSON number with no fraction, never a boolean.
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) < 9.0e15 else { return nil }
        return Int64(double)
    }
}
