import CryptoKit
import Foundation

// **#190 §0 to §2 — the three calls the app makes to the relay itself.**
//
// "The app never talks to the relay" has exactly these exceptions: the direct
// opt-out, "my data at the relay", and the answer to a conflict challenge.
// Each is signed with the binding key and needs no server, so turning the
// relay off works while the server is down. Every request carries a fresh
// `HL-Nonce`; every answer must carry the relay's `hl-relay-resp-v2`
// signature over this request and the raw answer, by a pinned identity key.
// Anything else is a transport error, never a refusal, a revocation or a
// notice.

/// The relay this build talks to, and the identity keys it pins. The values
/// come from ``HLPushRelayPin`` (generated at build time from the relay's
/// `keys/<host>.json` by `scripts/pin-relay-keys.py`), never from the relay
/// at run time: an answer cannot vouch for the key that signs it.
public enum HLPushRelayKeys {
    public static var host: String {
        HLPushRelayPin.host
    }

    /// `current`, then `next`, then the offline `emergency` key; empty until
    /// the relay's first release is pinned. Until then every relay answer is
    /// a transport error. An answer signed by any of the three is accepted.
    public static var pinned: [Curve25519.Signing.PublicKey] {
        keys(current: HLPushRelayPin.current, next: HLPushRelayPin.next, emergency: HLPushRelayPin.emergency)
    }

    static func keys(current: String, next: String, emergency: String = "") -> [Curve25519.Signing.PublicKey] {
        [current, next, emergency].compactMap { Data(relayBase64URL: $0) }.filter { $0.count == 32 }.compactMap {
            try? Curve25519.Signing.PublicKey(rawRepresentation: $0)
        }
    }
}

public protocol RelayTransport: Sendable {
    /// Sends `request` and returns the raw answer. Implementations stop reading
    /// and throw once the body passes ``RelayClient/maxResponseBytes``.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionRelayTransport: RelayTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.expectedContentLength > Int64(RelayClient.maxResponseBytes) { throw URLError(.dataLengthExceedsMaximum) }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > RelayClient.maxResponseBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return (body, http)
    }
}

public enum RelayCallOutcome: Sendable, Equatable {
    /// The relay answered, signed by a pinned key over this very request.
    /// `retryAfter` comes from the signed body only (capped at a day).
    case confirmed(status: Int, body: Data, retryAfter: Int?)
    /// No answer, or one without a valid signature for this request.
    case transportError
}

public struct RelayClient: Sendable {
    public let host: String
    let transport: RelayTransport
    let pinnedKeys: [Curve25519.Signing.PublicKey]
    let clock: @Sendable () -> Date
    let makeNonce: @Sendable () -> String

    /// The relay never sends more than 64 KiB; anything over 256 KiB is not read.
    public static let maxResponseBytes = 262_144
    /// Request bodies of the app endpoints are capped at 4 KiB by the relay.
    public static let maxRequestBytes = 4096
    static let maxRetryAfter = 86400

    static let nonceHeader = "HL-Nonce"
    static let responseSignatureHeader = "HL-Relay-Signature"

    public init(
        host: String = HLPushRelayKeys.host,
        transport: RelayTransport = URLSessionRelayTransport(),
        pinnedKeys: [Curve25519.Signing.PublicKey] = HLPushRelayKeys.pinned,
        clock: @escaping @Sendable () -> Date = { .now },
        makeNonce: @escaping @Sendable () -> String = { RelayClient.freshNonce() }
    ) {
        self.host = host
        self.transport = transport
        self.pinnedKeys = pinnedKeys
        self.clock = clock
        self.makeNonce = makeNonce
    }

    /// `DELETE /v1/bindings/self` (`hl-unbind-v1`): the relay drops the
    /// binding and blocks the pair of device and instance until this binding
    /// key returns with a higher `seq` and a later `iat` (#190 §4).
    /// `iatOffset` is the relay's clock minus the device's, from a
    /// `stale_timestamp` answer (D1 (3)).
    public func revoke(
        apnsToken: Data,
        instanceId: String,
        bindingKey: Curve25519.Signing.PrivateKey,
        iatOffset: Int64 = 0
    ) async -> RelayCallOutcome {
        let iat = Int64(clock().timeIntervalSince1970) + iatOffset
        let tag = RelayEnvelope.tokenTag(of: apnsToken)
        let text = RelayStatement.unbind(host: host, instanceId: instanceId, tokenTag: tag, iat: iat)
        guard let signature = try? RelayStatement.sign(text, with: bindingKey) else { return .transportError }
        let body: [String: Any] = [
            "token": apnsToken.relayHex,
            "bindingKey": bindingKey.publicKey.rawRepresentation.relayBase64URL,
            "statement": ["instanceId": instanceId, "tokenTag": tag.relayHex, "iat": iat],
            "signature": signature.relayBase64URL
        ]
        return await call(method: "DELETE", path: "/v1/bindings/self", json: body)
    }

    /// `DELETE /v1/bindings/self/liveactivity` (`hl-la-withdraw-v1`): the
    /// Live Activity consent goes, the binding stays.
    public func revokeLiveActivity(
        apnsToken: Data,
        instanceId: String,
        bindingKey: Curve25519.Signing.PrivateKey
    ) async -> RelayCallOutcome {
        let iat = Int64(clock().timeIntervalSince1970)
        let tag = RelayEnvelope.tokenTag(of: apnsToken)
        let text = RelayStatement.liveActivityWithdraw(host: host, instanceId: instanceId, tokenTag: tag, iat: iat)
        guard let signature = try? RelayStatement.sign(text, with: bindingKey) else { return .transportError }
        let body: [String: Any] = [
            "token": apnsToken.relayHex,
            "bindingKey": bindingKey.publicKey.rawRepresentation.relayBase64URL,
            "statement": ["instanceId": instanceId, "tokenTag": tag.relayHex, "iat": iat],
            "signature": signature.relayBase64URL
        ]
        return await call(method: "DELETE", path: "/v1/bindings/self/liveactivity", json: body)
    }

    /// `GET /v1/bindings/self` (`hl-selfread-v1`): what the relay holds.
    public func readSelf(apnsToken: Data, bindingKey: Curve25519.Signing.PrivateKey) async -> RelayCallOutcome {
        let iat = Int64(clock().timeIntervalSince1970)
        let text = RelayStatement.selfRead(host: host, tokenTag: RelayEnvelope.tokenTag(of: apnsToken), iat: iat)
        guard let signature = try? RelayStatement.sign(text, with: bindingKey) else { return .transportError }
        return await call(method: "GET", path: "/v1/bindings/self", json: nil, headers: [
            "HL-Token": apnsToken.relayHex,
            "HL-Binding-Key": bindingKey.publicKey.rawRepresentation.relayBase64URL,
            "HL-Iat": String(iat),
            "HL-Signature": signature.relayBase64URL
        ])
    }

    /// `POST /v1/bindings/challenge` (`hl-challenge-v1`): `challenge` exactly
    /// as received in the push's `c`.
    public func answerChallenge(_ challenge: String, apnsToken: Data, bindingKey: Curve25519.Signing.PrivateKey) async -> RelayCallOutcome {
        let tag = RelayEnvelope.tokenTag(of: apnsToken)
        let text = RelayStatement.challenge(host: host, challenge: challenge, tokenTag: tag)
        guard let signature = try? RelayStatement.sign(text, with: bindingKey) else { return .transportError }
        let body: [String: Any] = [
            "bindingKey": bindingKey.publicKey.rawRepresentation.relayBase64URL,
            "challenge": challenge,
            "tokenTag": tag.relayHex,
            "signature": signature.relayBase64URL
        ]
        return await call(method: "POST", path: "/v1/bindings/challenge", json: body)
    }

    /// The request as sent: `HL-Nonce`, and for `POST` and `DELETE` a body
    /// with its declared `Content-Length` (the relay answers `411` without
    /// it). `nil` when the body would pass 4 KiB.
    func request(method: String, path: String, nonce: String, json: [String: Any]?, headers: [String: String]) -> URLRequest? {
        guard let url = URL(string: "https://\(host)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(nonce, forHTTPHeaderField: Self.nonceHeader)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let json {
            guard let body = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
                  body.count <= Self.maxRequestBytes else { return nil }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
            request.httpBody = body
        } else if method != "GET" {
            request.setValue("0", forHTTPHeaderField: "Content-Length")
        }
        return request
    }

    private func call(method: String, path: String, json: [String: Any]?, headers: [String: String] = [:]) async -> RelayCallOutcome {
        let nonce = makeNonce()
        guard let request = request(method: method, path: path, nonce: nonce, json: json, headers: headers),
              let answer = try? await transport.send(request) else { return .transportError }
        let (data, response) = answer
        return verify(response: response, body: data, method: method, pathWithQuery: path, nonce: nonce)
    }

    /// §0: rebuild the text from the own request and the raw answer and check
    /// it against `current`, then `next`. An answer bound to `-` although a
    /// nonce was sent, or a body over the cap, is a transport error.
    func verify(response: HTTPURLResponse, body: Data, method: String, pathWithQuery: String, nonce: String) -> RelayCallOutcome {
        guard nonce != "-", body.count <= Self.maxResponseBytes,
              let header = response.value(forHTTPHeaderField: Self.responseSignatureHeader),
              let signature = Data(relayBase64URL: header), signature.count == 64 else { return .transportError }
        let text = RelayStatement.response(
            host: host,
            method: method,
            pathWithQuery: pathWithQuery,
            nonce: nonce,
            status: response.statusCode,
            body: body
        )
        guard pinnedKeys.contains(where: { RelayStatement.verify(text, signature: signature, publicKey: $0) }) else {
            return .transportError
        }
        return .confirmed(status: response.statusCode, body: body, retryAfter: Self.retryAfter(in: body))
    }

    /// `retryAfter` from the signed JSON body, never from the header.
    static func retryAfter(in body: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let value = (object["retryAfter"] as? NSNumber)?.intValue, value >= 0 else { return nil }
        return min(value, maxRetryAfter)
    }

    /// 16 bytes from the system CSPRNG, unpadded base64url, 22 characters.
    public static func freshNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).relayBase64URL
    }
}
