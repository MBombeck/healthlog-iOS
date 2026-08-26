import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Illness re-enable flow (v1.18.3 §1 — born-gating dropped). Asserts the full
/// contract: `illness` is ON when absent from the map (default-on), a user can
/// disable it (`illness:false`), and `ModuleGate.setEnabled(.illness, true)`
/// PATCHes the per-key body and reconciles the echoed map → ON. Real `APIClient`
/// + stub `URLProtocol` (the PATCH echoes the resolved `modules`).
@MainActor
@Suite("Illness re-enable flow (v1.18.3)", .serialized)
struct IllnessOptInFlowTests {
    private func makeGate() -> ModuleGate {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.18.1",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        return ModuleGate(repo: ModuleGateRepository(api: api))
    }

    @Test("Absent illness key → ON (default-on; v1.18.3)")
    func absentIsOn() {
        let gate = makeGate()
        #expect(gate.isEnabled(.illness) == true)
    }

    @Test("A user-disabled illness (present-false) → OFF")
    func disabledIsOff() {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "1.18.3",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        let gate = ModuleGate(repo: ModuleGateRepository(api: api), modules: ["illness": false])
        #expect(gate.isEnabled(.illness) == false)
    }

    @Test("setEnabled(.illness, true) re-enables: PATCHes per-key + reconciles map → ON")
    func reEnableFlipsOn() async {
        nonisolated(unsafe) var patchedBody: [String: Bool]?
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/auth/me/modules")
            #expect(req.httpMethod == "PATCH")
            // URLProtocol swaps httpBody into httpBodyStream — re-materialize.
            let data = req.httpBody ?? illnessReadStream(req.httpBodyStream)
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
                patchedBody = json
            }
            // The server echoes the freshly-resolved modules map.
            let body = Data(#"{"data":{"modules":{"illness":true}},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        // Start from a user-disabled state (the only way to reach the re-enable
        // surface now that illness is default-on).
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "1.18.3",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let gate = ModuleGate(repo: ModuleGateRepository(api: api), modules: ["illness": false])
        #expect(gate.isEnabled(.illness) == false)
        let ok = await gate.setEnabled(.illness, enabled: true)
        #expect(ok)
        // The PATCH body carries ONLY the single toggled key.
        #expect(patchedBody == ["illness": true])
        // The echoed map reconciles → illness ON.
        #expect(gate.isEnabled(.illness) == true)
    }

    @Test("A failed re-enable PATCH restores the previous (disabled) state")
    func reEnableFailureRollsBack() async {
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":"boom"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, body)
        }
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "1.18.3",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        let gate = ModuleGate(repo: ModuleGateRepository(api: api), modules: ["illness": false])
        let ok = await gate.setEnabled(.illness, enabled: true)
        #expect(!ok)
        // Rolled back to the previous user-disabled state (OFF).
        #expect(gate.isEnabled(.illness) == false)
    }
}

/// `URLProtocol` swaps `httpBody` into `httpBodyStream` — re-materialize.
/// Free function so the `@Sendable` stub handler can call it without crossing
/// the `@MainActor` test type's isolation.
private func illnessReadStream(_ stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: bufferSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

// swiftlint:enable force_unwrapping
