// swiftlint:disable force_unwrapping
import CryptoKit
import Foundation
@testable import HealthLog

/// A sealer for tests only: the device never seals, the server does. Uses
/// CryptoKit's sender with a fresh ephemeral key, like a production sealer.
enum RelayTestSealer {
    static func seal(
        _ json: [String: Any],
        to recipient: Curve25519.KeyAgreement.PublicKey,
        from sender: Curve25519.KeyAgreement.PrivateKey,
        apnsToken: Data,
        pushClass: RelayPushClass
    ) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        var padded = Data([UInt8(body.count >> 8), UInt8(body.count & 0xFF)]) + body
        padded += Data(count: pushClass.bucket - padded.count)
        let header = Data([RelayEnvelope.version, RelayEnvelope.suite, pushClass.classByte])
        var hpke = try HPKE.Sender(
            recipientKey: recipient,
            ciphersuite: RelayEnvelope.ciphersuite,
            info: RelayEnvelope.info,
            authenticatedBy: sender
        )
        let ciphertext = try hpke.seal(padded, authenticating: header + RelayEnvelope.tokenTag(of: apnsToken))
        return header + hpke.encapsulatedKey + ciphertext
    }

    static func ulid(_ number: Int) -> String {
        "01JTESTAPP" + String(format: "%016d", number)
    }
}

/// Records the relay calls and answers them signed with a test relay key.
final class RecordingRelayTransport: RelayTransport, @unchecked Sendable {
    // `@unchecked`: `requests` is only touched under `lock`.
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let relayKey = Curve25519.Signing.PrivateKey()
    let status: Int
    let host: String

    init(status: Int = 200, host: String = HLPushRelayKeys.host) {
        self.status = status
        self.host = host
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: URLRequest) {
        lock.withLock { recorded.append(request) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let body = Data("{}".utf8)
        let nonce = request.value(forHTTPHeaderField: RelayClient.nonceHeader) ?? "-"
        var path = request.url?.path ?? "/"
        if let query = request.url?.query { path += "?" + query }
        let text = RelayStatement.response(
            host: host,
            method: request.httpMethod ?? "GET",
            pathWithQuery: path,
            nonce: nonce,
            status: status,
            body: body
        )
        let signature = try RelayStatement.sign(text, with: relayKey)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: [RelayClient.responseSignatureHeader: signature.relayBase64URL]
        )!
        return (body, response)
    }
}

/// A transport that never answers, as with the relay down.
struct FailingRelayTransport: RelayTransport {
    func send(_: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.cannotConnectToHost)
    }
}
