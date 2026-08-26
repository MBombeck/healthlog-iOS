import Foundation
@testable import HealthLog

// MARK: - Scripted transport (Phase 08 Wave 0)

/// A per-store `APIClientProtocol` whose every response is decided by one
/// closure the test owns. Nothing here is process-global, so two stores in the
/// same test never see each other's script.
final class ScriptedDocumentsAPI: APIClientProtocol, @unchecked Sendable {
    typealias Route = @Sendable (
        _ method: HTTPMethod,
        _ path: String,
        _ query: [(String, String)]
    ) async throws -> any Sendable

    private let lock = NSLock()
    private var storedRoute: Route?

    var route: Route? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedRoute
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedRoute = newValue
        }
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        let value = try await resolve(request.method, request.path, request.query)
        guard let typed = value as? T else {
            throw HLError.decoding("scripted route returned \(type(of: value)) where \(T.self) was expected")
        }
        return typed
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        _ = try await resolve(request.method, request.path, request.query)
    }

    func download(_ request: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        let value = try await resolve(request.method, request.path, request.query)
        guard let data = value as? Data,
              let url = URL(string: "https://scripted.healthlog.local\(request.path)"),
              let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil) else
        {
            throw HLError.decoding("scripted route returned no downloadable body for \(request.path)")
        }
        return (data, response)
    }

    private func resolve(
        _ method: HTTPMethod,
        _ path: String,
        _ query: [(String, String)]
    ) async throws -> any Sendable {
        guard let route else { throw HLError.unknown("no scripted route for \(method.rawValue) \(path)") }
        return try await route(method, path, query)
    }
}

/// The continuation the test holds. `holdUntilReleased()` parks the scripted
/// response inside the store's `await`, `waitUntilHeld()` lets the test observe
/// that it is parked, and `release()` lets it finish — so "A finishes after B"
/// is an ordering the test states, never one it waits out.
actor DocumentScript {
    private var usageCalls = 0
    private var heldContinuation: CheckedContinuation<Void, Never>?
    private var observerContinuation: CheckedContinuation<Void, Never>?
    private var isHeld = false
    private var isReleased = false

    func nextUsage() -> Int {
        usageCalls += 1
        return usageCalls
    }

    func holdUntilReleased() async {
        isHeld = true
        observerContinuation?.resume()
        observerContinuation = nil
        guard !isReleased else { return }
        await withCheckedContinuation { heldContinuation = $0 }
    }

    func waitUntilHeld() async {
        guard !isHeld else { return }
        await withCheckedContinuation { observerContinuation = $0 }
    }

    func release() {
        isReleased = true
        heldContinuation?.resume()
        heldContinuation = nil
    }

    /// Re-arm for a second hold in the same test.
    func rearm() {
        isHeld = false
        isReleased = false
    }
}
