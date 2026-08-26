import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks: `X-Device-Id` ist auf jedem Request gesetzt, über Lifetime stabil
/// und persistiert in der Keychain (siehe `05-auth-flows.md §9` + W2a-A2 §3).
@Suite("X-Device-Id header", .serialized)
struct DeviceIDHeaderTests {
    private func makeAPI(keychain: InMemoryKeychain = InMemoryKeychain()) -> (APIClient, InMemoryKeychain) {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return (
            APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock()),
            keychain
        )
    }

    @Test("Sends X-Device-Id on every request")
    func headerPresent() async {
        let (api, _) = makeAPI()
        nonisolated(unsafe) var captured: String?
        MockURLProtocol.handler = { req in
            captured = req.value(forHTTPHeaderField: "X-Device-Id")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null}"#.utf8)
            )
        }
        let req: APIRequest<EmptyPayload> = .get("/api/x")
        _ = try? await api.send(req)
        #expect(captured != nil)
        #expect(captured?.isEmpty == false)
    }

    @Test("X-Device-Id is stable across sequential requests")
    func headerStable() async {
        let (api, _) = makeAPI()
        nonisolated(unsafe) var ids: [String] = []
        MockURLProtocol.handler = { req in
            if let v = req.value(forHTTPHeaderField: "X-Device-Id") { ids.append(v) }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null}"#.utf8)
            )
        }
        for _ in 0 ..< 4 {
            let req: APIRequest<EmptyPayload> = .get("/api/x")
            _ = try? await api.send(req)
        }
        #expect(ids.count == 4)
        #expect(Set(ids).count == 1, "device-id must be stable, got \(ids)")
    }

    @Test("X-Device-Id persists across APIClient instances (keychain shared)")
    func headerPersists() async {
        let kc = InMemoryKeychain()
        let (api1, _) = makeAPI(keychain: kc)
        nonisolated(unsafe) var first: String?
        MockURLProtocol.handler = { req in
            first = req.value(forHTTPHeaderField: "X-Device-Id")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null}"#.utf8)
            )
        }
        let r1: APIRequest<EmptyPayload> = .get("/api/x")
        _ = try? await api1.send(r1)

        let (api2, _) = makeAPI(keychain: kc)
        nonisolated(unsafe) var second: String?
        MockURLProtocol.handler = { req in
            second = req.value(forHTTPHeaderField: "X-Device-Id")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null}"#.utf8)
            )
        }
        let r2: APIRequest<EmptyPayload> = .get("/api/x")
        _ = try? await api2.send(r2)

        #expect(first != nil)
        #expect(first == second)
    }

    @Test("Generated device-id is a lowercase UUID-shape")
    func headerShape() throws {
        let kc = InMemoryKeychain()
        let id = try kc.deviceID()
        // 36 chars, hyphens at the canonical positions, lowercase.
        #expect(id.count == 36)
        let lower = id.lowercased()
        #expect(id == lower)
        #expect(UUID(uuidString: id) != nil)
    }
}
