import Foundation

// MARK: - #146 / #147 (server v1.43.7 to v1.43.8) — capped lists

/// `meta` of a capped list (`ListCapMeta` in `docs/api/openapi.yaml` at
/// v1.43.10): `truncated` is true when more rows exist than the response
/// carries, `limit` is the most rows it could carry. Fifteen list routes send
/// it; the server asks clients to "show the person that the list is partial
/// rather than letting the last row read as the oldest there is".
///
/// Decoded tolerantly: a missing or malformed `truncated` reads as "complete",
/// which is exactly what an older server meant.
public struct ListCapMeta: Decodable, Sendable, Equatable {
    public let truncated: Bool
    public let limit: Int?

    public init(truncated: Bool, limit: Int?) {
        self.truncated = truncated
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey {
        case truncated, limit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        limit = try? c.decodeIfPresent(Int.self, forKey: .limit)
    }
}

/// One list response with the cap the server reported beside it.
public struct ListPage<T: Sendable>: Sendable {
    public let data: T
    /// `nil` on a server before v1.43.7 and from a transport that cannot see
    /// the envelope (a test stub).
    public let cap: ListCapMeta?

    public init(data: T, cap: ListCapMeta?) {
        self.data = data
        self.cap = cap
    }
}

/// A transport that can hand back a list's envelope `meta` beside its `data`.
///
/// A separate protocol on purpose: `APIClientProtocol.send(_:)` returns `data`
/// only, and its many test conformers stay untouched. ``APIClientProtocol/listPage(_:)``
/// uses this when the transport offers it and falls back to `send` otherwise.
public protocol ListPageReading: Sendable {
    func sendListPage<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> ListPage<T>
}

private struct ListCapEnvelope: Decodable {
    let meta: ListCapMeta?

    private enum CodingKeys: String, CodingKey {
        case meta
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try? c.decodeIfPresent(ListCapMeta.self, forKey: .meta)
    }
}

extension APIClient: ListPageReading {
    /// The same request, status handling, retries and failure recording as
    /// `send(_:)` (it rides `download(_:)` and `decodePayload`), plus the
    /// envelope's `meta`.
    public func sendListPage<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> ListPage<T> {
        let started = ContinuousClock.now
        let dataRequest = APIRequest<Data>(
            method: request.method,
            path: request.path,
            query: request.query,
            body: request.body,
            extraHeaders: request.extraHeaders,
            idempotencyKey: request.idempotencyKey,
            maxRetries: request.maxRetries,
            failFast: request.failFast,
            streaming: request.streaming,
            allowsAuthenticationRecovery: request.allowsAuthenticationRecovery
        )
        let (data, response) = try await download(dataRequest)
        do {
            let payload = try recordingFailure(method: request.method, path: request.path, response: response, data: data) {
                try decodePayload(T.self, data: data, status: response.statusCode)
            }
            let cap = (try? JSONDecoder.hlDefault.decode(ListCapEnvelope.self, from: data))?.meta
            return ListPage(data: payload, cap: cap)
        } catch {
            EndpointFailureDiagnostics.record(error, method: request.method, path: request.path, since: started)
            throw error
        }
    }
}

public extension APIClientProtocol {
    /// A list read with its cap when the transport can see it, else `send`.
    func listPage<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> ListPage<T> {
        if let reader = self as? ListPageReading {
            return try await reader.sendListPage(request)
        }
        return try await ListPage(data: send(request), cap: nil)
    }
}

// MARK: - Reading a capped list whole

/// How the app honours `meta.truncated` on the lists it reads.
///
/// - A route that takes `offset` (`/api/illness/episodes`,
///   `/api/mental-health/assessments`) is read page by page while the server
///   says more rows exist, so the list is whole.
/// - A route without `offset` but with a `limit` the app asks below the
///   route's ceiling is asked once more at the ceiling when the first answer
///   was cut (allergies, family history, personal records, side effects).
/// - A route with neither (`/api/insights/ecg`, `/api/insights/rhythm-events`,
///   both capped at 200 newest) cannot be read further; the cut is logged.
///
/// Nothing here adds a line to a screen: at the ceilings below a cut list is
/// not expected in practice, and none of these screens has a natural place for
/// a "partial" note. Ceilings are the `maximum` of each route's `limit` in the
/// v1.43.10 spec.
enum CappedListReader {
    static let maxPages = 20

    static let allergiesCeiling = 200
    static let familyHistoryCeiling = 200
    static let personalRecordsCeiling = 500
    static let sideEffectsCeiling = 200

    /// Reads every page of an `offset`-paged list while `meta.truncated`. The
    /// first request is `query` exactly; each next one replaces `offset` with
    /// the rows read so far. `items` picks the rows off a page.
    static func readAllPages<Page: Decodable & Sendable, Item: Sendable>(
        api: APIClientProtocol,
        path: String,
        query: [(String, String)],
        items: @Sendable (Page) -> [Item]
    ) async throws -> [Item] {
        var rows: [Item] = []
        var pageQuery = query
        for _ in 0 ..< maxPages {
            let request: APIRequest<Page> = .get(path, query: pageQuery)
            let answer = try await api.listPage(request)
            let pageRows = items(answer.data)
            rows += pageRows
            guard answer.cap?.truncated == true, !pageRows.isEmpty else { return rows }
            pageQuery = query.filter { $0.0 != "offset" } + [("offset", String(rows.count))]
        }
        logCut(path)
        return rows
    }

    /// Reads a list without `offset`; when the server cut it and the app
    /// asked below the route's `ceiling`, asks once more at the ceiling.
    static func readUpToCeiling<Page: Decodable & Sendable>(
        api: APIClientProtocol,
        path: String,
        query: [(String, String)],
        limit: Int,
        ceiling: Int
    ) async throws -> Page {
        let first: ListPage<Page> = try await api.listPage(.get(path, query: query))
        guard first.cap?.truncated == true else { return first.data }
        guard limit < ceiling else {
            logCut(path)
            return first.data
        }
        let widened = query.filter { $0.0 != "limit" } + [("limit", String(ceiling))]
        let second: ListPage<Page> = try await api.listPage(.get(path, query: widened))
        if second.cap?.truncated == true { logCut(path) }
        return second.data
    }

    /// A list the server cut and the app cannot read further.
    static func logCut(_ path: String) {
        HLLog.api.info("Capped list still partial after reading on: \(EndpointRouteTemplate.template(path), privacy: .private)")
    }
}
