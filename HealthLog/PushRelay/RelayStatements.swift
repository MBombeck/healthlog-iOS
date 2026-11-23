import CryptoKit
import Foundation

// **#190 5.2 and 5.4 — the texts the device binding key signs.**
//
// Every statement is a newline-joined list that starts with a versioned tag
// and names the relay host, so a signature for one relay or one purpose is
// worth nothing for another. Token tags are lowercase hex; times are Unix
// seconds; keys and signatures travel as unpadded base64url.

public enum RelayStatement {
    /// `POST /api/devices` `relayBinding`: binds this token to the instance.
    public static func bind(
        host: String,
        instanceId: String,
        tokenTag: Data,
        kind: String = "device",
        seq: Int64,
        iat: Int64
    ) -> String {
        join("hl-bind-v1", host, instanceId, tokenTag.relayHex, kind, String(seq), String(iat))
    }

    /// `DELETE /v1/bindings/self`: the direct opt-out, without the server.
    public static func unbind(host: String, instanceId: String, tokenTag: Data, iat: Int64) -> String {
        join("hl-unbind-v1", host, instanceId, tokenTag.relayHex, String(iat))
    }

    /// `POST /v1/bindings/challenge`: answers a conflict challenge push.
    public static func challenge(host: String, challenge: String, tokenTag: Data) -> String {
        join("hl-challenge-v1", host, challenge, tokenTag.relayHex)
    }

    /// Sent to the own server at Live Activity start; reaches the relay only
    /// inside the `end` push.
    public static func activity(host: String, instanceId: String, tokenTag: Data, laTokenTag: Data, iat: Int64) -> String {
        join("hl-activity-v1", host, instanceId, tokenTag.relayHex, laTokenTag.relayHex, String(iat))
    }

    /// The separate Live Activity consent (#190, 17:58): only the device can
    /// switch it on.
    public static func liveActivityConsent(host: String, instanceId: String, tokenTag: Data, textVersion: String, iat: Int64) -> String {
        join("hl-la-consent-v1", host, instanceId, tokenTag.relayHex, textVersion, String(iat))
    }

    /// Withdraws it, through the server or directly at the relay.
    public static func liveActivityWithdraw(host: String, instanceId: String, tokenTag: Data, iat: Int64) -> String {
        join("hl-la-withdraw-v1", host, instanceId, tokenTag.relayHex, String(iat))
    }

    /// Registers a push-to-start token; at most 30 days old when the relay
    /// uses it, so it is signed again before that.
    public static func liveActivityStart(host: String, instanceId: String, tokenTag: Data, startTokenTag: Data, iat: Int64) -> String {
        join("hl-la-start-v1", host, instanceId, tokenTag.relayHex, startTokenTag.relayHex, String(iat))
    }

    /// `GET /v1/bindings/self`: "my data at the relay".
    public static func selfRead(host: String, tokenTag: Data, iat: Int64) -> String {
        join("hl-selfread-v1", host, tokenTag.relayHex, String(iat))
    }

    /// The relay's signed answer (`hl-relay-resp-v2`, #190 §0): bound to the
    /// request's method, raw path with query and nonce (`-` when the relay
    /// saw none), and to the status and the raw body.
    public static func response(
        host: String,
        method: String,
        pathWithQuery: String,
        nonce: String,
        status: Int,
        body: Data
    ) -> String {
        join("hl-relay-resp-v2", host, method.uppercased(), pathWithQuery, nonce, String(status), SHA256.hash(data: body).relayHex)
    }

    private static func join(_ fields: String...) -> String {
        fields.joined(separator: "\n")
    }

    public static func sign(_ text: String, with key: Curve25519.Signing.PrivateKey) throws -> Data {
        try key.signature(for: Data(text.utf8))
    }

    public static func verify(_ text: String, signature: Data, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        publicKey.isValidSignature(signature, for: Data(text.utf8))
    }
}

public extension Data {
    /// Lowercase hex, as every relay statement spells bytes.
    var relayHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Unpadded base64url, the relay's encoding for keys and signatures.
    var relayBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict: rejects padding, `+`, `/` and whitespace like the relay does.
    init?(relayBase64URL text: String) {
        guard !text.contains(where: { "=+/ \n\r\t".contains($0) }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }

    init?(relayHex text: String) {
        guard text.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

extension SHA256.Digest {
    var relayHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
