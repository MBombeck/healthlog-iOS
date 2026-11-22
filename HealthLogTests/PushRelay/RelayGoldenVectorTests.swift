// swiftlint:disable force_unwrapping
import CryptoKit
import Foundation
@testable import HealthLog
import Testing

/// The relay's golden vectors (`spec/vectors/v1.json` of the relay repository,
/// copied unchanged to `Fixtures/relay-vectors-v1.json`): every envelope opens
/// or fails with exactly the recorded code, every statement text this app
/// builds is the recorded text, every recorded signature verifies, and every
/// negative statement fails.
@Suite("Push relay: golden vectors v1")
struct RelayGoldenVectorTests {
    struct Vectors: Decodable {
        struct Constants: Decodable {
            let host: String
            let now: Int64
            let info: String
            let envelopeLength: [String: Int]
            let maxTtlSeconds: [String: Int64]
            let clockSkewSeconds: Int64
        }

        struct Keys: Decodable {
            let recipientPublicKey: String
            let recipientPrivateKey: String
            let recipientKeyIdApiOnly: String
            let senderPublicKey: String
            let senderPrivateKey: String
            let bindingSeed: String
            let relaySeed: String
            let instanceId: String
            let laToken: String
            let apnsToken: String
            let nonce: String
        }

        struct TokenTag: Decodable {
            let token: String
            let tokenTag: String
        }

        struct Envelope: Decodable {
            let name: String
            let recipientKeys: [String]
            let trustedSenders: [String]
            let apnsToken: String
            let expectedClass: String
            let now: Int64
            let envelope: String
            let expect: String
            let plaintext: RelayJSON?
        }

        struct Statement: Decodable {
            let name: String
            let publicKey: String
            let text: String
            let signature: String
            let body: String?
        }

        struct Negative: Decodable {
            let name: String
            let of: String
            let text: String
        }

        let constants: Constants
        let keys: Keys
        let tokenTags: [TokenTag]
        let aad: [String: String]
        let envelopes: [Envelope]
        let statements: [Statement]
        let negativeStatements: [Negative]
    }

    static let vectors: Vectors = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/relay-vectors-v1.json")
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    static func hex(_ text: String) -> Data {
        Data(relayHex: text)!
    }

    @Test("constants match the app's envelope parameters")
    func constants() {
        let c = Self.vectors.constants
        #expect(c.info == String(data: RelayEnvelope.info, encoding: .utf8))
        #expect(c.clockSkewSeconds == RelayEnvelope.clockSkew)
        for pushClass in RelayPushClass.allCases {
            #expect(c.envelopeLength[pushClass.rawValue] == pushClass.envelopeLength)
            #expect(c.maxTtlSeconds[pushClass.rawValue] == pushClass.maxLifetime)
        }
        #expect(c.host == HLPushRelayKeys.host)
    }

    @Test("token tags, the AAD and the API key id")
    func tags() throws {
        for tag in Self.vectors.tokenTags {
            #expect(RelayEnvelope.tokenTag(of: Self.hex(tag.token)).relayHex == tag.tokenTag)
        }
        let token = Self.hex(Self.vectors.keys.apnsToken)
        let header = Data([RelayEnvelope.version, RelayEnvelope.suite, RelayPushClass.alert.classByte])
        #expect((header + RelayEnvelope.tokenTag(of: token)).relayHex == Self.vectors.aad["alert"])
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.hex(Self.vectors.keys.recipientPrivateKey))
        #expect(recipient.publicKey.rawRepresentation.relayHex == Self.vectors.keys.recipientPublicKey)
        #expect(RelayEnvelope.keyId(of: recipient.publicKey.rawRepresentation).relayHex == Self.vectors.keys.recipientKeyIdApiOnly)
    }

    @Test("every envelope vector opens or fails with its recorded code", arguments: RelayGoldenVectorTests.vectors.envelopes.map(\.name))
    func envelope(name: String) throws {
        let vector = try #require(Self.vectors.envelopes.first { $0.name == name })
        let recipients = try vector.recipientKeys.map { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.hex($0)) }
        let senders = try vector.trustedSenders.map { try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Self.hex($0)) }
        let envelope = try #require(Data(relayBase64URL: vector.envelope))
        let pushClass = try #require(RelayPushClass(rawValue: vector.expectedClass))
        let result: Result<RelayPlaintext, RelayEnvelopeError>
        do {
            result = try .success(RelayEnvelope.open(
                envelope,
                recipientKeys: recipients,
                trustedSenders: senders,
                apnsToken: Self.hex(vector.apnsToken),
                expectedClass: pushClass,
                now: vector.now
            ))
        } catch {
            result = .failure(error)
        }
        switch result {
        case let .success(plaintext):
            #expect(vector.expect == "ok", "\(name) opened but should fail with \(vector.expect)")
            #expect(plaintext.json == vector.plaintext, "\(name): plaintext differs")
        case let .failure(error):
            #expect(error.rawValue == vector.expect, "\(name)")
        }
    }

    @Test("the vectors cover every error code the device can raise from bytes alone")
    func coverage() {
        let codes = Set(Self.vectors.envelopes.map(\.expect))
        let byteCodes: Set = [
            "ok",
            "malformed",
            "unsupportedVersion",
            "classMismatch",
            "authFailure",
            "lifetimeTooLong",
            "notYetValid",
            "expired"
        ]
        #expect(byteCodes.isSubset(of: codes))
    }

    @Test("the binding key from the seed is the recorded key")
    func bindingKey() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.hex(Self.vectors.keys.bindingSeed))
        let bind = try #require(Self.vectors.statements.first { $0.name == "bind" })
        #expect(key.publicKey.rawRepresentation.relayBase64URL == bind.publicKey)
    }

    @Test("the app builds the recorded statement texts")
    func statementTexts() throws {
        let v = Self.vectors
        let host = v.constants.host
        let now = v.constants.now
        let tag = RelayEnvelope.tokenTag(of: Self.hex(v.keys.apnsToken))
        let laTag = RelayEnvelope.tokenTag(of: Self.hex(v.keys.laToken))
        func text(_ name: String) throws -> String {
            try #require(v.statements.first { $0.name == name }).text
        }
        #expect(try text("bind") == RelayStatement.bind(host: host, instanceId: v.keys.instanceId, tokenTag: tag, seq: 7, iat: now))
        #expect(try text("unbind") == RelayStatement.unbind(host: host, instanceId: v.keys.instanceId, tokenTag: tag, iat: now))
        let challenge = Data(repeating: 0x63, count: 32).relayBase64URL
        #expect(try text("challenge") == RelayStatement.challenge(host: host, challenge: challenge, tokenTag: tag))
        #expect(try text("activity") == RelayStatement.activity(
            host: host,
            instanceId: v.keys.instanceId,
            tokenTag: tag,
            laTokenTag: laTag,
            iat: now
        ))
        #expect(try text("selfRead") == RelayStatement.selfRead(host: host, tokenTag: tag, iat: now))
        #expect(try text("laConsent") == RelayStatement.liveActivityConsent(
            host: host, instanceId: v.keys.instanceId, tokenTag: tag, textVersion: "2026-11-21", iat: now
        ))
        #expect(try text("laWithdraw") == RelayStatement.liveActivityWithdraw(
            host: host,
            instanceId: v.keys.instanceId,
            tokenTag: tag,
            iat: now
        ))
        #expect(try text("laStart") == RelayStatement.liveActivityStart(
            host: host, instanceId: v.keys.instanceId, tokenTag: tag, startTokenTag: laTag, iat: now
        ))
        for (name, method, path, nonce, status) in [
            ("response", "POST", "/v1/push", v.keys.nonce, 200),
            ("responseAppEndpoint", "DELETE", "/v1/bindings/self", v.keys.nonce, 204),
            ("responseWithoutNonce", "GET", "/healthz", "-", 200)
        ] {
            let response = try #require(v.statements.first { $0.name == name })
            #expect(response.text == RelayStatement.response(
                host: host,
                method: method,
                pathWithQuery: path,
                nonce: nonce,
                status: status,
                body: Data((response.body ?? "").utf8)
            ), "\(name)")
        }
    }

    @Test("every recorded signature verifies", arguments: RelayGoldenVectorTests.vectors.statements.map(\.name))
    func signatureVerifies(name: String) throws {
        let statement = try #require(Self.vectors.statements.first { $0.name == name })
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: #require(Data(relayBase64URL: statement.publicKey)))
        let signature = try #require(Data(relayBase64URL: statement.signature))
        #expect(RelayStatement.verify(statement.text, signature: signature, publicKey: key))
    }

    @Test(
        "every negative statement fails against the original signature",
        arguments: RelayGoldenVectorTests.vectors.negativeStatements.map(\.name)
    )
    func negativeFails(name: String) throws {
        let negative = try #require(Self.vectors.negativeStatements.first { $0.name == name })
        let statement = try #require(Self.vectors.statements.first { $0.name == negative.of })
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: #require(Data(relayBase64URL: statement.publicKey)))
        let signature = try #require(Data(relayBase64URL: statement.signature))
        #expect(!RelayStatement.verify(negative.text, signature: signature, publicKey: key))
    }

    @Test("a signature this app makes verifies under the recorded text and key")
    func appSignatureVerifies() throws {
        let v = Self.vectors
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.hex(v.keys.bindingSeed))
        let bind = try #require(v.statements.first { $0.name == "bind" })
        let signature = try RelayStatement.sign(bind.text, with: key)
        #expect(RelayStatement.verify(bind.text, signature: signature, publicKey: key.publicKey))
    }

    /// The client's check of §0, run against the recorded relay answers.
    private func check(
        _ name: String,
        method: String,
        path: String,
        nonce: String,
        status: Int,
        keys: [Curve25519.Signing.PublicKey]
    ) throws -> RelayCallOutcome {
        let v = Self.vectors
        let response = try #require(v.statements.first { $0.name == name })
        let url = try #require(URL(string: "https://\(v.constants.host)\(path)"))
        let http = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: [RelayClient.responseSignatureHeader: response.signature]
        ))
        return RelayClient(pinnedKeys: keys).verify(
            response: http,
            body: Data((response.body ?? "").utf8),
            method: method,
            pathWithQuery: path,
            nonce: nonce
        )
    }

    /// The relay identity key of the vectors (seed `31…`).
    private var relayKey: Curve25519.Signing.PublicKey {
        // swiftlint:disable:next force_try
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Self.hex(Self.vectors.keys.relaySeed)).publicKey
    }

    @Test("hl-relay-resp-v2: the recorded answers verify, against current and against next")
    func responsesVerify() throws {
        let nonce = Self.vectors.keys.nonce
        let other = Curve25519.Signing.PrivateKey().publicKey
        #expect(try check("response", method: "POST", path: "/v1/push", nonce: nonce, status: 200, keys: [relayKey])
            == .confirmed(status: 200, body: Data(#"{"items":[]}"#.utf8), retryAfter: nil))
        #expect(
            try check(
                "responseAppEndpoint",
                method: "DELETE",
                path: "/v1/bindings/self",
                nonce: nonce,
                status: 204,
                keys: [other, relayKey]
            )
                == .confirmed(status: 204, body: Data(), retryAfter: nil),
            "the next key is tried after current"
        )
        #expect(try check("response", method: "POST", path: "/v1/push", nonce: nonce, status: 200, keys: []) == .transportError)
    }

    @Test("hl-relay-resp-v2: an answer bound to - is a transport error, though its signature is valid")
    func responseWithoutNonceRefused() throws {
        #expect(try check("responseWithoutNonce", method: "GET", path: "/healthz", nonce: "-", status: 200, keys: [relayKey]) ==
            .transportError)
    }

    @Test("hl-relay-resp-v2: another nonce, status, method or path, or a replay onto another request, fails")
    func responseNegatives() throws {
        let nonce = Self.vectors.keys.nonce
        let otherNonce = Data(repeating: 0x4F, count: 16).relayBase64URL
        #expect(try check("response", method: "POST", path: "/v1/push", nonce: otherNonce, status: 200, keys: [relayKey]) ==
            .transportError)
        #expect(try check("response", method: "POST", path: "/v1/push", nonce: nonce, status: 410, keys: [relayKey]) == .transportError)
        #expect(try check("response", method: "GET", path: "/v1/push", nonce: nonce, status: 200, keys: [relayKey]) == .transportError)
        #expect(try check("response", method: "POST", path: "/v1/status", nonce: nonce, status: 200, keys: [relayKey]) == .transportError)
        let replayNonce = Data(repeating: 0x50, count: 16).relayBase64URL
        #expect(try check(
            "responseAppEndpoint",
            method: "DELETE",
            path: "/v1/bindings/self",
            nonce: replayNonce,
            status: 204,
            keys: [relayKey]
        )
            == .transportError)
        for name in [
            "responseOtherNonce",
            "responseOtherStatus",
            "responseOtherMethod",
            "responseOtherPath",
            "responseAppReplayedOntoOtherRequest"
        ] {
            #expect(Self.vectors.negativeStatements.contains { $0.name == name }, "\(name) is in the vectors")
        }
    }

    @Test("retryAfter comes from the signed body only, capped at a day; an oversized body is refused")
    func retryAfterAndSize() throws {
        #expect(RelayClient.retryAfter(in: Data(#"{"error":"device_quota","retryAfter":41}"#.utf8)) == 41)
        #expect(RelayClient.retryAfter(in: Data(#"{"retryAfter":999999}"#.utf8)) == 86400)
        #expect(RelayClient.retryAfter(in: Data()) == nil)
        let url = try #require(URL(string: "https://push.healthlog.dev/v1/bindings/self"))
        let http = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Retry-After": "5", RelayClient.responseSignatureHeader: String(repeating: "A", count: 86)
        ]))
        let big = Data(count: RelayClient.maxResponseBytes + 1)
        #expect(RelayClient(pinnedKeys: [relayKey]).verify(
            response: http, body: big, method: "GET", pathWithQuery: "/v1/bindings/self", nonce: Self.vectors.keys.nonce
        ) == .transportError)
    }

    @Test("the pinned host is the vectors' host, and pinned keys are empty or valid 32-byte keys")
    func pinnedKeys() {
        #expect(HLPushRelayPin.host == Self.vectors.constants.host)
        #expect(HLPushRelayPin.current.isEmpty == HLPushRelayPin.next.isEmpty)
        if !HLPushRelayPin.current.isEmpty {
            #expect(HLPushRelayKeys.pinned.count == (HLPushRelayPin.emergency.isEmpty ? 2 : 3))
        }
        #expect(HLPushRelayPin.emergency.isEmpty || !HLPushRelayPin.current.isEmpty)
        #expect(HLPushRelayKeys.keys(current: "", next: "").isEmpty)
    }
}
