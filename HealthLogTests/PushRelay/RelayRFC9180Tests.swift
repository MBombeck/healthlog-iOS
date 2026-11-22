// swiftlint:disable force_unwrapping
import CryptoKit
import Foundation
@testable import HealthLog
import Testing

/// RFC 9180 A.2.1 (base) and A.2.3 (auth), DHKEM(X25519, HKDF-SHA256),
/// HKDF-SHA256, ChaCha20-Poly1305, sequence 0, byte for byte.
///
/// Two halves: CryptoKit's `HPKE.Recipient`, the type the envelope opens with,
/// must open the RFC ciphertext to the RFC plaintext; and a key schedule
/// written out from the RFC must reproduce the shared secret, key, nonce and
/// ciphertext, so the suite and the info string are pinned, not only "it opens".
@Suite("Push relay: RFC 9180 A.2.1 and A.2.3")
struct RelayRFC9180Tests {
    private static func hex(_ text: String) -> Data {
        Data(relayHex: text)!
    }

    static let info = hex("4f6465206f6e2061204772656369616e2055726e")
    static let plaintext = hex("4265617574792069732074727574682c20747275746820626561757479")
    static let aad = hex("436f756e742d30")

    struct Vector {
        let skEm, pkRm, skRm, enc, shared, key, nonce, ct: Data
        var skSm: Data?
        var pkSm: Data?
    }

    static let base = Vector(
        skEm: hex("f4ec9b33b792c372c1d2c2063507b684ef925b8c75a42dbcbf57d63ccd381600"),
        pkRm: hex("4310ee97d88cc1f088a5576c77ab0cf5c3ac797f3d95139c6c84b5429c59662a"),
        skRm: hex("8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb"),
        enc: hex("1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a"),
        shared: hex("0bbe78490412b4bbea4812666f7916932b828bba79942424abb65244930d69a7"),
        key: hex("ad2744de8e17f4ebba575b3f5f5a8fa1f69c2a07f6e7500bc60ca6e3e3ec1c91"),
        nonce: hex("5c4d98150661b848853b547f"),
        ct: hex("1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db21993c62ce81883d2dd1b51a28")
    )

    static let auth = Vector(
        skEm: hex("c94619e1af28971c8fa7957192b7e62a71ca2dcdde0a7cc4a8a9e741d600ab13"),
        pkRm: hex("1a478716d63cb2e16786ee93004486dc151e988b34b475043d3e0175bdb01c44"),
        skRm: hex("3ca22a6d1cda1bb9480949ec5329d3bf0b080ca4c45879c95eddb55c70b80b82"),
        enc: hex("f7674cc8cd7baa5872d1f33dbaffe3314239f6197ddf5ded1746760bfc847e0e"),
        shared: hex("d2d67828c8bc9fa661cf15a31b3ebf1febe0cafef7abfaaca580aaf6d471e3eb"),
        key: hex("b071fd1136680600eb447a845a967d35e9db20749cdf9ce098bcc4deef4b1356"),
        nonce: hex("d20577dff16d7cea2c4bf780"),
        ct: hex("ab1a13c9d4f01a87ec3440dbd756e2677bd2ecf9df0ce7ed73869b98e00c09be111cb9fdf077347aeb88e61bdf"),
        skSm: hex("2def0cb58ffcf83d1062dd085c8aceca7f4c0c3fd05912d847b61f3e54121f05"),
        pkSm: hex("f0f4f9e96c54aeed3f323de8534fffd7e0577e4ce269896716bcb95643c8712b")
    )

    @Test("A.2.1 base: CryptoKit opens the RFC ciphertext")
    func baseOpens() throws {
        let v = Self.base
        let skR = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.skRm)
        #expect(skR.publicKey.rawRepresentation == v.pkRm)
        #expect(try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.skEm).publicKey.rawRepresentation == v.enc)
        var recipient = try HPKE.Recipient(
            privateKey: skR,
            ciphersuite: RelayEnvelope.ciphersuite,
            info: Self.info,
            encapsulatedKey: v.enc
        )
        #expect(try recipient.open(v.ct, authenticating: Self.aad) == Self.plaintext)
    }

    @Test("A.2.3 auth: CryptoKit opens the RFC ciphertext with the sender key")
    func authOpens() throws {
        let v = Self.auth
        let skR = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.skRm)
        let skS = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: #require(v.skSm))
        #expect(skR.publicKey.rawRepresentation == v.pkRm)
        #expect(skS.publicKey.rawRepresentation == v.pkSm)
        var recipient = try HPKE.Recipient(
            privateKey: skR,
            ciphersuite: RelayEnvelope.ciphersuite,
            info: Self.info,
            encapsulatedKey: v.enc,
            authenticatedBy: skS.publicKey
        )
        #expect(try recipient.open(v.ct, authenticating: Self.aad) == Self.plaintext)
    }

    @Test("A.2.3 auth: a different sender key does not open")
    func authRejectsOtherSender() throws {
        let v = Self.auth
        let skR = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.skRm)
        let other = Curve25519.KeyAgreement.PrivateKey().publicKey
        var recipient = try HPKE.Recipient(
            privateKey: skR,
            ciphersuite: RelayEnvelope.ciphersuite,
            info: Self.info,
            encapsulatedKey: v.enc,
            authenticatedBy: other
        )
        #expect(throws: (any Error).self) { try recipient.open(v.ct, authenticating: Self.aad) }
    }

    @Test("A.2.1 and A.2.3: the written-out key schedule matches byte for byte", arguments: [false, true])
    func keySchedule(authMode: Bool) throws {
        let v = authMode ? Self.auth : Self.base
        let skE = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: v.skEm)
        let pkR = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: v.pkRm)
        var dh = try Reference.dh(skE, pkR)
        var kemContext = v.enc + v.pkRm
        if authMode {
            let skS = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: #require(v.skSm))
            dh += try Reference.dh(skS, pkR)
            kemContext += try #require(v.pkSm)
        }
        let shared = Reference.extractAndExpand(dh: dh, kemContext: kemContext)
        #expect(shared == v.shared)
        let (key, nonce) = Reference.schedule(mode: authMode ? 0x02 : 0x00, shared: shared, info: Self.info)
        #expect(key == v.key)
        #expect(nonce == v.nonce)
        let sealed = try ChaChaPoly.seal(
            Self.plaintext,
            using: SymmetricKey(data: key),
            nonce: ChaChaPoly.Nonce(data: nonce),
            authenticating: Self.aad
        )
        #expect(sealed.ciphertext + sealed.tag == v.ct)
    }

    /// RFC 9180 sections 4 and 5.1, spelled out with CryptoKit primitives.
    enum Reference {
        static let kemSuite = Data("KEM".utf8) + Data([0x00, 0x20])
        static let hpkeSuite = Data("HPKE".utf8) + Data([0x00, 0x20, 0x00, 0x01, 0x00, 0x03])

        static func dh(_ sk: Curve25519.KeyAgreement.PrivateKey, _ pk: Curve25519.KeyAgreement.PublicKey) throws -> Data {
            try sk.sharedSecretFromKeyAgreement(with: pk).withUnsafeBytes { Data($0) }
        }

        static func extract(salt: Data, ikm: Data) -> Data {
            let saltKey = SymmetricKey(data: salt.isEmpty ? Data(count: 32) : salt)
            return Data(HMAC<SHA256>.authenticationCode(for: ikm, using: saltKey))
        }

        static func expand(prk: Data, info: Data, length: Int) -> Data {
            var output = Data()
            var block = Data()
            var counter: UInt8 = 1
            while output.count < length {
                block = Data(HMAC<SHA256>.authenticationCode(for: block + info + Data([counter]), using: SymmetricKey(data: prk)))
                output += block
                counter += 1
            }
            return output.prefix(length)
        }

        static func labeledExtract(_ suite: Data, salt: Data, label: String, ikm: Data) -> Data {
            extract(salt: salt, ikm: Data("HPKE-v1".utf8) + suite + Data(label.utf8) + ikm)
        }

        static func labeledExpand(_ suite: Data, prk: Data, label: String, info: Data, length: Int) -> Data {
            let lengthBytes = Data([UInt8(length >> 8), UInt8(length & 0xFF)])
            return expand(prk: prk, info: lengthBytes + Data("HPKE-v1".utf8) + suite + Data(label.utf8) + info, length: length)
        }

        static func extractAndExpand(dh: Data, kemContext: Data) -> Data {
            let prk = labeledExtract(kemSuite, salt: Data(), label: "eae_prk", ikm: dh)
            return labeledExpand(kemSuite, prk: prk, label: "shared_secret", info: kemContext, length: 32)
        }

        static func schedule(mode: UInt8, shared: Data, info: Data) -> (key: Data, nonce: Data) {
            let pskIdHash = labeledExtract(hpkeSuite, salt: Data(), label: "psk_id_hash", ikm: Data())
            let infoHash = labeledExtract(hpkeSuite, salt: Data(), label: "info_hash", ikm: info)
            let context = Data([mode]) + pskIdHash + infoHash
            let secret = labeledExtract(hpkeSuite, salt: shared, label: "secret", ikm: Data())
            return (
                labeledExpand(hpkeSuite, prk: secret, label: "key", info: context, length: 32),
                labeledExpand(hpkeSuite, prk: secret, label: "base_nonce", info: context, length: 12)
            )
        }
    }
}
