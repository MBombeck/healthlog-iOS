// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog

/// **LIFE (1.5.0)** — a small in-memory life-circumstances server for the
/// store and repository tests: the fact writes change what the next read
/// returns, every request is recorded with its decoded body, and single
/// routes can be told to fail.
final class LifeServerStub: @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
        let body: [String: Any]
    }

    private struct Fact {
        let id: String
        let kind: String
        let value: Any
        let validFrom: String
    }

    private let lock = NSLock()
    private var facts: [Fact] = []
    private var aiIncluded: Set<String> = ["SMOKING_STATUS", "ACTIVITY", "WORK", "HABITS", "GOALS"]
    private var counter = 0
    private var log: [Recorded] = []
    /// `"METHOD /path"` → (status, body) answered instead of the normal route.
    private var overrides: [String: (Int, String)] = [:]
    /// The about-me token `GET /api/coach/about-me` answers with.
    var aboutMeToken: String? = "2026-11-01T08:00:00.000Z"
    /// AUDITC: the AUDIT-C routes and the read route's `auditC` block.
    private let auditCServer = AuditCServerStub()
    /// POLISH-C (C7): `false` reads like a server before AUDIT-C (no block).
    var offersAuditC = true

    /// Changes the AUDIT-C state under the lock the routes run under.
    func auditC<T>(_ change: (AuditCServerStub) -> T) -> T {
        lock.withLock { change(auditCServer) }
    }

    var requests: [Recorded] {
        lock.withLock { log }
    }

    func seed(kind: String, valueJSON: String, id: String) {
        let value = (try? JSONSerialization.jsonObject(with: Data(valueJSON.utf8), options: [.fragmentsAllowed])) ?? NSNull()
        lock.withLock { facts.append(Fact(id: id, kind: kind, value: value, validFrom: LifeCircumstancesFixtures.date)) }
    }

    func override(_ route: String, status: Int, body: String) {
        lock.withLock { overrides[route] = (status, body) }
    }

    func clearOverride(_ route: String) {
        lock.withLock { overrides[route] = nil }
    }

    func handle(_ request: URLRequest) -> (HTTPURLResponse, Data?) {
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path
        let body = Self.body(request)
        let (status, json) = lock.withLock { () -> (Int, String) in
            log.append(Recorded(method: method, path: path, body: body))
            if let forced = overrides["\(method) \(path)"] { return forced }
            return route(method: method, path: path, body: body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, Data(json.utf8))
    }

    private func route(method: String, path: String, body: [String: Any]) -> (Int, String) {
        typealias Fx = LifeCircumstancesFixtures
        switch (method, path) {
        case ("GET", "/api/anamnesis/life-circumstances"):
            return (200, Fx.envelope(payload()))
        case ("GET", "/api/anamnesis/facts"):
            return (200, Fx.envelope(legacyFacts()))
        case ("GET", "/api/coach/about-me"):
            let token = aboutMeToken.map { "\"\($0)\"" } ?? "null"
            return (200, Fx.envelope(#"{"aboutMe":"","updatedAt":\#(token)}"#))
        case ("POST", "/api/anamnesis/facts"):
            let kind = body["kind"] as? String ?? ""
            if facts.contains(where: { $0.kind == kind }) {
                return (409, #"{"data":null,"error":"exists","meta":{"errorCode":"anamnesis.fact.currentExists"}}"#)
            }
            let fact = next(kind: kind, value: body["value"] ?? NSNull(), body: body)
            facts.append(fact)
            return (201, Fx.envelope(revision(fact)))
        case ("PATCH", "/api/anamnesis/life-circumstances/ai-sections"):
            for (key, on) in body["sections"] as? [String: Bool] ?? [:] {
                if on { aiIncluded.insert(key) } else { aiIncluded.remove(key) }
            }
            return (200, Fx.envelope(#"{"aiSections":{},"updatedAt":"2026-11-04T09:00:00.000Z"}"#))
        case ("POST", "/api/anamnesis/life-circumstances/confirm"):
            return (200, Fx.envelope(#"{"section":"activity","lastConfirmedAt":"2026-11-04T09:00:00.000Z"}"#))
        default:
            if let answer = auditCServer.route(method: method, path: path, body: body) { return answer }
            return factRoute(method: method, path: path, body: body)
        }
    }

    private func factRoute(method: String, path: String, body: [String: Any]) -> (Int, String) {
        let prefix = "/api/anamnesis/facts/"
        let id = String(path.dropFirst(prefix.count))
        guard path.hasPrefix(prefix), let index = facts.firstIndex(where: { $0.id == id }) else {
            return (404, #"{"data":null,"error":"not found"}"#)
        }
        if method == "DELETE" {
            let old = facts.remove(at: index)
            return (200, LifeCircumstancesFixtures.envelope(#"{"id":"\#(old.id)","kind":"\#(old.kind)"}"#))
        }
        let fact = next(kind: facts[index].kind, value: body["value"] ?? NSNull(), body: body)
        facts[index] = fact
        return (200, LifeCircumstancesFixtures.envelope(revision(fact)))
    }

    private func next(kind: String, value: Any, body: [String: Any]) -> Fact {
        counter += 1
        let from = (body["validFrom"] as? String).map { "\($0)T12:00:00.000Z" } ?? "2026-11-04T09:00:00.000Z"
        return Fact(id: "rev-\(counter)", kind: kind, value: value, validFrom: from)
    }

    private func revision(_ fact: Fact) -> String {
        let value = (try? JSONSerialization.data(withJSONObject: fact.value, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return LifeCircumstancesFixtures.fact(fact.id, fact.kind, value)
            .replacingOccurrences(of: LifeCircumstancesFixtures.date, with: fact.validFrom)
    }

    private func payload() -> String {
        typealias Fx = LifeCircumstancesFixtures
        let layout: [LifeSectionKey: String] = [
            .tobacco: "SMOKING_STATUS", .alcohol: "ALCOHOL_PATTERN", .activity: "ACTIVITY",
            .work: "WORK", .habits: "HABITS", .goals: "GOALS"
        ]
        let sections = LifeSectionKey.allCases.map { key in
            let ai = layout[key] ?? ""
            let kinds = key.kinds.map(\.rawValue)
            return Fx.section(
                key.rawValue, ai,
                facts: facts.filter { kinds.contains($0.kind) }.map(revision),
                aiIncluded: aiIncluded.contains(ai)
            )
        }
        return Fx.payload(
            sections: sections,
            extra: #"{"SHIFT_SCHEDULE":\#(aiIncluded.contains("SHIFT_SCHEDULE"))}"#,
            auditC: offersAuditC ? auditCServer.json() : nil
        )
    }

    /// `GET /api/anamnesis/facts`: the three one-word facts, every key present.
    private func legacyFacts() -> String {
        let current = ["SMOKING_STATUS", "ALCOHOL_PATTERN", "SHIFT_SCHEDULE"].map { kind in
            let row = facts.last(where: { $0.kind == kind }).map(revision) ?? "null"
            return #""\#(kind)":\#(row)"#
        }.joined(separator: ",")
        return #"{"current":{\#(current)},"history":[]}"#
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&chunk, maxLength: chunk.count)
                guard read > 0 else { break }
                buffer.append(chunk, count: read)
            }
            data = buffer
        }
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
